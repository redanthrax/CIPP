function Get-CIPPCloudEndpoint {
    <#
    .SYNOPSIS
        Returns the fixed identity and API hosts for a Microsoft cloud.
    .DESCRIPTION
        The single source of truth for which hosts CIPP talks to for a tenant's cloudEnvironment
        (redanthrax/CIPP#2, #3). Keyed on the three canonical values only:

            Commercial  login.microsoftonline.com  graph.microsoft.com      (also GCC Moderate)
            USGovHigh   login.microsoftonline.us   graph.microsoft.us
            USGovDoD    login.microsoftonline.us   dod-graph.microsoft.us

        The match is exact and case-sensitive. Anything else - empty, null, 'usgovhigh', a host
        name - throws, so an unexpected stored value can never fall back to commercial hosts or
        credentials. Every value below is a literal: no host is ever built from a stored value,
        a discovery document or request input.

        To add a service (#3: Exchange, Defender, ...), add a literal property to each entry.
    .PARAMETER CloudEnvironment
        Commercial, USGovHigh or USGovDoD (exact case).
    .OUTPUTS
        PSCustomObject with CloudEnvironment, IsGovernment, LoginHost, Authority, GraphHost, GraphUrl
        and GraphScope.
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$CloudEnvironment
    )

    if (-not $script:CIPPCloudEndpointMap) {
        # Ordinal comparer: 'usgovhigh' must not resolve to 'USGovHigh'.
        $Map = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
        $Map['Commercial'] = [pscustomobject]@{
            CloudEnvironment = 'Commercial'
            IsGovernment     = $false
            LoginHost        = 'login.microsoftonline.com'
            Authority        = 'https://login.microsoftonline.com'
            GraphHost        = 'graph.microsoft.com'
            GraphUrl         = 'https://graph.microsoft.com'
            GraphScope       = 'https://graph.microsoft.com/.default'
        }
        $Map['USGovHigh'] = [pscustomobject]@{
            CloudEnvironment = 'USGovHigh'
            IsGovernment     = $true
            LoginHost        = 'login.microsoftonline.us'
            Authority        = 'https://login.microsoftonline.us'
            GraphHost        = 'graph.microsoft.us'
            GraphUrl         = 'https://graph.microsoft.us'
            GraphScope       = 'https://graph.microsoft.us/.default'
        }
        $Map['USGovDoD'] = [pscustomobject]@{
            CloudEnvironment = 'USGovDoD'
            IsGovernment     = $true
            LoginHost        = 'login.microsoftonline.us'
            Authority        = 'https://login.microsoftonline.us'
            GraphHost        = 'dod-graph.microsoft.us'
            GraphUrl         = 'https://dod-graph.microsoft.us'
            GraphScope       = 'https://dod-graph.microsoft.us/.default'
        }
        $script:CIPPCloudEndpointMap = $Map
    }

    $Endpoint = $null
    if ([string]::IsNullOrEmpty($CloudEnvironment) -or -not $script:CIPPCloudEndpointMap.TryGetValue($CloudEnvironment, [ref]$Endpoint)) {
        # The value is not echoed: it can come from a table row or a request.
        throw 'Unknown cloud environment. Expected exactly Commercial, USGovHigh or USGovDoD.'
    }
    # A copy, so a caller changing a property cannot alter the map for everyone else.
    return $Endpoint.PSObject.Copy()
}
