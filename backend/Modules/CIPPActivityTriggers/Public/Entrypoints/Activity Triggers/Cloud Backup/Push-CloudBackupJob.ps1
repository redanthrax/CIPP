function Push-CloudBackupJob {
    <#
    .SYNOPSIS
        Runs one cloud backup compare, restore preview or restore job
    .FUNCTIONALITY
        Entrypoint
    #>
    [CmdletBinding()]
    param($Item)

    $JobId = "$($Item.JobId)"
    $Table = $null
    $Row = $null
    $Status = 'Failed'
    $ErrorText = ''
    $Summary = $null
    $Result = [System.Collections.Generic.List[object]]::new()
    $TargetDomain = $null

    try {
        if (-not ($JobId -as [guid])) { throw "Cloud backup job id '$JobId' is not valid" }
        $Table = Get-CIPPTable -TableName 'CloudBackupJobs'
        $Job = @(Get-CIPPAzDataTableEntity @Table -Filter "PartitionKey eq 'CloudBackupJob' and RowKey eq '$([guid]$JobId)'")[0]
        if (-not $Job) { throw "Cloud backup job $JobId was not found" }

        $Row = @{
            PartitionKey   = 'CloudBackupJob'
            RowKey         = $Job.RowKey
            Type           = "$($Job.Type)"
            Status         = 'Running'
            RunId          = "$($Job.RunId)"
            CompareToRunId = "$($Job.CompareToRunId)"
            SourceTenantId = "$($Job.SourceTenantId)"
            SourceTenant   = "$($Job.SourceTenant)"
            TargetTenantId = "$($Job.TargetTenantId)"
            TargetTenant   = "$($Job.TargetTenant)"
            Parameters     = "$($Job.Parameters)"
            ParametersHash = "$($Job.ParametersHash)"
            PreviewJobId   = "$($Job.PreviewJobId)"
            RequestedBy    = "$($Job.RequestedBy)"
            CreatedAt      = "$($Job.CreatedAt)"
            StartedAt      = [datetime]::UtcNow.ToString('o')
            CompletedAt    = ''
            Summary        = ''
            Error          = ''
        }
        Add-CIPPAzDataTableEntity @Table -Entity $Row -Force

        $Parameters = [CIPP.CippJson]::ConvertFromJson($Row.Parameters)
        $Areas = @(foreach ($Area in @($Parameters.Areas)) { if ($Area) { "$Area" } })
        $SameTenant = $Row.SourceTenantId -eq $Row.TargetTenantId
        $Target = (Get-CIPPTenantLookup)[$Row.TargetTenantId]
        $TargetDomain = $Target.defaultDomainName ?? $Row.TargetTenant

        $SnapshotParams = @{ RunId = $Row.RunId }
        if ($Areas.Count -gt 0) { $SnapshotParams.Area = $Areas }
        $Snapshot = Get-CIPPCloudBackupSnapshot @SnapshotParams
        if ($Areas.Count -eq 0) { $Areas = @($Snapshot.Areas.Keys) }

        if ($Row.Type -eq 'Compare') {
            $Other = $null
            if ($Row.CompareToRunId) {
                $Other = Get-CIPPCloudBackupSnapshot -RunId $Row.CompareToRunId -Area $Areas
            } elseif (-not $Target) {
                throw "Tenant $($Row.TargetTenant) was not found"
            }
            $Summary = [ordered]@{}
            foreach ($Area in $Areas) {
                $Reference = $Snapshot.Areas[$Area]
                if (-not $Reference) { continue }
                $Difference = if ($Other) {
                    $Other.Areas[$Area]
                } else {
                    Get-CIPPCloudBackupConfigData -TenantFilter $TargetDomain -Area $Area
                }
                $Difference = $Difference ?? [pscustomobject]@{ Sections = [ordered]@{}; References = @{ Groups = @{}; Users = @{} } }
                $Counts = [ordered]@{ Added = 0; Removed = 0; Changed = 0; Unchanged = 0 }
                foreach ($Change in @(Compare-CIPPCloudBackupConfig -Area $Area -Reference $Reference -Difference $Difference -MatchByName:(-not $SameTenant))) {
                    if ($null -eq $Change) { continue }
                    $Counts["$($Change.Change)"]++
                    if ($Change.Change -ne 'Unchanged') { $Result.Add($Change) }
                }
                $Summary[$Area] = $Counts
            }
        } else {
            $Apply = $Row.Type -eq 'Restore'
            $Selected = @{}
            foreach ($Selection in @($Parameters.Items)) {
                if ($null -eq $Selection) { continue }
                $AreaName = "$($Selection.Area)"
                if (-not $Selected.ContainsKey($AreaName)) { $Selected[$AreaName] = [System.Collections.Generic.List[object]]::new() }
                $Selected[$AreaName].Add(@{ Section = "$($Selection.Section)"; Key = "$($Selection.Key)" })
            }
            $HasSelection = $Selected.Count -gt 0
            if (-not $Target) { throw "Tenant $($Row.TargetTenant) was not found" }

            $Mode = if ($Apply) { 'Restore' } else { 'Restore preview' }
            Write-LogMessage -API 'CloudBackupRestore' -tenant $TargetDomain -tenantid $Row.TargetTenantId -message "$Mode of backup $($Row.RunId) started by $($Row.RequestedBy) (areas: $($Areas -join ', '))" -sev Info

            foreach ($Area in $Areas) {
                $AreaSnapshot = $Snapshot.Areas[$Area]
                if (-not $AreaSnapshot) { continue }
                if ($HasSelection -and -not $Selected.ContainsKey($Area)) { continue }

                $AreaRows = @(try {
                        $RestoreParams = @{
                            Snapshot           = $AreaSnapshot
                            SourceTenantId     = $Row.SourceTenantId
                            TargetTenantFilter = $TargetDomain
                            ConflictAction     = "$($Parameters.ConflictAction)"
                            Apply              = $Apply
                        }
                        if ($HasSelection) { $RestoreParams.Items = @($Selected[$Area]) }
                        switch ($Area) {
                            'ConditionalAccess' { Restore-CIPPCloudBackupConditionalAccess @RestoreParams -CAState "$($Parameters.CAState)" }
                            'Intune' { Restore-CIPPCloudBackupIntune @RestoreParams }
                            'Exchange' { Restore-CIPPCloudBackupExchange @RestoreParams }
                            default {
                                $Wanted = $null
                                if ($HasSelection) {
                                    $Wanted = [System.Collections.Generic.HashSet[string]]::new()
                                    foreach ($Selection in $Selected[$Area]) { $null = $Wanted.Add("$($Selection.Section)|$($Selection.Key)") }
                                }
                                foreach ($Section in @($AreaSnapshot.Sections.Keys)) {
                                    $Label = Get-CIPPCloudBackupSectionLabel -Section $Section
                                    $Entries = @(foreach ($Entry in @($AreaSnapshot.Sections[$Section])) { if ($null -ne $Entry) { $Entry } })
                                    if ($Entries.Count -eq 0) { continue }
                                    foreach ($Info in @(Get-CIPPCloudBackupItemInfo -Section $Section -Item $Entries)) {
                                        if ($Wanted -and -not $Wanted.Contains("$Section|$($Info.Key)")) { continue }
                                        [pscustomobject]@{
                                            Area         = $Area
                                            Section      = $Section
                                            SectionLabel = $Label
                                            Key          = $Info.Key
                                            Name         = $Info.Name
                                            Action       = 'NotRestorable'
                                            Status       = 'Skipped'
                                            Message      = 'SharePoint settings can be compared but not restored'
                                            Unmapped     = @()
                                        }
                                    }
                                }
                            }
                        }
                    } catch {
                        [pscustomobject]@{
                            Area         = $Area
                            Section      = ''
                            SectionLabel = ''
                            Key          = ''
                            Name         = $Area
                            Action       = 'Skip'
                            Status       = 'Failed'
                            Message      = "Could not restore $($Area): $((Get-CippException -Exception $_).NormalizedError)"
                            Unmapped     = @()
                        }
                    })

                $DifferenceIndex = @{}
                if (-not $Apply) {
                    try {
                        $Live = Get-CIPPCloudBackupConfigData -TenantFilter $TargetDomain -Area $Area
                        foreach ($Change in @(Compare-CIPPCloudBackupConfig -Area $Area -Reference $AreaSnapshot -Difference $Live -MatchByName:(-not $SameTenant))) {
                            if ($null -eq $Change) { continue }
                            $IndexKey = if ($SameTenant) { "$($Change.Section)|$($Change.Key)" } else { "$($Change.Section)|$($Change.Name)" }
                            $DifferenceIndex[$IndexKey] = @($Change.Differences)
                        }
                    } catch {
                        $ErrorMessage = Get-CippException -Exception $_
                        Write-LogMessage -API 'CloudBackupRestore' -tenant $TargetDomain -tenantid $Row.TargetTenantId -message "Restore preview could not compare $Area with the current configuration: $($ErrorMessage.NormalizedError)" -sev Warning -LogData $ErrorMessage
                    }
                }

                foreach ($AreaRow in $AreaRows) {
                    if ($null -eq $AreaRow) { continue }
                    $IndexKey = if ($SameTenant) { "$($AreaRow.Section)|$($AreaRow.Key)" } else { "$($AreaRow.Section)|$($AreaRow.Name)" }
                    $Differences = $DifferenceIndex[$IndexKey] ?? @()
                    $null = $AreaRow.PSObject.Properties.Remove('Differences')
                    $AreaRow.PSObject.Properties.Add([psnoteproperty]::new('Differences', @($Differences)))
                    $Result.Add($AreaRow)
                    if ($AreaRow.Status -eq 'Failed') {
                        Write-LogMessage -API 'CloudBackupRestore' -tenant $TargetDomain -tenantid $Row.TargetTenantId -message "$Mode of $($AreaRow.SectionLabel) '$($AreaRow.Name)' failed: $($AreaRow.Message)" -sev Warning
                    }
                }
            }

            $Summary = [ordered]@{ Create = 0; Update = 0; CreateCopy = 0; Skip = 0; NotRestorable = 0; Succeeded = 0; Failed = 0 }
            foreach ($ResultRow in $Result) {
                if ($Summary.Contains("$($ResultRow.Action)")) { $Summary["$($ResultRow.Action)"]++ }
                if ($ResultRow.Status -in @('Succeeded', 'Failed')) { $Summary["$($ResultRow.Status)"]++ }
            }
        }
        $Status = 'Completed'
    } catch {
        $ErrorMessage = Get-CippException -Exception $_
        $ErrorText = $ErrorMessage.NormalizedError
        try { Write-LogMessage -API 'CloudBackupRestore' -tenant $TargetDomain -tenantid $Row.TargetTenantId -message "Cloud backup job $JobId failed: $ErrorText" -sev Error -LogData $ErrorMessage } catch { Write-Warning $ErrorText }
    } finally {
        if ($Row) {
            $Row.Status = $Status
            $Row.CompletedAt = [datetime]::UtcNow.ToString('o')
            $Row.Error = "$ErrorText"
            $Row.Summary = if ($Summary) { [CIPP.CippJson]::ToJson($Summary, 5) ?? (ConvertTo-Json -InputObject $Summary -Depth 5 -Compress) } else { '' }
            try {
                $ResultJson = [CIPP.CippJson]::ToJson($Result, 50) ?? (ConvertTo-Json -InputObject @($Result) -Depth 50 -Compress)
                Add-CIPPAzDataTableEntity @Table -Entity @{ PartitionKey = 'CloudBackupJobResult'; RowKey = $Row.RowKey; Result = $ResultJson } -Force
            } catch {
                $Row.Status = 'Failed'
                $Row.Error = "Could not save the job result: $((Get-CippException -Exception $_).NormalizedError)"
            }
            try {
                Add-CIPPAzDataTableEntity @Table -Entity $Row -Force
            } catch {
                $RecordError = "Could not record cloud backup job $($JobId): $($_.Exception.Message)"
                try { Write-LogMessage -API 'CloudBackupRestore' -tenant $TargetDomain -tenantid $Row.TargetTenantId -message $RecordError -sev Error } catch { Write-Warning $RecordError }
            }
            if ($Row.Type -ne 'Compare' -and $Summary) {
                $Mode = if ($Row.Type -eq 'Restore') { 'Restore' } else { 'Restore preview' }
                $Counts = foreach ($Name in $Summary.Keys) { "$Name $($Summary[$Name])" }
                $Severity = if ($Summary.Failed -gt 0 -or $Row.Status -eq 'Failed') { 'Warning' } else { 'Info' }
                try {
                    Write-LogMessage -API 'CloudBackupRestore' -tenant $TargetDomain -tenantid $Row.TargetTenantId -message "$Mode of backup $($Row.RunId) requested by $($Row.RequestedBy) finished with status $($Row.Status): $($Counts -join ', ')" -sev $Severity
                } catch { Write-Warning "$Mode of backup $($Row.RunId) finished with status $($Row.Status)" }
            }
        }
    }
}
