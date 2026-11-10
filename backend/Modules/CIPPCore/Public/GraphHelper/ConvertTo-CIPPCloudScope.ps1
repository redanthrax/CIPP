function ConvertTo-CIPPCloudScope {
    <#
    .SYNOPSIS
        Translates an OAuth scope string from commercial Graph to a tenant's cloud.
    .DESCRIPTION
        Callers ask Get-GraphToken for commercial scopes (https://graph.microsoft.com/.default).
        For a government tenant each Graph scope is rewritten onto that cloud's Graph host from
        Get-CIPPCloudEndpoint. OpenID scopes (openid, profile, offline_access, email) pass through.

        Any other resource - Exchange (outlook.office365.com), Partner Center, the Office 365
        Management API, SharePoint, a GUID resource - throws for a government tenant instead of
        being sent as is: a commercial resource cannot be issued by a government authority, and
        routing those hosts is redanthrax/CIPP#3. Commercial scopes are returned unchanged.
    .PARAMETER Scope
        A single scope or a space-separated list.
    .PARAMETER CloudEnvironment
        Commercial, USGovHigh or USGovDoD (exact case).
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Scope,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$CloudEnvironment
    )

    $Endpoint = Get-CIPPCloudEndpoint -CloudEnvironment $CloudEnvironment
    if (-not $Endpoint.IsGovernment) { return $Scope }

    $Commercial = Get-CIPPCloudEndpoint -CloudEnvironment 'Commercial'
    $CommercialPrefix = "$($Commercial.GraphUrl)/"
    $TargetPrefix = "$($Endpoint.GraphUrl)/"
    $PassThrough = @('openid', 'profile', 'offline_access', 'email')

    $Translated = foreach ($Item in ($Scope -split '\s+' | Where-Object { $_ })) {
        if ($Item.StartsWith($CommercialPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $TargetPrefix + $Item.Substring($CommercialPrefix.Length)
        } elseif ($Item.StartsWith($TargetPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $Item
        } elseif ($PassThrough -contains $Item) {
            $Item
        } else {
            # Name only the host, never the whole scope string.
            $ResourceHost = try { ([uri]$Item).Host } catch { $null }
            $Resource = if ($ResourceHost) { $ResourceHost } else { 'this resource' }
            throw "Tokens for $Resource are not yet supported for government tenants ($CloudEnvironment); only Microsoft Graph is (see redanthrax/CIPP#3)."
        }
    }
    if (-not $Translated) { throw 'No scope to request.' }
    return ($Translated -join ' ')
}
