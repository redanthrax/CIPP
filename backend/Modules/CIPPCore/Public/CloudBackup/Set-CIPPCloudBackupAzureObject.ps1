function Set-CIPPCloudBackupAzureObject {
    <#
    .SYNOPSIS
        Uploads a block blob to an Azure Blob cloud backup destination.
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        $Destination,

        [Parameter(Mandatory = $true)]
        [string]$Key,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]]$Body,

        [string]$ContentType = 'application/octet-stream',

        [hashtable]$Metadata
    )

    if (-not $PSCmdlet.ShouldProcess($Key, 'Upload')) { return }

    $Headers = @{ 'x-ms-blob-type' = 'BlockBlob' }
    if ($Metadata) {
        foreach ($Name in $Metadata.Keys) {
            if ($Name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
                throw [System.ArgumentException]::new("'$Name' is not a valid metadata name.")
            }
            $Headers["x-ms-meta-$Name"] = [string]$Metadata[$Name]
        }
    }

    $null = Invoke-CIPPCloudBackupAzureBlobRequest -Destination $Destination -Method 'PUT' -Key $Key -Body $Body -ContentType $ContentType -Headers $Headers
}
