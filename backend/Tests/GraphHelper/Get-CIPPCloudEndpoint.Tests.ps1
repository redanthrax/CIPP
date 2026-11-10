# Pester tests for the fixed cloud map (redanthrax/CIPP#2, #3 security requirements):
#   - each canonical value maps to literal hosts
#   - unknown, empty and wrongly cased values throw (fail closed, never commercial)
#   - scope translation never sends a commercial resource for a government tenant
#   - the access token classifier only accepts known audiences and issuers

BeforeAll {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    . (Join-Path $RepoRoot 'Modules/CIPPCore/Public/GraphHelper/Get-CIPPCloudEndpoint.ps1')
    . (Join-Path $RepoRoot 'Modules/CIPPCore/Public/GraphHelper/ConvertTo-CIPPCloudScope.ps1')
    . (Join-Path $RepoRoot 'Modules/CIPPCore/Public/GraphHelper/Get-CIPPAccessTokenCloudEnvironment.ps1')

    function New-TestJwt {
        param([hashtable]$Claims)
        $Encode = { param($Text) [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text)).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
        '{0}.{1}.sig' -f (& $Encode '{"alg":"RS256","typ":"JWT"}'), (& $Encode ($Claims | ConvertTo-Json -Compress))
    }
}

Describe 'Get-CIPPCloudEndpoint' {
    It 'maps <Cloud> to literal hosts' -TestCases @(
        @{ Cloud = 'Commercial'; Login = 'login.microsoftonline.com'; Graph = 'graph.microsoft.com'; Gov = $false }
        @{ Cloud = 'USGovHigh'; Login = 'login.microsoftonline.us'; Graph = 'graph.microsoft.us'; Gov = $true }
        @{ Cloud = 'USGovDoD'; Login = 'login.microsoftonline.us'; Graph = 'dod-graph.microsoft.us'; Gov = $true }
    ) {
        param($Cloud, $Login, $Graph, $Gov)
        $Endpoint = Get-CIPPCloudEndpoint -CloudEnvironment $Cloud
        $Endpoint.CloudEnvironment | Should -BeExactly $Cloud
        $Endpoint.IsGovernment | Should -Be $Gov
        $Endpoint.LoginHost | Should -BeExactly $Login
        $Endpoint.Authority | Should -BeExactly "https://$Login"
        $Endpoint.GraphHost | Should -BeExactly $Graph
        $Endpoint.GraphUrl | Should -BeExactly "https://$Graph"
        $Endpoint.GraphScope | Should -BeExactly "https://$Graph/.default"
    }

    It 'throws for <Name>' -TestCases @(
        @{ Name = 'an empty value'; Value = '' }
        @{ Name = 'null'; Value = $null }
        @{ Name = 'lower case'; Value = 'usgovhigh' }
        @{ Name = 'upper case'; Value = 'COMMERCIAL' }
        @{ Name = 'trailing whitespace'; Value = 'USGovHigh ' }
        @{ Name = 'a trailing newline'; Value = "USGovDoD`n" }
        @{ Name = 'an unknown cloud'; Value = 'China' }
        @{ Name = 'a host name'; Value = 'graph.microsoft.us' }
    ) {
        param($Name, $Value)
        { Get-CIPPCloudEndpoint -CloudEnvironment $Value } | Should -Throw '*Unknown cloud environment*'
    }

    It 'does not echo the rejected value' {
        try { Get-CIPPCloudEndpoint -CloudEnvironment 'evil.example' } catch { $_.Exception.Message | Should -Not -BeLike '*evil.example*' }
    }

    It 'returns a copy, so a caller cannot change the map' {
        $First = Get-CIPPCloudEndpoint -CloudEnvironment 'USGovHigh'
        $First.GraphHost = 'evil.example'
        (Get-CIPPCloudEndpoint -CloudEnvironment 'USGovHigh').GraphHost | Should -BeExactly 'graph.microsoft.us'
    }
}

Describe 'ConvertTo-CIPPCloudScope' {
    It 'returns commercial scopes unchanged' {
        ConvertTo-CIPPCloudScope -Scope 'https://outlook.office365.com/.default' -CloudEnvironment 'Commercial' | Should -BeExactly 'https://outlook.office365.com/.default'
    }

    It 'rewrites the Graph .default scope for <Cloud>' -TestCases @(
        @{ Cloud = 'USGovHigh'; Expected = 'https://graph.microsoft.us/.default' }
        @{ Cloud = 'USGovDoD'; Expected = 'https://dod-graph.microsoft.us/.default' }
    ) {
        param($Cloud, $Expected)
        ConvertTo-CIPPCloudScope -Scope 'https://graph.microsoft.com/.default' -CloudEnvironment $Cloud | Should -BeExactly $Expected
    }

    It 'rewrites every Graph scope in a list and keeps OpenID scopes' {
        $Result = ConvertTo-CIPPCloudScope -Scope 'https://graph.microsoft.com/Directory.ReadWrite.All https://graph.microsoft.com/AppRoleAssignment.ReadWrite.All offline_access profile openid' -CloudEnvironment 'USGovHigh'
        $Result | Should -BeExactly 'https://graph.microsoft.us/Directory.ReadWrite.All https://graph.microsoft.us/AppRoleAssignment.ReadWrite.All offline_access profile openid'
        $Result | Should -Not -BeLike '*microsoft.com*'
    }

    It 'leaves a scope already on the tenant''s Graph host alone' {
        ConvertTo-CIPPCloudScope -Scope 'https://dod-graph.microsoft.us/.default' -CloudEnvironment 'USGovDoD' | Should -BeExactly 'https://dod-graph.microsoft.us/.default'
    }

    It 'throws for a non-Graph resource on a government tenant: <Scope>' -TestCases @(
        @{ Scope = 'https://outlook.office365.com/.default' }
        @{ Scope = 'https://api.partnercenter.microsoft.com/.default' }
        @{ Scope = 'https://manage.office.com/.default' }
        @{ Scope = 'https://graph.microsoft.com.evil.example/.default' }
        @{ Scope = '00000002-0000-0ff1-ce00-000000000000/.default' }
    ) {
        param($Scope)
        { ConvertTo-CIPPCloudScope -Scope $Scope -CloudEnvironment 'USGovHigh' } | Should -Throw '*not yet supported for government tenants*'
    }

    It 'does not accept the GCC High Graph host for a DoD tenant' {
        { ConvertTo-CIPPCloudScope -Scope 'https://graph.microsoft.us/.default' -CloudEnvironment 'USGovDoD' } | Should -Throw '*not yet supported*'
    }

    It 'throws for an unknown cloud' {
        { ConvertTo-CIPPCloudScope -Scope 'https://graph.microsoft.com/.default' -CloudEnvironment 'usgovhigh' } | Should -Throw '*Unknown cloud environment*'
    }
}

