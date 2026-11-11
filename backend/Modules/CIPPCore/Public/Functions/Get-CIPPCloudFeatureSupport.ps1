function Get-CIPPCloudFeatureSupport {
    <#
    .SYNOPSIS
        Returns the support-matrix entry that marks a feature unsupported in a cloud, or nothing.
    .DESCRIPTION
        Reads Config\cloudFeatureSupport.json (redanthrax/CIPP#4), the same file the frontend imports
        as src/data/cloudFeatureSupport.json. The file lists features a government cloud does not
        support; Commercial is never listed, so for Commercial (or no cloud) this returns nothing
        without reading the file.

        The entry comes back with its source's reason and evidence attached.
    .PARAMETER Type
        The matrix section: pages, actions, standards, baselineStandards, alerts, tests, cacheTypes or timers.
    .PARAMETER Name
        The feature's key in that section (standard name, cache type, test id, alert name, ...).
    .PARAMETER CloudEnvironment
        Commercial, USGovHigh or USGovDoD.
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('pages', 'actions', 'standards', 'baselineStandards', 'alerts', 'tests', 'cacheTypes', 'timers')]
        [string]$Type,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [string]$CloudEnvironment
    )

    if ([string]::IsNullOrEmpty($CloudEnvironment) -or $CloudEnvironment -ceq 'Commercial') { return }

    if (-not $script:CIPPCloudFeatureSupport) {
        $Path = Join-Path $env:CIPPRootPath 'Config\cloudFeatureSupport.json'
        $Matrix = [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json
        $Index = @{}
        foreach ($Section in @('pages', 'actions', 'standards', 'baselineStandards', 'alerts', 'tests', 'cacheTypes', 'timers')) {
            $Lookup = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($Entry in @($Matrix.$Section)) {
                $Key = $Entry.name ?? $Entry.path ?? $Entry.url
                $Source = $Matrix.sources.($Entry.source)
                $Lookup[$Key] = [PSCustomObject]@{
                    Name              = $Key
                    UnsupportedClouds = @($Entry.unsupportedClouds)
                    Source            = $Entry.source
                    Reason            = $Source.reason
                    Evidence          = $Source.evidence
                }
            }
            $Index[$Section] = $Lookup
        }
        $script:CIPPCloudFeatureSupport = $Index
    }

    $Entry = $null
    if ($script:CIPPCloudFeatureSupport[$Type].TryGetValue($Name, [ref]$Entry) -and $Entry.UnsupportedClouds -ccontains $CloudEnvironment) {
        return $Entry
    }
}
