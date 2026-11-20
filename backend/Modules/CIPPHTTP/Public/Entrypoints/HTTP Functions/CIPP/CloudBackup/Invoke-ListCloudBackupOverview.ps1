function Invoke-ListCloudBackupOverview {
    <#
    .FUNCTIONALITY
        Entrypoint,AnyTenant
    .ROLE
        CIPP.CloudBackup.Read
    .SYNOPSIS
        Cloud backup overview
    .DESCRIPTION
        Summarises cloud backup: number of policies and destinations, tenants covered by enabled policies, failed runs in the last 24 hours, the size of the latest backups, and the latest run for each policy and tenant.
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    try {
        $Now = [datetime]::UtcNow
        $AllowedTenants = @(Test-CIPPAccess -Request $Request -TenantList)
        $AllAllowed = $AllowedTenants -contains 'AllTenants'
        $Policies = @(@(Get-CIPPCloudBackupPolicy).Where({ Test-CIPPCloudBackupPolicyScope -Tenants $_.Tenants -AllowedTenants $AllowedTenants }))
        $DestinationCount = @(Get-CIPPCloudBackupDestination).Count

        $TenantList = @(Get-Tenants)
        $Covered = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($Policy in $Policies) {
            if (-not $Policy.Enabled) { continue }
            foreach ($TenantId in @(Get-CIPPCloudBackupPolicyTenantId -Tenants $Policy.Tenants -TenantList $TenantList)) {
                if ($AllAllowed -or $AllowedTenants -contains $TenantId) { [void]$Covered.Add($TenantId) }
            }
        }

        $Intervals = @{ '1h' = 1; '4h' = 4; '12h' = 12; '1d' = 24; '7d' = 168 }
        $DayKey = '{0:D19}' -f ([datetime]::MaxValue.Ticks - $Now.AddDays(-1).Ticks)
        $RunsTable = Get-CIPPTable -TableName 'CloudBackupRuns'
        $Latest = [System.Collections.Generic.List[object]]::new()
        $Failures = 0
        foreach ($Policy in $Policies) {
            $WindowHours = [Math]::Max(24, 2 * ($Intervals["$($Policy.ConfigSchedule)"] ?? 24))
            $WindowKey = '{0:D19}' -f ([datetime]::MaxValue.Ticks - $Now.AddHours(-$WindowHours).Ticks)
            $Seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            $Rows = Get-CIPPAzDataTableEntity @RunsTable -Filter "PartitionKey eq '$($Policy.Id)' and RowKey lt '$WindowKey'" -Property PartitionKey, RowKey, PolicyName, TenantId, Tenant, Status, CompletedAt, Items, Bytes
            foreach ($Row in @($Rows | Sort-Object -Property RowKey)) {
                if (-not $AllAllowed -and $AllowedTenants -notcontains $Row.TenantId) { continue }
                if ($Row.Status -eq 'Failed' -and [string]::CompareOrdinal($Row.RowKey, $DayKey) -lt 0) { $Failures++ }
                if ($Seen.Add("$($Row.TenantId)")) {
                    $Latest.Add([pscustomobject]@{
                            PolicyId    = $Policy.Id
                            PolicyName  = $Row.PolicyName ?? $Policy.Name
                            TenantId    = $Row.TenantId
                            Tenant      = $Row.Tenant
                            Status      = $Row.Status
                            CompletedAt = if ($Row.CompletedAt) { "$($Row.CompletedAt)" } else { $null }
                            Items       = [int]$Row.Items
                            Bytes       = [int64]$Row.Bytes
                        })
                }
            }
        }

        $Body = [pscustomobject]@{
            Policies        = $Policies.Count
            EnabledPolicies = @($Policies.Where({ $_.Enabled })).Count
            Destinations    = $DestinationCount
            TenantsCovered  = $Covered.Count
            Failures24h     = $Failures
            LatestBytes     = [int64](@(foreach ($Run in $Latest) { $Run.Bytes }) | Measure-Object -Sum).Sum
            LatestRuns      = @($Latest)
        }
        $StatusCode = [HttpStatusCode]::OK
    } catch {
        $ErrorMessage = Get-CippException -Exception $_
        Write-LogMessage -headers $Request.Headers -API $Request.Params.CIPPEndpoint -message "Failed to load the cloud backup overview: $($ErrorMessage.NormalizedError)" -sev Error -LogData $ErrorMessage
        $StatusCode = Get-CippErrorStatusCode -ErrorRecord $_
        $Body = @{ Results = "Failed to load the cloud backup overview: $($ErrorMessage.NormalizedError)" }
    }

    return ([HttpResponseContext]@{
            StatusCode = $StatusCode
            Body       = $Body
        })
}
