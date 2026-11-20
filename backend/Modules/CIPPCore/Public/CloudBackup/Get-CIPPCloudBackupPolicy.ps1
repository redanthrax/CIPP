function Get-CIPPCloudBackupPolicy {
    <#
    .SYNOPSIS
        Cloud backup policies from the Config table, with their JSON columns parsed.
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [string]$Id
    )

    $Filter = "PartitionKey eq 'CloudBackupPolicy'"
    if ($Id) {
        $Guid = $Id -as [guid]
        if (-not $Guid) { return }
        $Filter = "$Filter and RowKey eq '$Guid'"
    }

    $Table = Get-CIPPTable -TableName 'Config'
    foreach ($Row in @(Get-CIPPAzDataTableEntity @Table -Filter $Filter)) {
        [pscustomobject]@{
            Id             = $Row.RowKey
            Name           = $Row.Name
            Enabled        = "$($Row.Enabled)" -eq 'True'
            DestinationId  = $Row.DestinationId
            Tenants        = @(if ($Row.Tenants) { [CIPP.CippJson]::ConvertFromJson([string]$Row.Tenants) })
            ConfigAreas    = @(if ($Row.ConfigAreas) { [CIPP.CippJson]::ConvertFromJson([string]$Row.ConfigAreas) })
            ConfigSchedule = $Row.ConfigSchedule
            ConfigNextRun  = $Row.ConfigNextRun
            RetentionDays  = ($Row.RetentionDays -as [int]) ?? 90
            Encryption     = "$($Row.Encryption)" -eq 'True'
            CurrentKeyId   = "$($Row.CurrentKeyId)"
            KeyIds         = @(if ($Row.KeyIds) { [CIPP.CippJson]::ConvertFromJson([string]$Row.KeyIds) })
        }
    }
}
