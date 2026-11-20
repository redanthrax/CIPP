function Receive-CIPPCloudBackupAzureObjectStream {
    <#
    .SYNOPSIS
        Downloads a blob (or one version of it) from an Azure Blob cloud backup destination into a stream in 8 MiB ranges.
    .DESCRIPTION
        Returns { Key; VersionId; Bytes; ContentType; Metadata }, or $null when it does not exist. Ranges after the first
        request carry If-Match, so a blob replaced during the download fails instead of mixing two versions.
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Destination,

        [Parameter(Mandatory = $true)]
        [string]$Key,

        [string]$VersionId,

        [Parameter(Mandatory = $true)]
        [System.IO.Stream]$OutStream
    )

    $Query = [ordered]@{}
    if ($VersionId) { $Query.versionid = $VersionId }
    $Head = Invoke-CIPPCloudBackupAzureBlobRequest -Destination $Destination -Method 'HEAD' -Key $Key -Query $Query -AllowStatus 404
    if ($Head.StatusCode -eq 404) { return $null }

    $Length = [int64]@($Head.Headers['Content-Length'])[0]
    $ETag = [string]@($Head.Headers['ETag'])[0]
    $Metadata = @{}
    foreach ($Name in $Head.Headers.Keys) {
        if ($Name -like 'x-ms-meta-*') { $Metadata[$Name.Substring(10)] = @($Head.Headers[$Name])[0] }
    }

    $Offset = [int64]0
    while ($Offset -lt $Length) {
        $End = [Math]::Min($Offset + 8MB, $Length) - 1
        $Response = Invoke-CIPPCloudBackupAzureBlobRequest -Destination $Destination -Method 'GET' -Key $Key -Query $Query -Headers @{ 'x-ms-range' = "bytes=$Offset-$End"; 'If-Match' = $ETag }
        if ($Response.Body.Length -eq 0) { throw "Azure Storage returned no data for '$Key' at byte $Offset." }
        $OutStream.Write($Response.Body, 0, $Response.Body.Length)
        $Offset += $Response.Body.Length
    }

    [pscustomobject]@{
        Key         = $Key
        VersionId   = @($Head.Headers['x-ms-version-id'])[0]
        Bytes       = $Length
        ContentType = @($Head.Headers['Content-Type'])[0]
        Metadata    = $Metadata
    }
}
