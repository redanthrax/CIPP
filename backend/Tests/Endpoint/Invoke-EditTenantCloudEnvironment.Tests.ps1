# Pester tests for Invoke-EditTenantCloudEnvironment
#
# The override endpoint is the only way to correct a tenant's stored cloud (e.g. a DoD tenant that
# detection reported as GCC High, redanthrax/CIPP#1). It must accept only the three known values,
# only touch tenants inside the caller's scope, and only change cloudEnvironment on the row.
#
# The real Get-Tenants and ConvertTo-CIPPODataFilterValue are loaded so tenant scoping and filter
# escaping are exercised end to end against an in-memory Tenants table.

BeforeAll {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    $FunctionPath = Get-ChildItem -Path (Join-Path $RepoRoot 'Modules') -Recurse -Filter 'Invoke-EditTenantCloudEnvironment.ps1' -File -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not $FunctionPath) { throw 'Could not locate Invoke-EditTenantCloudEnvironment.ps1 under Modules/' }

    class HttpResponseContext {
        [object]$StatusCode
        [object]$Body
    }

    $Accelerators = [psobject].Assembly.GetType('System.Management.Automation.TypeAccelerators')
    if (-not $Accelerators::Get.ContainsKey('HttpStatusCode')) {
        $Accelerators::Add('HttpStatusCode', [System.Net.HttpStatusCode])
    }

    function Get-CippTable { param($tablename) }
    function Get-CIPPAzDataTableEntity { param($Context, $Filter, $Property) }
    function Add-CIPPAzDataTableEntity { param($Context, $Entity, [switch]$Force) }
    function Write-LogMessage { param($headers, $API, $tenant, $TenantId, $message, $Sev, $LogData) }
    function Get-CippException { param($Exception) [pscustomobject]@{ NormalizedError = "$($Exception.Exception.Message)" } }
    # An unknown tenant makes Get-Tenants rebuild from GDAP; stub that out as "no relationships"
    function New-GraphGetRequest { param($uri, $tenantid, $NoAuthCheck, $ErrorAction) }
    function Get-AzDataTableEntity { param($Context, $Filter) }
    function Add-AzDataTableEntity { param($Context, $Entity, [switch]$Force) }

    $script:OriginalRefreshToken = $env:RefreshToken
    $env:RefreshToken = 'test-refresh-token'

    . (Join-Path $RepoRoot 'Modules/CIPPCore/Public/ConvertTo-CIPPODataFilterValue.ps1')
    . (Join-Path $RepoRoot 'Modules/CIPPCore/Public/GraphHelper/Get-Tenants.ps1')
    . $FunctionPath

    $script:ContosoId = 'aaaaaaaa-0000-0000-0000-000000000001'
    $script:FabrikamId = 'bbbbbbbb-0000-0000-0000-000000000002'

    function New-CloudRequest {
        param($CustomerId = $script:ContosoId, $CloudEnvironment)
        [pscustomobject]@{
            Params  = @{ CIPPEndpoint = 'EditTenantCloudEnvironment' }
            Headers = @{ }
            Body    = [pscustomobject]@{
                customerId       = $CustomerId
                cloudEnvironment = $CloudEnvironment
            }
            Query   = [pscustomobject]@{ }
        }
    }

    # Minimal emulation of the table service: every quoted literal in the filter is a candidate
    # key, matched against RowKey/customerId/domain columns ('' unescaped back to ').
    function Find-TenantRow {
        param($Filter)
        $Literals = [regex]::Matches($Filter, "'((?:[^']|'')*)'") | ForEach-Object { $_.Groups[1].Value -replace "''", "'" }
        $script:Rows | Where-Object {
            $Row = $_
            -not $Row.Excluded -and ($Literals | Where-Object { $_ -in @($Row.RowKey, $Row.customerId, $Row.defaultDomainName, $Row.initialDomainName) })
        }
    }
}

