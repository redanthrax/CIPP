function Invoke-ListCloudBackupJobs {
    <#
    .FUNCTIONALITY
        Entrypoint,AnyTenant
    .ROLE
        CIPP.CloudBackup.Read
    .SYNOPSIS
        List cloud backup compare and restore jobs
    .DESCRIPTION
        Lists the newest 200 compare, restore preview and restore jobs of the last 30 days with their status, tenants, who started them and a summary of the results. With Id, returns that job including every result item. Callers limited to some tenants only see jobs for those tenants.
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    # Optional job id to return one job with its results
    $Id = $Request.Query.Id

    if ($Id -and -not ($Id -as [guid])) {
        return ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::BadRequest
                Body       = @{ Results = 'Id must be a job id (GUID)' }
            })
    }

    try {
        $AllowedTenants = @(Test-CIPPAccess -Request $Request -TenantList)
        $AllAllowed = $AllowedTenants -contains 'AllTenants'
        $Lookup = Get-CIPPTenantLookup
        $Table = Get-CIPPTable -TableName 'CloudBackupJobs'

        $Filter = "PartitionKey eq 'CloudBackupJob'"
        if ($Id) { $Filter = "$Filter and RowKey eq '$([guid]$Id)'" }
        $Found = @(Get-CIPPAzDataTableEntity @Table -Filter $Filter)
        $Rows = [System.Collections.Generic.List[object]]::new()
        foreach ($Row in $Found) {
            if ($AllAllowed -or ($AllowedTenants -contains $Row.SourceTenantId -and $AllowedTenants -contains $Row.TargetTenantId)) { $Rows.Add($Row) }
        }

        if ($Id -and $Found.Count -eq 0) {
            return ([HttpResponseContext]@{
                    StatusCode = [HttpStatusCode]::NotFound
                    Body       = @{ Results = "Job $Id was not found" }
                })
        }
        if ($Id -and $Rows.Count -eq 0) {
            return ([HttpResponseContext]@{
                    StatusCode = [HttpStatusCode]::Forbidden
                    Body       = @{ Results = 'You do not have access to the tenants of this job' }
                })
        }

        $Selected = if ($Id) { @($Rows) } else { @($Rows | Sort-Object -Property CreatedAt -Descending | Select-Object -First 200) }
        $Jobs = foreach ($Row in $Selected) {
            $Job = [pscustomobject]@{
                Id             = $Row.RowKey
                Type           = $Row.Type
                Status         = $Row.Status
                RunId          = $Row.RunId
                CompareToRunId = if ($Row.CompareToRunId) { $Row.CompareToRunId } else { $null }
                SourceTenantId = $Row.SourceTenantId
                SourceTenant   = $Lookup["$($Row.SourceTenantId)"].defaultDomainName ?? $Row.SourceTenant
                TargetTenantId = $Row.TargetTenantId
                TargetTenant   = $Lookup["$($Row.TargetTenantId)"].defaultDomainName ?? $Row.TargetTenant
                Parameters     = if ($Row.Parameters) { [CIPP.CippJson]::ConvertFromJson([string]$Row.Parameters) } else { $null }
                PreviewJobId   = if ($Row.PreviewJobId) { $Row.PreviewJobId } else { $null }
                RequestedBy    = $Row.RequestedBy
                CreatedAt      = if ($Row.CreatedAt) { "$($Row.CreatedAt)" } else { $null }
                StartedAt      = if ($Row.StartedAt) { "$($Row.StartedAt)" } else { $null }
                CompletedAt    = if ($Row.CompletedAt) { "$($Row.CompletedAt)" } else { $null }
                Summary        = if ($Row.Summary) { [CIPP.CippJson]::ConvertFromJson([string]$Row.Summary) } else { $null }
                Error          = if ($Row.Error) { $Row.Error } else { $null }
            }
            if ($Id) {
                $ResultRow = @(Get-CIPPAzDataTableEntity @Table -Filter "PartitionKey eq 'CloudBackupJobResult' and RowKey eq '$($Row.RowKey)'")[0]
                $Result = @(if ($ResultRow.Result) { [CIPP.CippJson]::ConvertFromJson([string]$ResultRow.Result) })
                $Job.PSObject.Properties.Add([psnoteproperty]::new('Result', $Result))
            }
            $Job
        }
        $Body = if ($Id) { @($Jobs)[0] } else { @($Jobs) }
        $StatusCode = [HttpStatusCode]::OK
    } catch {
        $ErrorMessage = Get-CippException -Exception $_
        Write-LogMessage -headers $Request.Headers -API $Request.Params.CIPPEndpoint -message "Failed to list cloud backup jobs: $($ErrorMessage.NormalizedError)" -sev Error -LogData $ErrorMessage
        return ([HttpResponseContext]@{
                StatusCode = Get-CippErrorStatusCode -ErrorRecord $_
                Body       = @{ Results = "Failed to list cloud backup jobs: $($ErrorMessage.NormalizedError)" }
            })
    }

    return ([HttpResponseContext]@{
            StatusCode = $StatusCode
            Body       = $Body
        })
}
