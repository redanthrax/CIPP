function Set-CIPPCloudBackupAzureRetentionRule {
    <#
    .SYNOPSIS
        Creates or replaces a lifecycle management rule that deletes blobs under a prefix after a number of days, keeping every other rule.
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        $Destination,

        [Parameter(Mandatory = $true)]
        [string]$RuleName,

        [Parameter(Mandatory = $true)]
        [string]$Prefix,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 36500)]
        [int]$Days
    )

    if ($RuleName -notmatch '^[A-Za-z0-9-]{1,256}$') {
        throw [System.ArgumentException]::new("'$RuleName' is not a valid lifecycle rule name.")
    }
    if (-not $PSCmdlet.ShouldProcess($RuleName, 'Set lifecycle rule')) { return }

    $Policy = Invoke-CIPPCloudBackupAzureManagementRequest -Destination $Destination -Method 'GET' -Path 'managementPolicies/default' -AllowNotFound
    $Rules = [System.Collections.Generic.List[object]]::new()
    foreach ($Rule in @($Policy.properties.policy.rules)) {
        if ($null -ne $Rule -and $Rule.name -ne $RuleName) { $Rules.Add($Rule) }
    }
    $Rules.Add([ordered]@{
            enabled    = $true
            name       = $RuleName
            type       = 'Lifecycle'
            definition = [ordered]@{
                actions = [ordered]@{
                    baseBlob = [ordered]@{ delete = [ordered]@{ daysAfterModificationGreaterThan = $Days } }
                }
                filters = [ordered]@{
                    blobTypes   = @('blockBlob')
                    prefixMatch = @("$($Destination.Container)/$Prefix")
                }
            }
        })

    $null = Invoke-CIPPCloudBackupAzureManagementRequest -Destination $Destination -Method 'PUT' -Path 'managementPolicies/default' -Body @{ properties = @{ policy = @{ rules = $Rules.ToArray() } } }
}
