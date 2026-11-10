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

# The GDAP refresh rewrites a tenant row whole. A detected or manually overridden cloud must
# survive that rewrite, both in the table and in what Get-Tenants hands back.
Describe 'Get-Tenants cloudEnvironment across the GDAP refresh' {
    BeforeAll {
        function Get-AzDataTableEntity { param($Context, $Filter) }
        function Add-CIPPAzDataTableEntity { param($Context, $Entity, [switch]$Force) }
        function Add-AzDataTableEntity { param($Context, $Entity, [switch]$Force) }
        function New-GraphGetRequest { param($uri, $tenantid, $NoAuthCheck) }
        function Get-CippException { param($Exception) }

        $script:OrigRefreshToken = $env:RefreshToken
        $script:OrigTenantID = $env:TenantID
        $env:RefreshToken = 'pester'
        $env:TenantID = 'ffffffff-ffff-ffff-ffff-ffffffffffff'
        $script:Guid = '55555555-5555-5555-5555-555555555555'

        function New-StoredRow {
            param($CloudEnvironment)
            $Row = [PSCustomObject]@{
                PartitionKey             = 'Tenants'
                RowKey                   = $script:Guid
                customerId               = $script:Guid
                displayName              = 'Gov Tenant'
                defaultDomainName        = 'gov.us'
                initialDomainName        = 'gov.onmicrosoft.us'
                delegatedPrivilegeStatus = 'granularDelegatedAdminPrivileges'
                Excluded                 = $false
                RequiresRefresh          = $true   # forces the row to be rewritten rather than reused
                LastRefresh              = [DateTimeOffset]::UtcNow
            }
            if ($null -ne $CloudEnvironment) { $Row | Add-Member -NotePropertyName cloudEnvironment -NotePropertyValue $CloudEnvironment }
            $Row
        }
    }

    AfterAll {
        $env:RefreshToken = $script:OrigRefreshToken
        $env:TenantID = $script:OrigTenantID
    }

    BeforeEach {
        $script:Row = $null
        $script:Written = [System.Collections.Generic.List[object]]::new()
        $script:DomainsFail = $false

        Mock Get-CippTable { @{} }
        Mock ConvertTo-CIPPODataFilterValue { $Value }
        Mock Write-LogMessage {}
        Mock Get-CippException { @{} }
        Mock Get-AzDataTableEntity {}
        Mock Add-AzDataTableEntity {}
        Mock Add-CIPPAzDataTableEntity { $script:Written.Add($Entity) }
        Mock Get-CIPPAzDataTableEntity {
            if ([string]::IsNullOrEmpty($Filter)) { return [PSCustomObject]@{ state = 'gdap' } }
            if ($Filter -like '*Excluded eq true*') { return $null }
            return $script:Row
        }
        Mock New-GraphGetRequest {
            if ($uri -like '*delegatedAdminRelationships*') {
                return [PSCustomObject]@{
                    displayName        = 'GDAP-Gov'
                    customer           = [PSCustomObject]@{ tenantId = $script:Guid; displayName = 'Gov Tenant' }
                    autoExtendDuration = 'P180D'
                    endDateTime        = (Get-Date).AddYears(1).ToString('o')
                }
            }
            if ($uri -like '*beta/domains*') {
                if ($script:DomainsFail) { throw 'domains read failed' }
                return @(
                    [PSCustomObject]@{ id = 'gov.us'; isDefault = $true; isInitial = $false }
                    [PSCustomObject]@{ id = 'gov.onmicrosoft.us'; isDefault = $false; isInitial = $true }
                )
            }
            if ($uri -like '*findTenantInformationByTenantId*') { return [PSCustomObject]@{ defaultDomainName = 'gov.us' } }
            throw "unexpected Graph call: $uri"
        }
    }

    It 'keeps a stored <Value> when the refresh rewrites the row' -ForEach @(
        @{ Value = 'USGovHigh' }
        @{ Value = 'USGovDoD' }
        @{ Value = 'Commercial' }
    ) {
        $script:Row = New-StoredRow -CloudEnvironment $Value

        $Result = Get-Tenants -TriggerRefresh

        $script:Written.Count | Should -Be 1
        $script:Written[0].cloudEnvironment | Should -Be $Value
        $Result.cloudEnvironment | Should -Be $Value
    }

    It 'keeps the stored value when the domains read falls back' {
        $script:Row = New-StoredRow -CloudEnvironment 'USGovDoD'
        $script:DomainsFail = $true

        $null = Get-Tenants -TriggerRefresh

        $script:Written[0].cloudEnvironment | Should -Be 'USGovDoD'
        $script:Written[0].RequiresRefresh | Should -BeTrue
    }

    It 'keeps the stored value on a refresh scoped to the tenant' {
        $script:Row = New-StoredRow -CloudEnvironment 'USGovHigh'
        $script:Row.RequiresRefresh = $false

        $Result = Get-Tenants -TriggerRefresh -TenantFilter $script:Guid

        $script:Written[0].cloudEnvironment | Should -Be 'USGovHigh'
        $Result.cloudEnvironment | Should -Be 'USGovHigh'
    }

    It 'writes Commercial for a legacy row with no value' {
        $script:Row = New-StoredRow

        $null = Get-Tenants -TriggerRefresh

        $script:Written[0].cloudEnvironment | Should -Be 'Commercial'
    }

    It 'writes Commercial for a tenant seen for the first time' {
        $script:Row = $null

        $Result = Get-Tenants -TriggerRefresh

        $script:Written[0].cloudEnvironment | Should -Be 'Commercial'
        $Result.cloudEnvironment | Should -Be 'Commercial'
    }

    It 'returns the stored value from the cache-hit branch without rewriting it' {
        $script:Row = New-StoredRow -CloudEnvironment 'USGovDoD'
        $script:Row.RequiresRefresh = $false

        $Result = Get-Tenants -TriggerRefresh

        $script:Written.Count | Should -Be 0
        $Result.cloudEnvironment | Should -Be 'USGovDoD'
    }
}
