# Pester tests for the cloud environment recorded by Invoke-ExecAddTenant
#
# A new direct tenant stores the cloud reported by Get-CIPPTenantCloudEnvironment
# (redanthrax/CIPP#1). Detection must never stop the tenant from being added, and the
# existing-tenant and blocked GDAP-conversion branches must not detect or write a cloud.

BeforeAll {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    $FunctionPath = Get-ChildItem -Path (Join-Path $RepoRoot 'Modules') -Recurse -Filter 'Invoke-ExecAddTenant.ps1' -File -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not $FunctionPath) { throw 'Could not locate Invoke-ExecAddTenant.ps1 under Modules/' }

    class HttpResponseContext {
        [object]$StatusCode
        [object]$Body
    }

    $Accelerators = [psobject].Assembly.GetType('System.Management.Automation.TypeAccelerators')
    if (-not $Accelerators::Get.ContainsKey('HttpStatusCode')) {
        $Accelerators::Add('HttpStatusCode', [System.Net.HttpStatusCode])
    }

    function Test-CIPPAccess { param($Request, [switch]$TenantList) }
    function Get-CippTable { param($tablename) }
    function Get-CIPPAuthentication { }
    function Get-CIPPAzDataTableEntity { param($Context, $Filter) }
    function Add-CIPPAzDataTableEntity { param($Context, $Entity, [switch]$Force) }
    function Remove-CIPPDirectTenantToken { param($TenantId) }
    function Write-LogMessage { param($headers, $API, $tenant, $tenantid, $message, $Sev, $LogData) }
    function New-CippQueueEntry { param($Name, $TotalTasks) }
    function Start-CIPPOrchestrator { param($InputObject) }
    function ConvertTo-CIPPODataFilterValue { param($Value, $Type) $Value -replace "'", "''" }
    function Get-CIPPTenantCloudEnvironment { param($TenantId, $InitialDomainName) }

    . $FunctionPath

    $script:TenantId = 'cccccccc-1111-2222-3333-444444444444'

    function New-AddRequest {
        [pscustomobject]@{
            Params  = @{ CIPPEndpoint = 'ExecAddTenant' }
            Headers = @{ }
            Body    = [pscustomobject]@{
                tenantId          = $script:TenantId
                defaultDomainName = 'contoso.us'
                accessToken       = 'token'
                username          = 'admin@contoso.onmicrosoft.us'
            }
            Query   = [pscustomobject]@{ }
        }
    }

    function New-GraphBatchResponse {
        param($InitialDomain = 'contoso.onmicrosoft.us')
        [pscustomobject]@{
            responses = @(
                [pscustomobject]@{ id = 'organization'; body = [pscustomobject]@{ value = @([pscustomobject]@{ id = $script:TenantId; displayName = 'Contoso Gov' }) } }
                [pscustomobject]@{ id = 'domains'; body = [pscustomobject]@{ value = @(
                            [pscustomobject]@{ id = 'contoso.us'; isDefault = $true; isInitial = $false }
                            [pscustomobject]@{ id = $InitialDomain; isDefault = $false; isInitial = $true }
                        )
                    }
                }
            )
        }
    }
}

