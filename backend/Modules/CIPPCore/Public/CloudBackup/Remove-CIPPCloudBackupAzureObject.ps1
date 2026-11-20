function Remove-CIPPCloudBackupAzureObject {
    <#
    .SYNOPSIS
        Deletes a blob and its snapshots from an Azure Blob cloud backup destination. A missing blob is not an error.
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        $Destination,

        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    if (-not $PSCmdlet.ShouldProcess($Key, 'Delete')) { return }

    $null = Invoke-CIPPCloudBackupAzureBlobRequest -Destination $Destination -Method 'DELETE' -Key $Key -Headers @{ 'x-ms-delete-snapshots' = 'include' } -AllowStatus 404
}
