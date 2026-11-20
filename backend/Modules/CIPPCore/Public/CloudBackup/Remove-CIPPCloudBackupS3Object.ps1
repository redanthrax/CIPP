function Remove-CIPPCloudBackupS3Object {
    <#
    .SYNOPSIS
        Deletes an object from an S3 cloud backup destination.
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]$Destination,
        [Parameter(Mandatory)][string]$Key
    )

    if ($PSCmdlet.ShouldProcess($Key, 'Delete S3 object')) {
        $null = Invoke-CIPPS3Request -Destination $Destination -Method DELETE -Key $Key
    }
}
