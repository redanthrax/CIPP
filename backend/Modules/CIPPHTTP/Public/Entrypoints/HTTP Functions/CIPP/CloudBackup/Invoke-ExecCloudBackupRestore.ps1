function Invoke-ExecCloudBackupRestore {
    <#
    .FUNCTIONALITY
        Entrypoint,AnyTenant
    .ROLE
        CIPP.CloudBackupRestore.ReadWrite
    .SYNOPSIS
        Preview or run a restore from a cloud backup
    .DESCRIPTION
        Queues a restore of Conditional Access, Intune and Exchange configuration from a backup run to the same or another tenant, and returns its JobId. Mode Preview makes no changes and shows what would happen. Mode Apply needs the PreviewJobId of a completed preview with the same options, started by the same user in the last 60 minutes and not used for another restore. Poll ListCloudBackupJobs with the JobId for the results.
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $ValidAreas = @('ConditionalAccess', 'Intune', 'Exchange', 'SharePoint')
    # Backup run id as returned by ListCloudBackupRuns
    $RunId = "$($Request.Body.RunId)"
    # Tenant to restore to (default domain or customerId); defaults to the backed-up tenant
    $TargetTenant = "$($Request.Body.TargetTenant.value ?? $Request.Body.TargetTenant)"
    # Preview (no changes) or Apply
    $Mode = "$($Request.Body.Mode.value ?? $Request.Body.Mode)"
    # What to do when the item already exists in the target: Skip, Overwrite or Copy
    $ConflictAction = "$($Request.Body.ConflictAction.value ?? $Request.Body.ConflictAction)"
    # Conditional Access policy state: AsBackedUp, ReportOnly or Disabled
    $CAState = "$($Request.Body.CAState.value ?? $Request.Body.CAState)"
    # Id of the completed preview job, required for Apply
    $PreviewJobId = "$($Request.Body.PreviewJobId)"
    # Configuration areas to restore; defaults to the areas of the selected items or of the backup
    $Areas = @(foreach ($Area in @($Request.Body.Areas)) { if ($Area) { "$($Area.value ?? $Area)" } })
    # Optional items to restore, each { Area, Section, Key }; all items of the areas when omitted
    $Items = @(foreach ($Item in @($Request.Body.Items)) { if ($null -ne $Item) { $Item } })

    if ($RunId -notmatch '^([0-9a-fA-F-]{36})_(\d{19}_[A-Za-z0-9.-]+)$' -or -not ($Matches[1] -as [guid])) {
        return ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::BadRequest
                Body       = @{ Results = 'RunId must be a backup run id from ListCloudBackupRuns' }
            })
    }
    $RunPartition = "$([guid]$Matches[1])"
    $RunKey = $Matches[2]
    if ($Mode -notin @('Preview', 'Apply')) {
        return ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::BadRequest
                Body       = @{ Results = 'Mode must be Preview or Apply' }
            })
    }
    if (-not $ConflictAction) { $ConflictAction = 'Skip' }
    if ($ConflictAction -notin @('Skip', 'Overwrite', 'Copy')) {
        return ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::BadRequest
                Body       = @{ Results = 'ConflictAction must be Skip, Overwrite or Copy' }
            })
    }
    if ($CAState -and $CAState -notin @('AsBackedUp', 'ReportOnly', 'Disabled')) {
        return ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::BadRequest
                Body       = @{ Results = 'CAState must be AsBackedUp, ReportOnly or Disabled' }
            })
    }
    if ($TargetTenant -eq 'AllTenants' -or $TargetTenant -like 'group:*') {
        return ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::BadRequest
                Body       = @{ Results = 'TargetTenant must be a single tenant' }
            })
    }
    $ItemKeys = [System.Collections.Generic.List[string]]::new()
    foreach ($Item in $Items) {
        if (-not $Item.Area -or -not $Item.Section -or "$($Item.Key)" -eq '' -or "$($Item.Area)" -notin $ValidAreas -or ($Areas.Count -gt 0 -and "$($Item.Area)" -notin $Areas)) {
            return ([HttpResponseContext]@{
                    StatusCode = [HttpStatusCode]::BadRequest
                    Body       = @{ Results = 'Each item needs an Area, Section and Key, and its Area must be one of the selected areas' }
                })
        }
        $ItemKeys.Add("$($Item.Area)`n$($Item.Section)`n$($Item.Key)")
    }
    foreach ($Area in $Areas) {
        if ($Area -notin $ValidAreas) {
            return ([HttpResponseContext]@{
                    StatusCode = [HttpStatusCode]::BadRequest
                    Body       = @{ Results = 'Areas must contain only ConditionalAccess, Intune, Exchange or SharePoint' }
                })
        }
    }
    if ($Mode -eq 'Apply' -and -not ($PreviewJobId -as [guid])) {
        return ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::BadRequest
                Body       = @{ Results = 'Run a restore preview first: Apply needs the PreviewJobId of a completed preview' }
            })
    }

    try {
        $RunsTable = Get-CIPPTable -TableName 'CloudBackupRuns'
        $Run = @(Get-CIPPAzDataTableEntity @RunsTable -Filter "PartitionKey eq '$RunPartition' and RowKey eq '$RunKey'")[0]
        if (-not $Run) {
            return ([HttpResponseContext]@{
                    StatusCode = [HttpStatusCode]::NotFound
                    Body       = @{ Results = "Backup run $RunId was not found" }
                })
        }
        $Lookup = Get-CIPPTenantLookup
        $Target = $Lookup[$(if ($TargetTenant) { $TargetTenant } else { "$($Run.TenantId)" })]
        if (-not $Target) {
            return ([HttpResponseContext]@{
                    StatusCode = [HttpStatusCode]::NotFound
                    Body       = @{ Results = "Tenant $(if ($TargetTenant) { $TargetTenant } else { $Run.Tenant }) was not found" }
                })
        }
        $AllowedTenants = @(Test-CIPPAccess -Request $Request -TenantList)
        if ($AllowedTenants -notcontains 'AllTenants' -and ($AllowedTenants -notcontains $Run.TenantId -or $AllowedTenants -notcontains $Target.customerId)) {
            return ([HttpResponseContext]@{
                    StatusCode = [HttpStatusCode]::Forbidden
                    Body       = @{ Results = 'You do not have access to the backed-up tenant or the target tenant' }
                })
        }
        if ($Run.Status -notin @('Succeeded', 'PartialSuccess')) {
            return ([HttpResponseContext]@{
                    StatusCode = [HttpStatusCode]::BadRequest
                    Body       = @{ Results = "Backup run from $($Run.StartedAt) has status $($Run.Status) and cannot be restored" }
                })
        }

        $SameTenant = "$($Run.TenantId)" -eq "$($Target.customerId)"
        if ($Areas.Count -eq 0) {
            $Areas = if ($Items.Count -gt 0) {
                @(foreach ($Item in $Items) { "$($Item.Area)" })
            } else {
                @(foreach ($AreaResult in @(if ($Run.Areas) { [CIPP.CippJson]::ConvertFromJson([string]$Run.Areas) })) {
                        if ($AreaResult.Status -ne 'Failed') { "$($AreaResult.Area)" }
                    })
            }
        }
        $Areas = @($Areas | Sort-Object -Unique)
        if ($Areas.Count -eq 0) {
            return ([HttpResponseContext]@{
                    StatusCode = [HttpStatusCode]::BadRequest
                    Body       = @{ Results = 'This backup has no configuration areas to restore' }
                })
        }
        if (-not $CAState) { $CAState = if ($SameTenant) { 'AsBackedUp' } else { 'ReportOnly' } }

        $SortedKeys = $ItemKeys.ToArray()
        [Array]::Sort($SortedKeys, [System.StringComparer]::Ordinal)
        $Previous = $null
        $CanonicalItems = foreach ($ItemKey in $SortedKeys) {
            if ($ItemKey -ceq $Previous) { continue }
            $Previous = $ItemKey
            $Parts = $ItemKey.Split("`n", 3)
            [ordered]@{ Area = $Parts[0]; Section = $Parts[1]; Key = $Parts[2] }
        }
        $Parameters = [ordered]@{
            RunId          = $RunId
            TargetTenantId = "$($Target.customerId)"
            Areas          = $Areas
            Items          = @($CanonicalItems)
            ConflictAction = $ConflictAction
            CAState        = $CAState
        }
        $ParametersJson = [CIPP.CippJson]::ToJson($Parameters, 5) ?? (ConvertTo-Json -InputObject $Parameters -Depth 5 -Compress)
        $ParametersHash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($ParametersJson))).ToLowerInvariant()
        $Principal = try { [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Request.Headers.'x-ms-client-principal')) | ConvertFrom-Json } catch { $null }
        $RequestedBy = if ($Request.Headers.'x-ms-client-principal-idp' -eq 'aad') { $Request.Headers.'x-ms-client-principal-name' } else { $Principal.userDetails ?? $Request.Headers.'x-ms-client-principal-name' ?? 'CIPP' }

        $JobsTable = Get-CIPPTable -TableName 'CloudBackupJobs'
        if ($Mode -eq 'Apply') {
            $Preview = @(Get-CIPPAzDataTableEntity @JobsTable -Filter "PartitionKey eq 'CloudBackupJob' and RowKey eq '$([guid]$PreviewJobId)'")[0]
            $PreviewCreated = [datetimeoffset]::MinValue
            $Refusal = if (-not $Preview -or $Preview.Type -ne 'RestorePreview') {
                'The preview was not found. Run a restore preview first.'
            } elseif ($Preview.Status -ne 'Completed') {
                'The preview has not completed successfully. Run a new preview.'
            } elseif ($Preview.AppliedJobId) {
                'This preview was already used for a restore. Run a new preview.'
            } elseif ("$($Preview.RequestedBy)" -ne "$RequestedBy") {
                'The preview was run by another user. Run your own preview first.'
            } elseif (-not [datetimeoffset]::TryParse("$($Preview.CreatedAt)", [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$PreviewCreated) -or
                $PreviewCreated.UtcDateTime -lt [datetime]::UtcNow.AddMinutes(-60)) {
                'The preview is more than 60 minutes old. Run a new preview.'
            } elseif ("$($Preview.ParametersHash)" -ne $ParametersHash) {
                'The restore options differ from the preview. Run a new preview with these options.'
            }
            if ($Refusal) {
                return ([HttpResponseContext]@{
                        StatusCode = [HttpStatusCode]::BadRequest
                        Body       = @{ Results = $Refusal }
                    })
            }
        }

        $JobId = [guid]::NewGuid().ToString()
        $Job = @{
            PartitionKey   = 'CloudBackupJob'
            RowKey         = $JobId
            Type           = if ($Mode -eq 'Apply') { 'Restore' } else { 'RestorePreview' }
            Status         = 'Queued'
            RunId          = $RunId
            CompareToRunId = ''
            SourceTenantId = "$($Run.TenantId)"
            SourceTenant   = "$($Lookup["$($Run.TenantId)"].defaultDomainName ?? $Run.Tenant)"
            TargetTenantId = "$($Target.customerId)"
            TargetTenant   = "$($Target.defaultDomainName)"
            Parameters     = $ParametersJson
            ParametersHash = $ParametersHash
            PreviewJobId   = if ($Mode -eq 'Apply') { "$([guid]$PreviewJobId)" } else { '' }
            RequestedBy    = "$RequestedBy"
            CreatedAt      = [datetime]::UtcNow.ToString('o')
            StartedAt      = ''
            CompletedAt    = ''
            Summary        = ''
            Error          = ''
        }
        Add-CIPPAzDataTableEntity @JobsTable -Entity $Job -Force
        if ($Mode -eq 'Apply') {
            $Preview | Add-Member -NotePropertyName 'AppliedJobId' -NotePropertyValue $JobId -Force
            Add-CIPPAzDataTableEntity @JobsTable -Entity $Preview -Force
        }

        $InputObject = [pscustomobject]@{
            Batch            = @([pscustomobject]@{ FunctionName = 'CloudBackupJob'; JobId = $JobId; QueueName = $Job.TargetTenant })
            OrchestratorName = "CloudBackupJob_$JobId"
            SkipLog          = $true
        }
        if (-not (Start-CIPPOrchestrator -InputObject $InputObject)) {
            $Job.Status = 'Failed'
            $Job.Error = 'The restore could not be queued'
            Add-CIPPAzDataTableEntity @JobsTable -Entity $Job -Force
            if ($Mode -eq 'Apply') {
                $Preview.AppliedJobId = ''
                Add-CIPPAzDataTableEntity @JobsTable -Entity $Preview -Force
            }
            throw 'The restore could not be queued'
        }
        $Result = if ($Mode -eq 'Apply') {
            "Restoring the backup of $($Job.SourceTenant) from $($Run.StartedAt) to $($Job.TargetTenant)"
        } else {
            "Previewing a restore of the backup of $($Job.SourceTenant) from $($Run.StartedAt) to $($Job.TargetTenant). No changes are made."
        }
        Write-LogMessage -headers $Request.Headers -API 'CloudBackupRestore' -tenant $Job.TargetTenant -tenantid $Job.TargetTenantId -message $Result -sev Info
        $StatusCode = [HttpStatusCode]::Accepted
    } catch {
        $ErrorMessage = Get-CippException -Exception $_
        $Result = "Failed to start the restore: $($ErrorMessage.NormalizedError)"
        Write-LogMessage -headers $Request.Headers -API $Request.Params.CIPPEndpoint -message $Result -sev Error -LogData $ErrorMessage
        $StatusCode = Get-CippErrorStatusCode -ErrorRecord $_
        $JobId = $null
    }

    return ([HttpResponseContext]@{
            StatusCode = $StatusCode
            Body       = @{ Results = $Result; JobId = $JobId }
        })
}
