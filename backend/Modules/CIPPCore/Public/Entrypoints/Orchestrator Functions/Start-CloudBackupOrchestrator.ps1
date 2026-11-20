function Start-CloudBackupOrchestrator {
    <#
    .SYNOPSIS
        Queues cloud backup runs for every due policy, one task per policy and tenant
    .DESCRIPTION
        Picks enabled policies whose ConfigNextRun has passed (or the given policy with -Force), moves ConfigNextRun on
        before queueing, keeps the destination's retention rule in line with the policy, prunes run history older than
        the policy's retention and starts one orchestration per policy.
    .FUNCTIONALITY
        Entrypoint
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$PolicyId,
        [string]$TenantFilter,
        [switch]$Force
    )

    try {
        $Now = [datetime]::UtcNow
        $Intervals = @{
            '1h'  = [timespan]::FromHours(1)
            '4h'  = [timespan]::FromHours(4)
            '12h' = [timespan]::FromHours(12)
            '1d'  = [timespan]::FromDays(1)
            '7d'  = [timespan]::FromDays(7)
        }

        if (-not $PolicyId) {
            try {
                $JobsTable = Get-CIPPTable -TableName 'CloudBackupJobs'
                $OldJobs = @(Get-CIPPAzDataTableEntity @JobsTable -Filter "PartitionKey eq 'CloudBackupJob' and CreatedAt lt '$($Now.AddDays(-30).ToString('o'))'" -Property PartitionKey, RowKey)
                if ($OldJobs.Count -gt 0) {
                    $OldResults = foreach ($Job in $OldJobs) { @{ PartitionKey = 'CloudBackupJobResult'; RowKey = $Job.RowKey } }
                    Remove-CIPPAzDataTableEntity @JobsTable -Entity @(@($OldJobs) + @($OldResults)) -Force
                }
                $StuckJobs = @(Get-CIPPAzDataTableEntity @JobsTable -Filter "PartitionKey eq 'CloudBackupJob' and (Status eq 'Queued' or Status eq 'Running') and CreatedAt lt '$($Now.AddHours(-12).ToString('o'))'")
                foreach ($Job in $StuckJobs) {
                    $Job.Status = 'Failed'
                    $Job.Error = 'The job did not finish within 12 hours'
                    $Job.CompletedAt = $Now.ToString('o')
                    Add-CIPPAzDataTableEntity @JobsTable -Entity $Job -Force
                }
            } catch {
                $ErrorMessage = Get-CippException -Exception $_
                Write-LogMessage -API 'CloudBackup' -message "Could not remove old cloud backup compare and restore jobs: $($ErrorMessage.NormalizedError)" -sev Warning -LogData $ErrorMessage
            }
        }

        $Policies = @(if ($PolicyId) { Get-CIPPCloudBackupPolicy -Id $PolicyId } else { Get-CIPPCloudBackupPolicy })
        $Due = foreach ($Policy in $Policies) {
            if ($Force -and $PolicyId) { $Policy; continue }
            if (-not $Policy.Enabled) { continue }
            $NextRun = [datetimeoffset]::MinValue
            $Parsed = [datetimeoffset]::TryParse("$($Policy.ConfigNextRun)", [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$NextRun)
            if (-not $Parsed -or $NextRun.UtcDateTime -le $Now) { $Policy }
        }
        $Due = @($Due)
        if ($Due.Count -eq 0) {
            Write-Information 'No cloud backup policies are due'
            return 0
        }

        $ConfigTable = Get-CIPPTable -TableName 'Config'
        if (-not $Force) {
            $NextRunUpdates = foreach ($Policy in $Due) {
                $Interval = $Intervals["$($Policy.ConfigSchedule)"] ?? $Intervals['1d']
                @{ PartitionKey = 'CloudBackupPolicy'; RowKey = $Policy.Id; ConfigNextRun = $Now.Add($Interval).ToString('o') }
            }
            Add-CIPPAzDataTableEntity @ConfigTable -Entity @($NextRunUpdates) -OperationType 'UpsertMerge'
        }

        $TenantList = @(Get-Tenants)
        $DomainById = @{}
        foreach ($Tenant in $TenantList) { $DomainById[$Tenant.customerId] = $Tenant.defaultDomainName }
        $OnlyTenant = $null
        if ($TenantFilter -and $TenantFilter -ne 'AllTenants') {
            $OnlyTenant = (Get-CIPPTenantLookup -Tenants $TenantList)[$TenantFilter].customerId
            if (-not $OnlyTenant) {
                Write-LogMessage -API 'CloudBackup' -tenant $TenantFilter -message "Cloud backup: tenant $TenantFilter was not found" -sev Warning
                return 0
            }
        }

        $RunsTable = Get-CIPPTable -TableName 'CloudBackupRuns'
        $Results = foreach ($Policy in $Due) {
            try {
                $Destination = Get-CIPPCloudBackupDestination -Id $Policy.DestinationId -IncludeSecret
                if (-not $Destination) {
                    Write-LogMessage -API 'CloudBackup' -message "Cloud backup policy $($Policy.Name) skipped: its destination no longer exists" -sev Error
                    $false
                    continue
                }

                $RuleName = "cipp-$($Policy.Id)"
                $Prefix = "$($Policy.Id)/"
                try {
                    $Rule = Get-CIPPCloudBackupRetentionRule -Destination $Destination -RuleName $RuleName
                    if (-not $Rule -or $Rule.Prefix -ne $Prefix -or ($Rule.Days -as [int]) -ne $Policy.RetentionDays) {
                        Set-CIPPCloudBackupRetentionRule -Destination $Destination -RuleName $RuleName -Prefix $Prefix -Days $Policy.RetentionDays
                    }
                } catch {
                    $ErrorMessage = Get-CippException -Exception $_
                    Write-LogMessage -API 'CloudBackup' -message "Cloud backup policy $($Policy.Name): could not check the retention rule on $($Destination.Name): $($ErrorMessage.NormalizedError)" -sev Warning -LogData $ErrorMessage
                }

                $CutoffKey = '{0:D19}' -f ([datetime]::MaxValue.Ticks - $Now.AddDays(-$Policy.RetentionDays).Ticks)
                $OldRuns = @(Get-CIPPAzDataTableEntity @RunsTable -Filter "PartitionKey eq '$($Policy.Id)' and RowKey gt '$CutoffKey'" -Property PartitionKey, RowKey)
                if ($OldRuns.Count -gt 0) { Remove-CIPPAzDataTableEntity @RunsTable -Entity $OldRuns -Force }

                $TenantIds = @(Get-CIPPCloudBackupPolicyTenantId -Tenants $Policy.Tenants -TenantList $TenantList)
                if ($OnlyTenant) { $TenantIds = @($TenantIds.Where({ $_ -eq $OnlyTenant })) }
                if ($TenantIds.Count -eq 0) {
                    Write-LogMessage -API 'CloudBackup' -message "Cloud backup policy $($Policy.Name) has no tenants to back up" -sev Warning
                    continue
                }

                $Queue = New-CippQueueEntry -Name "Cloud Backup - $($Policy.Name)" -TotalTasks $TenantIds.Count
                $Batch = foreach ($TenantId in $TenantIds) {
                    [pscustomobject]@{
                        FunctionName = 'CloudBackupTenant'
                        PolicyId     = $Policy.Id
                        customerId   = $TenantId
                        QueueId      = $Queue.RowKey
                        QueueName    = $DomainById[$TenantId] ?? $TenantId
                    }
                }
                $InputObject = [pscustomobject]@{
                    Batch            = @($Batch)
                    OrchestratorName = "CloudBackup_$($Policy.Id)"
                    AllowCollision   = $false
                    SkipLog          = $true
                }
                if ($PSCmdlet.ShouldProcess($Policy.Name, 'Starting cloud backup')) {
                    Start-CIPPOrchestrator -InputObject $InputObject
                }
            } catch {
                $ErrorMessage = Get-CippException -Exception $_
                Write-LogMessage -API 'CloudBackup' -message "Could not start cloud backup policy $($Policy.Name): $($ErrorMessage.NormalizedError)" -sev Error -LogData $ErrorMessage
                $false
            }
        }
        $Results = @($Results)
        if ($Results.Count -eq 0) { return 0 }
        if ($Results.Count -eq 1) { return $Results[0] }
        return $Results
    } catch {
        $ErrorMessage = Get-CippException -Exception $_
        Write-LogMessage -API 'CloudBackup' -message "Could not start cloud backups: $($ErrorMessage.NormalizedError)" -sev Error -LogData $ErrorMessage
        return $false
    }
}
