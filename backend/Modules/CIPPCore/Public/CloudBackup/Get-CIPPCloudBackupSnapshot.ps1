function Get-CIPPCloudBackupSnapshot {
    <#
    .SYNOPSIS
        Reads a Cloud Backup run back from its destination as { Run; Manifest; Areas }
    .DESCRIPTION
        RunId is the Id ListCloudBackupRuns returns. Each area file is checked against the manifest's SHA-256,
        decrypted when needed and parsed. Area limits the result to those areas.
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunId,
        [string[]]$Area
    )

    $PolicyId = if ($RunId.Length -gt 37 -and $RunId[36] -eq '_') { $RunId.Substring(0, 36) -as [guid] }
    $RowKey = if ($PolicyId) { $RunId.Substring(37) }
    if (-not $PolicyId -or $RowKey -notmatch '^\d{19}_[A-Za-z0-9-]+$') {
        throw [System.ArgumentException]::new("'$RunId' is not a valid backup run id.")
    }

    $RunsTable = Get-CIPPTable -TableName 'CloudBackupRuns'
    $Row = @(Get-CIPPAzDataTableEntity @RunsTable -Filter "PartitionKey eq '$PolicyId' and RowKey eq '$RowKey'")[0]
    if (-not $Row) {
        throw [System.Management.Automation.ItemNotFoundException]::new("Backup run $RunId was not found.")
    }
    $Run = [pscustomobject]@{
        Id            = $RunId
        PolicyId      = "$($Row.PolicyId)"
        PolicyName    = $Row.PolicyName
        DestinationId = "$($Row.DestinationId)"
        TenantId      = "$($Row.TenantId)"
        Tenant        = $Row.Tenant
        Workload      = $Row.Workload
        Status        = $Row.Status
        StartedAt     = if ($Row.StartedAt) { "$($Row.StartedAt)" } else { $null }
        CompletedAt   = if ($Row.CompletedAt) { "$($Row.CompletedAt)" } else { $null }
        Items         = [int]$Row.Items
        Bytes         = [int64]$Row.Bytes
        Areas         = @(if ($Row.Areas) { [CIPP.CippJson]::ConvertFromJson([string]$Row.Areas) })
        Warnings      = @(if ($Row.Warnings) { [CIPP.CippJson]::ConvertFromJson([string]$Row.Warnings) })
        Location      = "$($Row.Location)"
    }
    if (-not $Run.Location) {
        throw [System.Management.Automation.ItemNotFoundException]::new("Backup run $RunId stored no data.")
    }

    $DestinationId = "$($Row.DestinationId)"
    if (-not $DestinationId) {
        $Policy = Get-CIPPCloudBackupPolicy -Id "$PolicyId"
        if (-not $Policy) {
            throw [System.Management.Automation.ItemNotFoundException]::new("The backup policy of run $RunId no longer exists.")
        }
        $DestinationId = "$($Policy.DestinationId)"
    }
    $Destination = Get-CIPPCloudBackupDestination -Id $DestinationId -IncludeSecret
    if (-not $Destination) {
        throw [System.Management.Automation.ItemNotFoundException]::new("The storage destination of backup run $RunId no longer exists.")
    }

    $ManifestObject = Get-CIPPCloudBackupObject -Destination $Destination -Key "$($Run.Location)manifest.json"
    if (-not $ManifestObject) {
        throw [System.Management.Automation.ItemNotFoundException]::new("The manifest of backup run $RunId was not found in $($Destination.Name).")
    }
    $Manifest = [CIPP.CippJson]::ConvertFromJson([System.Text.Encoding]::UTF8.GetString([byte[]]$ManifestObject.Body))

    $Areas = [ordered]@{}
    foreach ($Entry in @($Manifest.Areas)) {
        $AreaName = [string]$Entry.Area
        if ($Area -and $AreaName -notin $Area) { continue }

        $Object = Get-CIPPCloudBackupObject -Destination $Destination -Key ([string]$Entry.Key)
        if (-not $Object) {
            throw [System.Management.Automation.ItemNotFoundException]::new("The $AreaName file of backup run $RunId was not found in $($Destination.Name).")
        }
        $Bytes = [byte[]]$Object.Body
        $Object = $null
        $Hash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
        if ($Hash -ne ([string]$Entry.Sha256).ToLowerInvariant()) {
            throw "The $AreaName file of backup run $RunId does not match its checksum: it has been changed or is damaged."
        }
        if (([string]$Entry.Key).EndsWith('.enc')) { $Bytes = Unprotect-CIPPCloudBackupData -Bytes $Bytes }

        $Reader = [System.IO.StreamReader]::new([System.IO.Compression.GZipStream]::new([System.IO.MemoryStream]::new($Bytes), [System.IO.Compression.CompressionMode]::Decompress), [System.Text.UTF8Encoding]::new($false))
        try { $Json = $Reader.ReadToEnd() } finally { $Reader.Dispose() }
        $Bytes = $null
        $Document = [CIPP.CippJson]::ConvertFromJson($Json)
        $Json = $null

        $Sections = [ordered]@{}
        if ($null -ne $Document.Sections) {
            foreach ($Property in $Document.Sections.PSObject.Properties) {
                $Sections[$Property.Name] = [object[]]@(foreach ($Item in $Property.Value) { $Item })
            }
        }
        $References = @{ Groups = @{}; Users = @{} }
        foreach ($Kind in 'Groups', 'Users') {
            $Source = $Document.References.$Kind
            if ($null -eq $Source) { continue }
            foreach ($Property in $Source.PSObject.Properties) { $References[$Kind][$Property.Name] = [string]$Property.Value }
        }
        $Areas[$AreaName] = [pscustomobject]@{ Sections = $Sections; References = $References }
        $Document = $null
    }

    [pscustomobject]@{ Run = $Run; Manifest = $Manifest; Areas = $Areas }
}
