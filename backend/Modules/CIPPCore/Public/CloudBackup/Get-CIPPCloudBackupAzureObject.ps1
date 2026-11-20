function Get-CIPPCloudBackupAzureObject {
    <#
    .SYNOPSIS
        Downloads a blob from an Azure Blob cloud backup destination as { Body; Metadata }, or $null when it does not exist.
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

    $Response = Invoke-CIPPCloudBackupAzureBlobRequest -Destination $Destination -Method 'GET' -Key $Key -AllowStatus 404
    if ($Response.StatusCode -eq 404) { return $null }

    $Metadata = @{}
    foreach ($Name in $Response.Headers.Keys) {
        if ($Name -like 'x-ms-meta-*') {
            $Metadata[$Name.Substring(10)] = @($Response.Headers[$Name])[0]
        }
    }
    return [pscustomobject]@{ Body = $Response.Body; Metadata = $Metadata }
}
