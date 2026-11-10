# Tenant rows written before cloudEnvironment existed carry no value. Get-Tenants must hand them out
# as Commercial so nothing needs migrating, and must leave a stored value alone (redanthrax/CIPP#1).

BeforeAll {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))

    function Get-CippTable { param($tablename) }
    function Get-CIPPAzDataTableEntity { param($Context, $Filter, $Property) }
    function Write-LogMessage { param($API, $tenant, $message, $Sev, $LogData, $headers, $level) }
    function ConvertTo-CIPPODataFilterValue { param($Value, $Type) }

    . (Join-Path $RepoRoot 'Modules/CIPPCore/Public/GraphHelper/Get-Tenants.ps1')
}

Describe 'Get-Tenants cloudEnvironment' {
    BeforeEach {
        Mock Get-CippTable { @{} }
        Mock Write-LogMessage {}
        Mock ConvertTo-CIPPODataFilterValue { $Value }
        Mock Get-CIPPAzDataTableEntity {
            @(
                [PSCustomObject]@{ RowKey = '11111111-1111-1111-1111-111111111111'; customerId = '11111111-1111-1111-1111-111111111111'; displayName = 'Legacy'; defaultDomainName = 'legacy.com'; initialDomainName = 'legacy.onmicrosoft.com' }
                [PSCustomObject]@{ RowKey = '22222222-2222-2222-2222-222222222222'; customerId = '22222222-2222-2222-2222-222222222222'; displayName = 'Empty'; defaultDomainName = 'empty.com'; initialDomainName = 'empty.onmicrosoft.com'; cloudEnvironment = '' }
                [PSCustomObject]@{ RowKey = '33333333-3333-3333-3333-333333333333'; customerId = '33333333-3333-3333-3333-333333333333'; displayName = 'Gov'; defaultDomainName = 'gov.us'; initialDomainName = 'gov.onmicrosoft.us'; cloudEnvironment = 'USGovHigh' }
                [PSCustomObject]@{ RowKey = '44444444-4444-4444-4444-444444444444'; customerId = '44444444-4444-4444-4444-444444444444'; displayName = 'DoD'; defaultDomainName = 'dod.mil'; initialDomainName = 'dod.onmicrosoft.us'; cloudEnvironment = 'USGovDoD' }
            )
        }
    }

    It 'returns <Expected> for <Name>' -ForEach @(
        @{ Name = 'Legacy'; Expected = 'Commercial' }
        @{ Name = 'Empty'; Expected = 'Commercial' }
        @{ Name = 'Gov'; Expected = 'USGovHigh' }
        @{ Name = 'DoD'; Expected = 'USGovDoD' }
    ) {
        $Tenant = @(Get-Tenants) | Where-Object displayName -EQ $Name
        $Tenant.cloudEnvironment | Should -Be $Expected
    }
}
