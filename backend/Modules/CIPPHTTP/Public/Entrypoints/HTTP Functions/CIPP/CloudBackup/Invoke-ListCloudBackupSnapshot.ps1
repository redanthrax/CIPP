function Invoke-ListCloudBackupSnapshot {
    <#
    .FUNCTIONALITY
        Entrypoint,AnyTenant
    .ROLE
        CIPP.CloudBackup.Read
    .SYNOPSIS
        List the items in a cloud backup run
    .DESCRIPTION
        Reads a configuration backup from its destination and lists every backed-up item (Conditional Access, Intune, Exchange and SharePoint settings) with its section, name and the full backed-up object.
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    # Backup run id as returned by ListCloudBackupRuns
    $RunId = "$($Request.Query.RunId)"
    # Optional configuration area to list
    $Area = $Request.Query.Area

    if ($RunId -notmatch '^([0-9a-fA-F-]{36})_(\d{19}_[A-Za-z0-9.-]+)$' -or -not ($Matches[1] -as [guid])) {
        return ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::BadRequest
                Body       = @{ Results = 'RunId must be a backup run id from ListCloudBackupRuns' }
            })
    }
    $PolicyId = "$([guid]$Matches[1])"
    $RunKey = $Matches[2]
    if ($Area -and $Area -notin @('ConditionalAccess', 'Intune', 'Exchange', 'SharePoint')) {
        return ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::BadRequest
                Body       = @{ Results = 'Area must be ConditionalAccess, Intune, Exchange or SharePoint' }
            })
    }

    try {
        $RunsTable = Get-CIPPTable -TableName 'CloudBackupRuns'
        $Run = @(Get-CIPPAzDataTableEntity @RunsTable -Filter "PartitionKey eq '$PolicyId' and RowKey eq '$RunKey'")[0]
        if (-not $Run) {
            return ([HttpResponseContext]@{
                    StatusCode = [HttpStatusCode]::NotFound
                    Body       = @{ Results = "Backup run $RunId was not found" }
                })
        }
        $AllowedTenants = @(Test-CIPPAccess -Request $Request -TenantList)
        if ($AllowedTenants -notcontains 'AllTenants' -and $AllowedTenants -notcontains $Run.TenantId) {
            return ([HttpResponseContext]@{
                    StatusCode = [HttpStatusCode]::Forbidden
                    Body       = @{ Results = 'You do not have access to the tenant of this backup' }
                })
        }

        $SnapshotParams = @{ RunId = $RunId }
        if ($Area) { $SnapshotParams.Area = @($Area) }
        $Snapshot = Get-CIPPCloudBackupSnapshot @SnapshotParams

        $Body = foreach ($AreaName in @($Snapshot.Areas.Keys)) {
            $Sections = $Snapshot.Areas[$AreaName].Sections
            foreach ($Section in @($Sections.Keys)) {
                $Label = Get-CIPPCloudBackupSectionLabel -Section $Section
                $Entries = @(foreach ($Entry in @($Sections[$Section])) { if ($null -ne $Entry) { $Entry } })
                if ($Entries.Count -eq 0) { continue }
                $Infos = @(Get-CIPPCloudBackupItemInfo -Section $Section -Item $Entries)
                for ($i = 0; $i -lt $Entries.Count; $i++) {
                    [pscustomobject]@{
                        Area         = $AreaName
                        Section      = $Section
                        SectionLabel = $Label
                        Key          = $Infos[$i].Key
                        Name         = $Infos[$i].Name
                        Item         = $Entries[$i]
                    }
                }
            }
        }
        $StatusCode = [HttpStatusCode]::OK
    } catch {
        $ErrorMessage = Get-CippException -Exception $_
        Write-LogMessage -headers $Request.Headers -API $Request.Params.CIPPEndpoint -message "Failed to read cloud backup $($RunId): $($ErrorMessage.NormalizedError)" -sev Error -LogData $ErrorMessage
        return ([HttpResponseContext]@{
                StatusCode = Get-CippErrorStatusCode -ErrorRecord $_
                Body       = @{ Results = "Failed to read the backup: $($ErrorMessage.NormalizedError)" }
            })
    }

    return ([HttpResponseContext]@{
            StatusCode = $StatusCode
            Body       = @($Body)
        })
}
