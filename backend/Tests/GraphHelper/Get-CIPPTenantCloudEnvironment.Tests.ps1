# Pester tests for Get-CIPPTenantCloudEnvironment
#
# Every tenant row records the Microsoft cloud it lives in so token and endpoint routing can branch
# on it (redanthrax/CIPP#1). Detection runs while a tenant is being added, so it must never throw,
# must never build a discovery URL from unchecked input, and must fall back to Commercial.

BeforeAll {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))

    function Write-LogMessage { param($API, $tenant, $tenantid, $message, $Sev, $LogData, $headers) }

    . (Join-Path $RepoRoot 'Modules/CIPPCore/Public/GraphHelper/Get-CIPPTenantCloudEnvironment.ps1')

    $script:TenantGuid = '11111111-2222-3333-4444-555555555555'

    function New-Discovery {
        param($Instance = 'microsoftonline.com', $Scope = 'NA', $SubScope)
        $Doc = [ordered]@{ cloud_instance_name = $Instance; tenant_region_scope = $Scope }
        if ($SubScope) { $Doc.tenant_region_sub_scope = $SubScope }
        [PSCustomObject]$Doc
    }
}

Describe 'Get-CIPPTenantCloudEnvironment' {
    BeforeEach {
        Mock Write-LogMessage {}
    }

    Context 'OpenID discovery' {
        It 'returns <Expected> for instance <Instance>, scope <Scope>, sub scope <SubScope>' -TestCases @(
            @{ Instance = 'microsoftonline.com'; Scope = 'NA'; SubScope = $null; Expected = 'Commercial' }
            @{ Instance = 'microsoftonline.com'; Scope = 'EU'; SubScope = $null; Expected = 'Commercial' }
            @{ Instance = 'microsoftonline.com'; Scope = 'NA'; SubScope = 'GCC'; Expected = 'Commercial' }
            @{ Instance = 'microsoftonline.us'; Scope = 'USGov'; SubScope = 'DODCON'; Expected = 'USGovHigh' }
            @{ Instance = 'microsoftonline.us'; Scope = 'USGov'; SubScope = $null; Expected = 'USGovHigh' }
            @{ Instance = 'microsoftonline.us'; Scope = 'USGov'; SubScope = 'DOD'; Expected = 'USGovDoD' }
            @{ Instance = 'microsoftonline.com'; Scope = 'USGov'; SubScope = $null; Expected = 'USGovHigh' }
        ) {
            param($Instance, $Scope, $SubScope, $Expected)
            Mock Invoke-RestMethod { New-Discovery -Instance $Instance -Scope $Scope -SubScope $SubScope }
            Get-CIPPTenantCloudEnvironment -TenantId $script:TenantGuid -InitialDomainName 'contoso.onmicrosoft.com' | Should -Be $Expected
        }

        It 'queries the commercial login endpoint for the tenant' {
            Mock Invoke-RestMethod { New-Discovery }
            $null = Get-CIPPTenantCloudEnvironment -TenantId $script:TenantGuid
            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
                $Uri -eq "https://login.microsoftonline.com/$($script:TenantGuid)/v2.0/.well-known/openid-configuration"
            }
        }

        It 'accepts a domain as tenant id' {
            Mock Invoke-RestMethod { New-Discovery -Instance 'microsoftonline.us' -Scope 'USGov' -SubScope 'DODCON' }
            Get-CIPPTenantCloudEnvironment -TenantId 'contoso.onmicrosoft.us' | Should -Be 'USGovHigh'
            Should -Invoke Invoke-RestMethod -Times 1
        }

        It 'trusts an onmicrosoft.us initial domain over a commercial discovery answer' {
            Mock Invoke-RestMethod { New-Discovery }
            Get-CIPPTenantCloudEnvironment -TenantId $script:TenantGuid -InitialDomainName 'contoso.onmicrosoft.us' | Should -Be 'USGovHigh'
        }
    }

    Context 'fallback' {
        It 'falls back to Commercial and logs when discovery fails' {
            Mock Invoke-RestMethod { throw 'network down' }
            Get-CIPPTenantCloudEnvironment -TenantId $script:TenantGuid -InitialDomainName 'contoso.onmicrosoft.com' | Should -Be 'Commercial'
            Should -Invoke Write-LogMessage -Times 1
        }

        It 'falls back to USGovHigh for an onmicrosoft.us initial domain when discovery fails' {
            Mock Invoke-RestMethod { throw 'network down' }
            Get-CIPPTenantCloudEnvironment -TenantId $script:TenantGuid -InitialDomainName 'contoso.onmicrosoft.us' | Should -Be 'USGovHigh'
        }

        It 'returns Commercial with no input at all' {
            Mock Invoke-RestMethod { throw 'should not be called' }
            Get-CIPPTenantCloudEnvironment | Should -Be 'Commercial'
            Should -Invoke Invoke-RestMethod -Times 0
        }
    }

    Context 'input validation' {
        It 'does not call discovery for tenant id <TenantId>' -TestCases @(
            @{ TenantId = '../../evil.com/x' }
            @{ TenantId = 'contoso.com/../common' }
            @{ TenantId = 'evil.com?x=1' }
            @{ TenantId = 'evil.com#frag' }
            @{ TenantId = 'user@evil.com' }
            @{ TenantId = 'not a tenant' }
            @{ TenantId = '11111111-2222-3333-4444-55555555555' }
        ) {
            param($TenantId)
            Mock Invoke-RestMethod { New-Discovery -Instance 'microsoftonline.us' -Scope 'USGov' }
            Get-CIPPTenantCloudEnvironment -TenantId $TenantId -InitialDomainName 'contoso.onmicrosoft.com' | Should -Be 'Commercial'
            Should -Invoke Invoke-RestMethod -Times 0
        }

        It 'still uses the initial domain when the tenant id is invalid' {
            Mock Invoke-RestMethod { throw 'should not be called' }
            Get-CIPPTenantCloudEnvironment -TenantId 'bad/id' -InitialDomainName 'contoso.onmicrosoft.us' | Should -Be 'USGovHigh'
        }
    }
}
