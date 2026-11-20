function Invoke-ExecCloudBackupCompare {
    <#
    .FUNCTIONALITY
        Entrypoint,AnyTenant
    .ROLE
        CIPP.CloudBackup.Read
    .SYNOPSIS
        Compare a cloud backup with the current configuration or another backup
    .DESCRIPTION
        Queues a comparison of a configuration backup with the tenant's current configuration or with another backup run, and returns its JobId. Poll ListCloudBackupJobs with the JobId for the added, removed and changed items.
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $RunIdPattern = '^([0-9a-fA-F-]{36})_(\d{19}_[A-Za-z0-9.-]+)$'
    # Backup run id as returned by ListCloudBackupRuns
    $RunId = "$($Request.Body.RunId)"
    # 'Live' for the current configuration, or another backup run id
    $CompareTo = "$($Request.Body.CompareTo.value ?? $Request.Body.CompareTo)"
    # Optional configuration areas to compare
    $Areas = @(foreach ($Area in @($Request.Body.Areas)) { if ($Area) { "$($Area.value ?? $Area)" } })

    if ($RunId -notmatch $RunIdPattern -or -not ($Matches[1] -as [guid])) {
        return ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::BadRequest
                Body       = @{ Results = 'RunId must be a backup run id from ListCloudBackupRuns' }
            })
    }
    $RunPartition = "$([guid]$Matches[1])"
    $RunKey = $Matches[2]
    if (-not $CompareTo) { $CompareTo = 'Live' }
    $OtherPartition = $null
    $OtherKey = $null
    if ($CompareTo -ne 'Live') {
        if ($CompareTo -notmatch $RunIdPattern -or -not ($Matches[1] -as [guid]) -or $CompareTo -eq $RunId) {
            return ([HttpResponseContext]@{
                    StatusCode = [HttpStatusCode]::BadRequest
                    Body       = @{ Results = "CompareTo must be 'Live' or the id of a different backup run" }
                })
        }
        $OtherPartition = "$([guid]$Matches[1])"
        $OtherKey = $Matches[2]
    }
    foreach ($Area in $Areas) {
        if ($Area -notin @('ConditionalAccess', 'Intune', 'Exchange', 'SharePoint')) {
            return ([HttpResponseContext]@{
                    StatusCode = [HttpStatusCode]::BadRequest
                    Body       = @{ Results = 'Areas must contain only ConditionalAccess, Intune, Exchange or SharePoint' }
                })
        }
    }

    try {
        $RunsTable = Get-CIPPTable -TableName 'CloudBackupRuns'
        $Run = @(Get-CIPPAzDataTableEntity @RunsTable -Filter "PartitionKey eq '$RunPartition' and RowKey eq '$RunKey'")[0]
        $Other = if ($OtherPartition) { @(Get-CIPPAzDataTableEntity @RunsTable -Filter "PartitionKey eq '$OtherPartition' and RowKey eq '$OtherKey'")[0] }
        if (-not $Run -or ($OtherPartition -and -not $Other)) {
            return ([HttpResponseContext]@{
                    StatusCode = [HttpStatusCode]::NotFound
                    Body       = @{ Results = "Backup run $(if ($Run) { $CompareTo } else { $RunId }) was not found" }
                })
        }
        $AllowedTenants = @(Test-CIPPAccess -Request $Request -TenantList)
        if ($AllowedTenants -notcontains 'AllTenants' -and ($AllowedTenants -notcontains $Run.TenantId -or ($Other -and $AllowedTenants -notcontains $Other.TenantId))) {
            return ([HttpResponseContext]@{
                    StatusCode = [HttpStatusCode]::Forbidden
                    Body       = @{ Results = 'You do not have access to the tenant of this backup' }
                })
        }
        foreach ($Candidate in @($Run, $Other)) {
            if ($Candidate -and $Candidate.Status -notin @('Succeeded', 'PartialSuccess')) {
                return ([HttpResponseContext]@{
                        StatusCode = [HttpStatusCode]::BadRequest
                        Body       = @{ Results = "Backup run from $($Candidate.StartedAt) has status $($Candidate.Status) and cannot be compared" }
                    })
            }
        }

        $Lookup = Get-CIPPTenantLookup
        $TargetTenantId = if ($Other) { $Other.TenantId } else { $Run.TenantId }
        $Parameters = [ordered]@{
            RunId     = $RunId
            CompareTo = $CompareTo
            Areas     = @($Areas | Sort-Object -Unique)
        }
        $ParametersJson = [CIPP.CippJson]::ToJson($Parameters, 5) ?? (ConvertTo-Json -InputObject $Parameters -Depth 5 -Compress)
        $Principal = try { [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Request.Headers.'x-ms-client-principal')) | ConvertFrom-Json } catch { $null }
        $RequestedBy = if ($Request.Headers.'x-ms-client-principal-idp' -eq 'aad') { $Request.Headers.'x-ms-client-principal-name' } else { $Principal.userDetails ?? $Request.Headers.'x-ms-client-principal-name' ?? 'CIPP' }

        $JobId = [guid]::NewGuid().ToString()
        $Job = @{
            PartitionKey   = 'CloudBackupJob'
            RowKey         = $JobId
            Type           = 'Compare'
            Status         = 'Queued'
            RunId          = $RunId
            CompareToRunId = if ($Other) { $CompareTo } else { '' }
            SourceTenantId = "$($Run.TenantId)"
            SourceTenant   = "$($Lookup["$($Run.TenantId)"].defaultDomainName ?? $Run.Tenant)"
            TargetTenantId = "$TargetTenantId"
            TargetTenant   = "$($Lookup["$TargetTenantId"].defaultDomainName ?? $(if ($Other) { $Other.Tenant } else { $Run.Tenant }))"
            Parameters     = $ParametersJson
            ParametersHash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($ParametersJson))).ToLowerInvariant()
            PreviewJobId   = ''
            RequestedBy    = "$RequestedBy"
            CreatedAt      = [datetime]::UtcNow.ToString('o')
            StartedAt      = ''
            CompletedAt    = ''
            Summary        = ''
            Error          = ''
        }
        $JobsTable = Get-CIPPTable -TableName 'CloudBackupJobs'
        Add-CIPPAzDataTableEntity @JobsTable -Entity $Job -Force

        $InputObject = [pscustomobject]@{
            Batch            = @([pscustomobject]@{ FunctionName = 'CloudBackupJob'; JobId = $JobId; QueueName = $Job.TargetTenant })
            OrchestratorName = "CloudBackupJob_$JobId"
            SkipLog          = $true
        }
        if (-not (Start-CIPPOrchestrator -InputObject $InputObject)) {
            $Job.Status = 'Failed'
            $Job.Error = 'The comparison could not be queued'
            Add-CIPPAzDataTableEntity @JobsTable -Entity $Job -Force
            throw 'The comparison could not be queued'
        }
        $Target = if ($Other) { "the backup from $($Other.StartedAt)" } else { 'the current configuration' }
        $Result = "Comparing the backup of $($Job.SourceTenant) from $($Run.StartedAt) with $Target"
        $StatusCode = [HttpStatusCode]::Accepted
    } catch {
        $ErrorMessage = Get-CippException -Exception $_
        $Result = "Failed to start the comparison: $($ErrorMessage.NormalizedError)"
        Write-LogMessage -headers $Request.Headers -API $Request.Params.CIPPEndpoint -message $Result -sev Error -LogData $ErrorMessage
        $StatusCode = Get-CippErrorStatusCode -ErrorRecord $_
        $JobId = $null
    }

    return ([HttpResponseContext]@{
            StatusCode = $StatusCode
            Body       = @{ Results = $Result; JobId = $JobId }
        })
}
