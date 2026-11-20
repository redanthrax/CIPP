function Receive-CIPPCloudBackupS3ObjectStream {
    <#
    .SYNOPSIS
        Downloads an object (or one version of it) from an S3 cloud backup destination into a stream in 8 MiB ranges.
    .DESCRIPTION
        Returns { Key; VersionId; Bytes; ContentType; Metadata }, or $null when it does not exist. Ranges carry If-Match,
        so an object replaced during the download fails instead of mixing two versions.
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Destination,
        [Parameter(Mandatory)][string]$Key,
        [string]$VersionId,
        [Parameter(Mandatory)][System.IO.Stream]$OutStream
    )

    $Query = @{}
    if ($VersionId) { $Query['versionId'] = $VersionId }
    try {
        $Head = Invoke-CIPPS3Request -Destination $Destination -Method HEAD -Key $Key -Query $Query
    } catch {
        if ($_.Exception.Data['S3ErrorCode'] -in @('NoSuchKey', 'NotFound', 'NoSuchVersion')) { return $null }
        throw
    }

    $Length = [int64]$Head.Headers['Content-Length']
    $ETag = [string]$Head.Headers['ETag']
    $Metadata = @{}
    foreach ($Name in $Head.Headers.Keys) {
        if ($Name.StartsWith('x-amz-meta-', [System.StringComparison]::OrdinalIgnoreCase)) { $Metadata[$Name.Substring(11)] = $Head.Headers[$Name] }
    }

    $Offset = [int64]0
    while ($Offset -lt $Length) {
        $End = [Math]::Min($Offset + 8MB, $Length) - 1
        $Response = Invoke-CIPPS3Request -Destination $Destination -Method GET -Key $Key -Query $Query -Headers @{ Range = "bytes=$Offset-$End"; 'If-Match' = $ETag }
        if ($Response.Body.Length -eq 0) { throw "S3 returned no data for object '$Key' at byte $Offset" }
        $OutStream.Write($Response.Body, 0, $Response.Body.Length)
        $Offset += $Response.Body.Length
    }

    [pscustomobject]@{
        Key         = $Key
        VersionId   = $Head.Headers['x-amz-version-id']
        Bytes       = $Length
        ContentType = $Head.Headers['Content-Type']
        Metadata    = $Metadata
    }
}