Describe 'Get-CIPPAccessTokenCloudEnvironment' {
    It 'classifies a <Name>' -TestCases @(
        @{ Name = 'commercial v1 token'; Aud = 'https://graph.microsoft.com'; Iss = 'https://sts.windows.net/t/'; Cloud = 'Commercial'; Family = 'Commercial' }
        @{ Name = 'commercial v2 token'; Aud = 'https://graph.microsoft.com/'; Iss = 'https://login.microsoftonline.com/t/v2.0'; Cloud = 'Commercial'; Family = 'Commercial' }
        @{ Name = 'GCC High v1 token'; Aud = 'https://graph.microsoft.us'; Iss = 'https://sts.windows.net/t/'; Cloud = 'USGovHigh'; Family = 'Government' }
        @{ Name = 'GCC High v2 token'; Aud = 'https://graph.microsoft.us'; Iss = 'https://login.microsoftonline.us/t/v2.0'; Cloud = 'USGovHigh'; Family = 'Government' }
        @{ Name = 'DoD v2 token'; Aud = 'https://dod-graph.microsoft.us'; Iss = 'https://login.microsoftonline.us/t/v2.0'; Cloud = 'USGovDoD'; Family = 'Government' }
        @{ Name = 'Graph app id token from the commercial authority'; Aud = '00000003-0000-0000-c000-000000000000'; Iss = 'https://login.microsoftonline.com/t/v2.0'; Cloud = $null; Family = 'Commercial' }
        @{ Name = 'Graph app id token from the government authority'; Aud = '00000003-0000-0000-c000-000000000000'; Iss = 'https://login.microsoftonline.us/t/v2.0'; Cloud = $null; Family = 'Government' }
        @{ Name = 'Graph app id v1 token'; Aud = '00000003-0000-0000-c000-000000000000'; Iss = 'https://sts.windows.net/t/'; Cloud = $null; Family = $null }
    ) {
        param($Name, $Aud, $Iss, $Cloud, $Family)
        $Result = Get-CIPPAccessTokenCloudEnvironment -AccessToken (New-TestJwt @{ aud = $Aud; iss = $Iss; tid = 't' })
        $Result.CloudEnvironment | Should -Be $Cloud
        $Result.Family | Should -Be $Family
    }

    It 'rejects <Name>' -TestCases @(
        @{ Name = 'an unknown audience'; Claims = @{ aud = 'https://graph.microsoft.de'; iss = 'https://sts.windows.net/t/' }; Message = '*known Microsoft Graph cloud*' }
        @{ Name = 'a look-alike audience'; Claims = @{ aud = 'https://graph.microsoft.us.evil.example'; iss = 'https://sts.windows.net/t/' }; Message = '*known Microsoft Graph cloud*' }
        @{ Name = 'a miscased audience'; Claims = @{ aud = 'https://Graph.Microsoft.US'; iss = 'https://sts.windows.net/t/' }; Message = '*known Microsoft Graph cloud*' }
        @{ Name = 'a missing audience'; Claims = @{ iss = 'https://sts.windows.net/t/' }; Message = '*known Microsoft Graph cloud*' }
        @{ Name = 'an unknown issuer'; Claims = @{ aud = 'https://graph.microsoft.us'; iss = 'https://login.evil.example/t/' }; Message = '*unknown authority*' }
        @{ Name = 'an http issuer'; Claims = @{ aud = 'https://graph.microsoft.us'; iss = 'http://login.microsoftonline.us/t/' }; Message = '*usable issuer*' }
        @{ Name = 'a missing issuer'; Claims = @{ aud = 'https://graph.microsoft.us' }; Message = '*usable issuer*' }
        @{ Name = 'a commercial issuer with a government audience'; Claims = @{ aud = 'https://graph.microsoft.us'; iss = 'https://login.microsoftonline.com/t/v2.0' }; Message = '*different clouds*' }
        @{ Name = 'a government issuer with a commercial audience'; Claims = @{ aud = 'https://graph.microsoft.com'; iss = 'https://login.microsoftonline.us/t/v2.0' }; Message = '*different clouds*' }
    ) {
        param($Name, $Claims, $Message)
        { Get-CIPPAccessTokenCloudEnvironment -AccessToken (New-TestJwt $Claims) } | Should -Throw $Message
    }

    It 'rejects a value that is not a JWT: <Value>' -TestCases @(
        @{ Value = '' }
        @{ Value = 'token' }
        @{ Value = 'a.b' }
        @{ Value = 'a.!!!.c' }
        @{ Value = 'a.bm90IGpzb24.c' }
    ) {
        param($Value)
        { Get-CIPPAccessTokenCloudEnvironment -AccessToken $Value } | Should -Throw
    }
}