Describe 'Invoke-ExecAddTenant cloud environment' {
    BeforeEach {
        $script:Written = [System.Collections.Generic.List[object]]::new()
        $script:ExistingTenant = $null

        Mock Test-CIPPAccess { @('AllTenants') }
        Mock Get-CippTable { @{ Context = $tablename } }
        Mock Get-CIPPAuthentication {}
        Mock Get-CIPPAzDataTableEntity { $script:ExistingTenant }
        Mock Add-CIPPAzDataTableEntity { $script:Written.Add($Entity) }
        Mock Remove-CIPPDirectTenantToken {}
        Mock Write-LogMessage {}
        Mock New-CippQueueEntry { [pscustomobject]@{ RowKey = 'queue-1' } }
        Mock Start-CIPPOrchestrator {}
        Mock Invoke-RestMethod { New-GraphBatchResponse }
        Mock Get-CIPPTenantCloudEnvironment { 'USGovHigh' }
    }

    Context 'new tenant' {
        It 'stores the detected cloud environment <Value> on the new row' -TestCases @(
            @{ Value = 'Commercial' }
            @{ Value = 'USGovHigh' }
            @{ Value = 'USGovDoD' }
        ) {
            param($Value)
            Mock Get-CIPPTenantCloudEnvironment { $Value }

            $Response = Invoke-ExecAddTenant -Request (New-AddRequest)

            $Response.StatusCode | Should -Be ([HttpStatusCode]::OK)
            $script:Written.Count | Should -Be 1
            $script:Written[0].cloudEnvironment | Should -BeExactly $Value
            $script:Written[0].delegatedPrivilegeStatus | Should -Be 'directTenant'
        }

        It 'passes the tenant id and the initial domain from Graph to detection' {
            $null = Invoke-ExecAddTenant -Request (New-AddRequest)
            Should -Invoke Get-CIPPTenantCloudEnvironment -Times 1 -ParameterFilter {
                $TenantId -eq $script:TenantId -and $InitialDomainName -eq 'contoso.onmicrosoft.us'
            }
        }

        It 'still adds the tenant as Commercial when detection throws' {
            Mock Get-CIPPTenantCloudEnvironment { throw 'detection exploded' }

            $Response = Invoke-ExecAddTenant -Request (New-AddRequest)

            $Response.StatusCode | Should -Be ([HttpStatusCode]::OK)
            $Response.Body.severity | Should -Be 'success'
            $script:Written.Count | Should -Be 1
            $script:Written[0].cloudEnvironment | Should -Be 'Commercial'
            $script:Written[0].RowKey | Should -Be $script:TenantId
            Should -Invoke Write-LogMessage -ParameterFilter { $Sev -eq 'Warning' -and $message -like '*defaulting to Commercial*' }
            Should -Invoke Start-CIPPOrchestrator -Times 1
        }

        It 'does not detect or write when the Graph lookup fails' {
            Mock Invoke-RestMethod { throw 'unauthorized' }
            $Response = Invoke-ExecAddTenant -Request (New-AddRequest)
            $Response.StatusCode | Should -Be ([HttpStatusCode]::InternalServerError)
            Should -Invoke Get-CIPPTenantCloudEnvironment -Times 0
            $script:Written.Count | Should -Be 0
        }
    }

    Context 'token tenant must match the requested tenant' {
        It 'rejects a token for <Name> without detecting or writing' -TestCases @(
            @{ Name = 'a different tenant'; OrgId = 'dddddddd-1111-2222-3333-444444444444' }
            @{ Name = 'no organization id'; OrgId = $null }
            @{ Name = 'an empty organization id'; OrgId = '' }
        ) {
            param($Name, $OrgId)
            $script:OrgId = $OrgId
            Mock Invoke-RestMethod {
                $Batch = New-GraphBatchResponse
                $Batch.responses[0].body.value[0].id = $script:OrgId
                $Batch
            }

            $Response = Invoke-ExecAddTenant -Request (New-AddRequest)

            $Response.StatusCode | Should -Be ([HttpStatusCode]::BadRequest)
            $Response.Body.severity | Should -Be 'error'
            $script:Written.Count | Should -Be 0
            Should -Invoke Get-CIPPTenantCloudEnvironment -Times 0
            Should -Invoke Start-CIPPOrchestrator -Times 0
            Should -Invoke Remove-CIPPDirectTenantToken -Times 1 -ParameterFilter { $TenantId -eq $script:TenantId }
            Should -Invoke Write-LogMessage -ParameterFilter { $Sev -eq 'Warning' -and $message -like '*Blocked adding tenant*' }
        }

        It 'accepts a token whose organization id matches the requested tenant' {
            $Response = Invoke-ExecAddTenant -Request (New-AddRequest)
            $Response.StatusCode | Should -Be ([HttpStatusCode]::OK)
            Should -Invoke Remove-CIPPDirectTenantToken -Times 0
        }
    }

    Context 'existing direct tenant' {
        It 'refreshes credentials without detecting or changing the stored cloud' {
            $script:ExistingTenant = [pscustomobject]@{
                PartitionKey = 'Tenants'; RowKey = $script:TenantId; customerId = $script:TenantId
                displayName = 'Contoso Gov'; defaultDomainName = 'contoso.us'
                delegatedPrivilegeStatus = 'directTenant'; cloudEnvironment = 'USGovDoD'
            }

            $Response = Invoke-ExecAddTenant -Request (New-AddRequest)

            $Response.StatusCode | Should -Be ([HttpStatusCode]::OK)
            Should -Invoke Get-CIPPTenantCloudEnvironment -Times 0
            $script:Written.Count | Should -Be 1
            $script:Written[0].cloudEnvironment | Should -Be 'USGovDoD'
            $script:Written[0].directTenantUserPrincipalName | Should -Be 'admin@contoso.onmicrosoft.us'
        }

        It 'leaves a legacy row without a cloud value untouched' {
            $script:ExistingTenant = [pscustomobject]@{
                PartitionKey = 'Tenants'; RowKey = $script:TenantId; customerId = $script:TenantId
                displayName = 'Contoso'; defaultDomainName = 'contoso.com'; delegatedPrivilegeStatus = 'directTenant'
            }
            $null = Invoke-ExecAddTenant -Request (New-AddRequest)
            Should -Invoke Get-CIPPTenantCloudEnvironment -Times 0
            $script:Written[0].PSObject.Properties.Name | Should -Not -Contain 'cloudEnvironment'
        }
    }

    Context 'blocked GDAP conversion' {
        It 'rejects the conversion without detecting or writing' {
            $script:ExistingTenant = [pscustomobject]@{
                PartitionKey = 'Tenants'; RowKey = $script:TenantId; customerId = $script:TenantId
                displayName = 'Contoso GDAP'; defaultDomainName = 'contoso.com'
                delegatedPrivilegeStatus = 'granularDelegatedAdminPrivileges'
            }

            $Response = Invoke-ExecAddTenant -Request (New-AddRequest)

            $Response.StatusCode | Should -Be ([HttpStatusCode]::BadRequest)
            Should -Invoke Get-CIPPTenantCloudEnvironment -Times 0
            Should -Invoke Remove-CIPPDirectTenantToken -Times 1
            $script:Written.Count | Should -Be 0
        }
    }

    Context 'access' {
        It 'returns 403 for a tenant-restricted caller before any detection' {
            Mock Test-CIPPAccess { @($script:TenantId) }
            $Response = Invoke-ExecAddTenant -Request (New-AddRequest)
            $Response.StatusCode | Should -Be ([HttpStatusCode]::Forbidden)
            Should -Invoke Get-CIPPTenantCloudEnvironment -Times 0
            Should -Invoke Invoke-RestMethod -Times 0
        }
    }
}

