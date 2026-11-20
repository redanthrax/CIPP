function Get-CIPPCloudBackupObject {
    <#
    .SYNOPSIS
        Downloads an object from a cloud backup destination as { Body; Metadata }, or $null when it does not exist.
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Destination,

        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    switch ($Destination.Provider) {
        'AzureBlob' { Get-CIPPCloudBackupAzureObject @PSBoundParameters }
        'S3' { Get-CIPPCloudBackupS3Object @PSBoundParameters }
        default { throw [System.ArgumentException]::new("Unknown cloud backup provider '$($Destination.Provider)'.") }
    }
}
