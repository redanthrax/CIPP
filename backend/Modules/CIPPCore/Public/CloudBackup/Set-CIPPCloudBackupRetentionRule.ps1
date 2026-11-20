function Set-CIPPCloudBackupRetentionRule {
    <#
    .SYNOPSIS
        Creates or replaces a lifecycle rule that deletes objects under a prefix after a number of days, keeping every other rule.
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

    if (-not $PSCmdlet.ShouldProcess($RuleName, 'Set lifecycle rule')) { return }

    $null = $PSBoundParameters.Remove('WhatIf')
    $null = $PSBoundParameters.Remove('Confirm')
    switch ($Destination.Provider) {
        'AzureBlob' { Set-CIPPCloudBackupAzureRetentionRule @PSBoundParameters }
        'S3' { Set-CIPPCloudBackupS3RetentionRule @PSBoundParameters }
        default { throw [System.ArgumentException]::new("Unknown cloud backup provider '$($Destination.Provider)'.") }
    }
}