Describe 'Invoke-EditTenantCloudEnvironment' {
    BeforeEach {
        $script:CippAllowedTenantsStorage = $null
        $script:Rows = @(
            [pscustomobject]@{
                PartitionKey = 'Tenants'; RowKey = $script:ContosoId; customerId = $script:ContosoId
                displayName = 'Contoso'; defaultDomainName = 'contoso.com'; initialDomainName = 'contoso.onmicrosoft.com'
                delegatedPrivilegeStatus = 'directTenant'; Excluded = $false; RequiresRefresh = $false; LastRefresh = [datetime]'2026-01-01'
            }
            [pscustomobject]@{
                PartitionKey = 'Tenants'; RowKey = $script:FabrikamId; customerId = $script:FabrikamId
                displayName = 'Fabrikam'; defaultDomainName = 'fabrikam.us'; initialDomainName = 'fabrikam.onmicrosoft.us'
                cloudEnvironment = 'USGovHigh'; Excluded = $false; RequiresRefresh = $false; LastRefresh = [datetime]'2026-01-01'
            }
        )
        $script:Written = [System.Collections.Generic.List[object]]::new()

        Mock Write-LogMessage {}
        Mock Get-CippTable { @{ Context = $tablename } }
        Mock Get-CIPPAzDataTableEntity { Find-TenantRow -Filter $Filter }
        Mock Add-CIPPAzDataTableEntity { $script:Written.Add(($Entity | Select-Object *)) }
        Mock New-GraphGetRequest { @() }
        Mock Get-AzDataTableEntity {}
        Mock Add-AzDataTableEntity {}
    }

    AfterEach {
        $script:CippAllowedTenantsStorage = $null
    }

    AfterAll {
        $env:RefreshToken = $script:OriginalRefreshToken
    }

    Context 'valid input' {
        It 'stores <Value> sent as a plain string' -TestCases @(
            @{ Value = 'Commercial' }
            @{ Value = 'USGovHigh' }
            @{ Value = 'USGovDoD' }
        ) {
            param($Value)
            $Response = Invoke-EditTenantCloudEnvironment -Request (New-CloudRequest -CloudEnvironment $Value)
            $Response.StatusCode | Should -Be ([HttpStatusCode]::OK)
            $script:Written.Count | Should -Be 1
            $script:Written[0].cloudEnvironment | Should -BeExactly $Value
        }

        It 'stores the value of a { label, value } autocomplete object (<Shape>)' -TestCases @(
            @{ Shape = 'PSCustomObject'; Object = [pscustomobject]@{ label = 'US Government (DoD)'; value = 'USGovDoD' } }
            @{ Shape = 'Hashtable'; Object = @{ label = 'US Government (DoD)'; value = 'USGovDoD' } }
        ) {
            param($Shape, $Object)
            $Response = Invoke-EditTenantCloudEnvironment -Request (New-CloudRequest -CloudEnvironment $Object)
            $Response.StatusCode | Should -Be ([HttpStatusCode]::OK)
            $script:Written[0].cloudEnvironment | Should -BeExactly 'USGovDoD'
        }

        It 'normalises case variant <Value> to the canonical value' -TestCases @(
            @{ Value = 'usgovhigh'; Expected = 'USGovHigh' }
            @{ Value = 'USGOVDOD'; Expected = 'USGovDoD' }
            @{ Value = 'commercial'; Expected = 'Commercial' }
        ) {
            param($Value, $Expected)
            $Response = Invoke-EditTenantCloudEnvironment -Request (New-CloudRequest -CloudEnvironment $Value)
            $Response.StatusCode | Should -Be ([HttpStatusCode]::OK)
            $script:Written[0].cloudEnvironment | Should -BeExactly $Expected
        }

        It 'changes only cloudEnvironment on the stored row' {
            $Before = $script:Rows[0] | Select-Object *
            $null = Invoke-EditTenantCloudEnvironment -Request (New-CloudRequest -CloudEnvironment 'USGovHigh')

            $After = $script:Written[0]
            $After.cloudEnvironment | Should -Be 'USGovHigh'
            foreach ($Property in $Before.PSObject.Properties) {
                $After.($Property.Name) | Should -Be $Property.Value -Because "$($Property.Name) must be left alone"
            }
            @($After.PSObject.Properties.Name | Where-Object { $_ -notin $Before.PSObject.Properties.Name }) | Should -Be @('cloudEnvironment')
        }

        It 'writes the row read from the table, not the Get-Tenants output' {
            # Get-Tenants adds a Commercial default on output; the write must be the raw table row
            $null = Invoke-EditTenantCloudEnvironment -Request (New-CloudRequest -CustomerId $script:FabrikamId -CloudEnvironment 'USGovDoD')
            $script:Written[0].RowKey | Should -Be $script:FabrikamId
            $script:Written[0].cloudEnvironment | Should -Be 'USGovDoD'
        }

        It 'reports the previous value, Commercial when the row had none' {
            $Response = Invoke-EditTenantCloudEnvironment -Request (New-CloudRequest -CloudEnvironment 'USGovHigh')
            $Response.Body.Results | Should -Match 'from Commercial to USGovHigh'

            $Response = Invoke-EditTenantCloudEnvironment -Request (New-CloudRequest -CustomerId $script:FabrikamId -CloudEnvironment 'USGovDoD')
            $Response.Body.Results | Should -Match 'from USGovHigh to USGovDoD'
        }

        It 'accepts a tenant domain as customerId and writes the matching row' {
            $Response = Invoke-EditTenantCloudEnvironment -Request (New-CloudRequest -CustomerId 'fabrikam.us' -CloudEnvironment 'Commercial')
            $Response.StatusCode | Should -Be ([HttpStatusCode]::OK)
            $script:Written[0].RowKey | Should -Be $script:FabrikamId
        }

        It 'logs the change against the tenant' {
            $null = Invoke-EditTenantCloudEnvironment -Request (New-CloudRequest -CloudEnvironment 'USGovHigh')
            Should -Invoke Write-LogMessage -Times 1 -ParameterFilter { $Sev -eq 'Info' -and $TenantId -eq $script:ContosoId }
        }
    }

    Context 'invalid input' {
        It 'returns 400 for cloudEnvironment <Name>' -TestCases @(
            @{ Name = 'null'; Value = $null }
            @{ Name = 'empty'; Value = '' }
            @{ Name = 'whitespace'; Value = '   ' }
            @{ Name = 'unknown'; Value = 'USGovModerate' }
            @{ Name = 'GCC'; Value = 'GCC' }
            @{ Name = 'padded'; Value = ' USGovHigh' }
            @{ Name = 'trailing newline'; Value = "USGovHigh`n" }
            @{ Name = 'wildcard'; Value = 'USGov*' }
            @{ Name = 'regex'; Value = 'USGov.*' }
            @{ Name = 'OData injection'; Value = "USGovHigh' or PartitionKey ne '" }
            @{ Name = 'script'; Value = '<script>alert(1)</script>' }
            @{ Name = 'subexpression'; Value = '$(Remove-Item /)' }
            @{ Name = 'array'; Value = @('USGovHigh', 'USGovDoD') }
            @{ Name = 'object without value'; Value = [pscustomobject]@{ label = 'USGovHigh' } }
            @{ Name = 'object with bad value'; Value = [pscustomobject]@{ label = 'US Government (DoD)'; value = 'DoD' } }
            @{ Name = 'number'; Value = 1 }
        ) {
            param($Name, $Value)
            $Response = Invoke-EditTenantCloudEnvironment -Request (New-CloudRequest -CloudEnvironment $Value)
            $Response.StatusCode | Should -Be ([HttpStatusCode]::BadRequest)
            Should -Invoke Add-CIPPAzDataTableEntity -Times 0
        }

        It 'returns 400 when customerId is <Name>' -TestCases @(
            @{ Name = 'null'; Value = $null }
            @{ Name = 'empty'; Value = '' }
            @{ Name = 'whitespace'; Value = ' ' }
        ) {
            param($Name, $Value)
            $Response = Invoke-EditTenantCloudEnvironment -Request (New-CloudRequest -CustomerId $Value -CloudEnvironment 'USGovHigh')
            $Response.StatusCode | Should -Be ([HttpStatusCode]::BadRequest)
            Should -Invoke Add-CIPPAzDataTableEntity -Times 0
        }

        It 'lists the allowed values in the 400 message' {
            $Response = Invoke-EditTenantCloudEnvironment -Request (New-CloudRequest -CloudEnvironment 'nope')
            $Response.Body.Results | Should -Match 'Allowed values: Commercial, USGovHigh, USGovDoD'
        }
    }

    Context 'tenant scope' {
        It 'returns 403 for a tenant outside the caller scope and writes nothing' {
            $script:CippAllowedTenantsStorage = [pscustomobject]@{ Value = @($script:ContosoId) }
            $Response = Invoke-EditTenantCloudEnvironment -Request (New-CloudRequest -CustomerId $script:FabrikamId -CloudEnvironment 'Commercial')
            $Response.StatusCode | Should -Be ([HttpStatusCode]::Forbidden)
            Should -Invoke Add-CIPPAzDataTableEntity -Times 0
        }

        It 'returns 403 when the out-of-scope tenant is named by domain' {
            $script:CippAllowedTenantsStorage = [pscustomobject]@{ Value = @($script:ContosoId) }
            $Response = Invoke-EditTenantCloudEnvironment -Request (New-CloudRequest -CustomerId 'fabrikam.onmicrosoft.us' -CloudEnvironment 'Commercial')
            $Response.StatusCode | Should -Be ([HttpStatusCode]::Forbidden)
            Should -Invoke Add-CIPPAzDataTableEntity -Times 0
        }

        It 'returns 403 for a caller whose scope resolved to no tenants' {
            $script:CippAllowedTenantsStorage = [pscustomobject]@{ Value = @() }
            $Response = Invoke-EditTenantCloudEnvironment -Request (New-CloudRequest -CloudEnvironment 'USGovHigh')
            $Response.StatusCode | Should -Be ([HttpStatusCode]::Forbidden)
            Should -Invoke Add-CIPPAzDataTableEntity -Times 0
        }

        It 'allows a tenant inside the caller scope' {
            $script:CippAllowedTenantsStorage = [pscustomobject]@{ Value = @($script:ContosoId) }
            $Response = Invoke-EditTenantCloudEnvironment -Request (New-CloudRequest -CloudEnvironment 'USGovHigh')
            $Response.StatusCode | Should -Be ([HttpStatusCode]::OK)
            $script:Written[0].RowKey | Should -Be $script:ContosoId
        }

        It 'returns 403 for an unknown tenant' {
            $Response = Invoke-EditTenantCloudEnvironment -Request (New-CloudRequest -CustomerId 'cccccccc-0000-0000-0000-000000000003' -CloudEnvironment 'USGovHigh')
            $Response.StatusCode | Should -Be ([HttpStatusCode]::Forbidden)
            Should -Invoke Add-CIPPAzDataTableEntity -Times 0
        }

        It 'returns 403 for an excluded tenant' {
            $script:Rows[0].Excluded = $true
            $Response = Invoke-EditTenantCloudEnvironment -Request (New-CloudRequest -CloudEnvironment 'USGovHigh')
            $Response.StatusCode | Should -Be ([HttpStatusCode]::Forbidden)
        }
    }

    Context 'table access' {
        It 'returns 500 and writes nothing when the tenant row disappears between lookup and write' {
            Mock Get-CIPPAzDataTableEntity {
                if ($Filter -match 'RowKey eq') { return } # direct row read finds nothing
                Find-TenantRow -Filter $Filter
            }
            $Response = Invoke-EditTenantCloudEnvironment -Request (New-CloudRequest -CloudEnvironment 'USGovHigh')
            $Response.StatusCode | Should -Be ([HttpStatusCode]::InternalServerError)
            $Response.Body.Results | Should -Match 'not found'
            Should -Invoke Add-CIPPAzDataTableEntity -Times 0
        }

        It 'returns 500 when the write fails' {
            Mock Add-CIPPAzDataTableEntity { throw 'storage unavailable' }
            $Response = Invoke-EditTenantCloudEnvironment -Request (New-CloudRequest -CloudEnvironment 'USGovHigh')
            $Response.StatusCode | Should -Be ([HttpStatusCode]::InternalServerError)
            Should -Invoke Write-LogMessage -ParameterFilter { $Sev -eq 'Error' }
        }

        It 'escapes a quote-bearing customerId in every OData filter' {
            $Injection = "x' or PartitionKey eq 'Tenants"
            $Response = Invoke-EditTenantCloudEnvironment -Request (New-CloudRequest -CustomerId $Injection -CloudEnvironment 'USGovHigh')
            $Response.StatusCode | Should -Be ([HttpStatusCode]::Forbidden)
            Should -Invoke Get-CIPPAzDataTableEntity -ParameterFilter { $Filter -like "*x'' or PartitionKey eq ''Tenants*" }
            Should -Invoke Get-CIPPAzDataTableEntity -Times 0 -ParameterFilter { $Filter -like "*'x' or PartitionKey eq 'Tenants'*" }
            Should -Invoke Add-CIPPAzDataTableEntity -Times 0
        }

        It 'escapes the stored customerId when reading the row back' {
            # Defence in depth: the row key comes from the table, but it is still escaped
            $script:Rows += [pscustomobject]@{
                PartitionKey = 'Tenants'; RowKey = "odd'id"; customerId = "odd'id"
                displayName = 'Quote'; defaultDomainName = 'quote.com'; initialDomainName = 'quote.onmicrosoft.com'
                Excluded = $false; RequiresRefresh = $false; LastRefresh = [datetime]'2026-01-01'
            }
            $Response = Invoke-EditTenantCloudEnvironment -Request (New-CloudRequest -CustomerId 'quote.com' -CloudEnvironment 'USGovHigh')
            $Response.StatusCode | Should -Be ([HttpStatusCode]::OK)
            Should -Invoke Get-CIPPAzDataTableEntity -ParameterFilter { $Filter -eq "PartitionKey eq 'Tenants' and RowKey eq 'odd''id'" }
            $script:Written[0].RowKey | Should -Be "odd'id"
        }
    }
}
