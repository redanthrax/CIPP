function Receive-CIPPCloudBackupObjectStream {
    <#
    .SYNOPSIS
        Downloads an object (or one version of it) from a cloud backup destination into a stream in bounded ranges.
    .DESCRIPTION
        Returns { Key; VersionId; Bytes; ContentType; Metadata }, or $null when the object or version does not exist.
        The data is written as stored; decrypting it is the caller's job.
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

    switch ($Destination.Provider) {
        'AzureBlob' { Receive-CIPPCloudBackupAzureObjectStream @PSBoundParameters }
        'S3' { Receive-CIPPCloudBackupS3ObjectStream @PSBoundParameters }
        default { throw [System.ArgumentException]::new("Unknown cloud backup provider '$($Destination.Provider)'.") }
    }
}