Describe 'Invoke-ExecAddTenant with the real detection helper' {
    BeforeAll {
        . (Join-Path $RepoRoot 'Modules/CIPPCore/Public/GraphHelper/Get-CIPPTenantCloudEnvironment.ps1')
    }

    BeforeEach {
        $script:Written = [System.Collections.Generic.List[object]]::new()
        Mock Test-CIPPAccess { @('AllTenants') }
        Mock Get-CippTable { @{ Context = $tablename } }
        Mock Get-CIPPAuthentication {}
        Mock Get-CIPPAzDataTableEntity {}
        Mock Add-CIPPAzDataTableEntity { $script:Written.Add($Entity) }
        Mock Write-LogMessage {}
        Mock New-CippQueueEntry { [pscustomobject]@{ RowKey = 'queue-1' } }
        Mock Start-CIPPOrchestrator {}
        Mock Invoke-RestMethod -ParameterFilter { $Uri -like 'https://graph.microsoft.com/*' } { New-GraphBatchResponse }
    }

    It 'stores USGovDoD for a DoD tenant' {
        Mock Invoke-RestMethod -ParameterFilter { $Uri -like 'https://login.microsoftonline.com/*' } {
            [pscustomobject]@{ cloud_instance_name = 'microsoftonline.us'; tenant_region_scope = 'USGov'; tenant_region_sub_scope = 'DOD' }
        }
        $Response = Invoke-ExecAddTenant -Request (New-AddRequest)
        $Response.StatusCode | Should -Be ([HttpStatusCode]::OK)
        $script:Written[0].cloudEnvironment | Should -Be 'USGovDoD'
        Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter { $Uri -eq "https://login.microsoftonline.com/$($script:TenantId)/v2.0/.well-known/openid-configuration" }
    }

    It 'stores USGovHigh from the onmicrosoft.us initial domain when discovery is unreachable' {
        Mock Invoke-RestMethod -ParameterFilter { $Uri -like 'https://login.microsoftonline.com/*' } { throw 'timed out' }
        $Response = Invoke-ExecAddTenant -Request (New-AddRequest)
        $Response.StatusCode | Should -Be ([HttpStatusCode]::OK)
        $script:Written[0].cloudEnvironment | Should -Be 'USGovHigh'
    }

    It 'stores Commercial for a commercial tenant' {
        Mock Invoke-RestMethod -ParameterFilter { $Uri -like 'https://graph.microsoft.com/*' } { New-GraphBatchResponse -InitialDomain 'contoso.onmicrosoft.com' }
        Mock Invoke-RestMethod -ParameterFilter { $Uri -like 'https://login.microsoftonline.com/*' } {
            [pscustomobject]@{ cloud_instance_name = 'microsoftonline.com'; tenant_region_scope = 'NA' }
        }
        $null = Invoke-ExecAddTenant -Request (New-AddRequest)
        $script:Written[0].cloudEnvironment | Should -Be 'Commercial'
    }
}
