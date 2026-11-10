BeforeAll {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    class HttpResponseContext { [object]$StatusCode; [object]$Body }
    $Accelerators = [psobject].Assembly.GetType('System.Management.Automation.TypeAccelerators')
    if (-not $Accelerators::Get.ContainsKey('HttpStatusCode')) {
        $Accelerators::Add('HttpStatusCode', [System.Net.HttpStatusCode])
    }

    function Get-CippKeyVaultName { 'kv' }
    function Get-CIPPAuthentication { }
    function Test-CIPPAccess { param($Request, [switch]$TenantList) $script:TenantAccess }
    function Get-CIPPTable { param($tablename) @{ TableName = $tablename } }
    function Get-CIPPAzDataTableEntity { param($TableName, $Filter) }
    function Add-CIPPAzDataTableEntity { param($TableName, $Entity, [switch]$Force) }
    function Set-CippKeyVaultSecret { param($VaultName, $Name, $SecretValue) }
    function Clear-CippTokenCache { param($TenantFilter) }
    function Set-CIPPCredentialVersion { }
    function New-CippQueueEntry { param($Name, $TotalTasks) @{ RowKey = 'q' } }
    function Start-CIPPOrchestrator { param($InputObject) }
    function Write-LogMessage { param($headers, $API, $tenant, $message, $Sev, $LogData) }
    function Get-CippException { param($Exception) @{ NormalizedError = "$Exception" } }
    . (Join-Path $RepoRoot 'Modules/CIPPHTTP/Public/Entrypoints/HTTP Functions/CIPP/Setup/Invoke-ExecUpdateRefreshToken.ps1')
    . (Join-Path $RepoRoot 'Modules/CIPPCore/Public/GraphHelper/Get-CIPPCloudEndpoint.ps1')
    . (Join-Path $RepoRoot 'Modules/CIPPCore/Public/GraphHelper/Get-CIPPAccessTokenCloudEnvironment.ps1')
    . (Join-Path $RepoRoot 'Modules/CIPPCore/Public/GraphHelper/Get-CIPPPartnerCloudEnvironment.ps1')
    . (Join-Path $RepoRoot 'Modules/CIPPCore/Public/GraphHelper/Resolve-CIPPSignInCloud.ps1')

    $script:Partner = '11111111-1111-1111-1111-111111111111'
    $script:Managed = '22222222-2222-2222-2222-222222222222'
    $script:Other = '33333333-3333-3333-3333-333333333333'

    function Invoke-Update($TenantId) {
        Invoke-ExecUpdateRefreshToken -Request ([pscustomobject]@{
                Params  = @{ CIPPEndpoint = 'ExecUpdateRefreshToken' }
                Headers = @{}
                Body    = [pscustomobject]@{ tenantId = $TenantId; refreshtoken = 'token' }
            })
    }
}

Describe 'Invoke-ExecUpdateRefreshToken tenant scope' {
    BeforeAll {
        $script:SavedTenantId = $env:TenantID
        $script:SavedStorage = $env:AzureWebJobsStorage
        $script:SavedNonLocal = $env:NonLocalHostAzurite
        $env:TenantID = $script:Partner
        $env:AzureWebJobsStorage = 'DefaultEndpointsProtocol=https;AccountName=x'
        $env:NonLocalHostAzurite = $null
    }
    AfterAll {
        $env:TenantID = $script:SavedTenantId
        $env:AzureWebJobsStorage = $script:SavedStorage
        $env:NonLocalHostAzurite = $script:SavedNonLocal
    }
    BeforeEach {
        Mock Set-CippKeyVaultSecret { }
        Mock Get-CIPPAzDataTableEntity { if ($Filter -match $script:Managed -or $Filter -match $script:Other) { [pscustomobject]@{ customerId = 'x' } } }
        $script:TenantAccess = @($script:Managed)
    }

    It 'refuses a tenantId of <TenantId>' -ForEach @(
        @{ TenantId = 'contoso.onmicrosoft.com' }
        @{ TenantId = "x' or PartitionKey ne '" }
        @{ TenantId = $null }
        @{ TenantId = "22222222-2222-2222-2222-222222222222`n" }
    ) {
        (Invoke-Update $TenantId).StatusCode | Should -Be 400
        Should -Invoke Set-CippKeyVaultSecret -Times 0
    }

    It 'refuses a managed tenant outside the caller''s access' {
        (Invoke-Update $script:Other).StatusCode | Should -Be 403
        Should -Invoke Set-CippKeyVaultSecret -Times 0
    }

    It 'refuses the partner tenant when it is outside the caller''s access' {
        (Invoke-Update $script:Partner).StatusCode | Should -Be 403
        Should -Invoke Set-CippKeyVaultSecret -Times 0
    }

    It 'stores the token for <Name>' -ForEach @(
        @{ Name = 'a tenant the caller can access'; Tenant = '22222222-2222-2222-2222-222222222222'; Access = @('22222222-2222-2222-2222-222222222222') }
        @{ Name = 'a tenant CIPP does not manage yet'; Tenant = '44444444-4444-4444-4444-444444444444'; Access = @('22222222-2222-2222-2222-222222222222') }
        @{ Name = 'any tenant for an all-tenant caller'; Tenant = '33333333-3333-3333-3333-333333333333'; Access = @('AllTenants') }
    ) {
        $script:TenantAccess = $Access
        (Invoke-Update $Tenant).StatusCode | Should -Be 200
        Should -Invoke Set-CippKeyVaultSecret -Times 1 -ParameterFilter { $Name -eq $Tenant }
    }
}

# redanthrax/CIPP#2: an existing direct tenant's working token must not be overwritten by a sign-in for
# another cloud or tenant - ExecAddTenant only validates after the token has been stored.
Describe 'Invoke-ExecUpdateRefreshToken existing direct tenant' {
    BeforeAll {
        $script:SavedTenantId = $env:TenantID
        $script:SavedStorage = $env:AzureWebJobsStorage
        $script:SavedNonLocal = $env:NonLocalHostAzurite
        $script:SavedPartnerCloud = $env:CIPP_PARTNER_CLOUD
        $env:TenantID = $script:Partner
        $env:AzureWebJobsStorage = 'DefaultEndpointsProtocol=https;AccountName=x'
        $env:NonLocalHostAzurite = $null
        $env:CIPP_PARTNER_CLOUD = $null
        $script:Direct = '55555555-5555-5555-5555-555555555555'
        $script:Aud = @{ Commercial = 'https://graph.microsoft.com'; USGovHigh = 'https://graph.microsoft.us'; USGovDoD = 'https://dod-graph.microsoft.us' }
        function New-Jwt($Cloud, $Tid) {
            $Enc = { param($T) [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($T)).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
            '{0}.{1}.sig' -f (& $Enc '{"alg":"RS256"}'), (& $Enc (@{ aud = $script:Aud[$Cloud]; iss = 'https://sts.windows.net/x/'; tid = $Tid } | ConvertTo-Json -Compress))
        }
        function Invoke-DirectUpdate($Cloud, $TokenCloud, $Tid = $script:Direct, $AccessToken) {
            if (-not $TokenCloud) { $TokenCloud = if ($Cloud) { $Cloud } else { 'Commercial' } }
            if (-not $AccessToken) { $AccessToken = New-Jwt $TokenCloud $Tid }
            $Body = [pscustomobject]@{ tenantId = $script:Direct; refreshtoken = 'new-token'; accessToken = $AccessToken }
            if ($Cloud) { $Body | Add-Member -NotePropertyName cloudEnvironment -NotePropertyValue $Cloud }
            Invoke-ExecUpdateRefreshToken -Request ([pscustomobject]@{ Params = @{ CIPPEndpoint = 'ExecUpdateRefreshToken' }; Headers = @{}; Body = $Body })
        }
    }
    AfterAll {
        $env:TenantID = $script:SavedTenantId
        $env:AzureWebJobsStorage = $script:SavedStorage
        $env:NonLocalHostAzurite = $script:SavedNonLocal
        $env:CIPP_PARTNER_CLOUD = $script:SavedPartnerCloud
    }
    BeforeEach {
        Mock Set-CippKeyVaultSecret { }
        Mock Write-LogMessage { }
        $script:TenantAccess = @('AllTenants')
        $script:StoredCloud = 'USGovHigh'
        Mock Get-CIPPAzDataTableEntity {
            if ($Filter -match $script:Direct) {
                $Row = [pscustomobject]@{ customerId = $script:Direct; delegatedPrivilegeStatus = 'directTenant' }
                if ($script:StoredCloud) { $Row | Add-Member -NotePropertyName cloudEnvironment -NotePropertyValue $script:StoredCloud }
                $Row
            }
        }
    }

    It 'stores a sign-in for the tenant in its stored cloud' {
        (Invoke-DirectUpdate 'USGovHigh').StatusCode | Should -Be 200
        Should -Invoke Set-CippKeyVaultSecret -Times 1 -ParameterFilter { $Name -eq $script:Direct }
    }

    It 'keeps the stored token for a sign-in to <Cloud> (token <TokenCloud>) when the tenant is stored as <Stored>' -TestCases @(
        @{ Stored = 'USGovHigh'; Cloud = 'USGovDoD'; TokenCloud = 'USGovDoD' }
        @{ Stored = 'USGovHigh'; Cloud = 'Commercial'; TokenCloud = 'Commercial' }
        @{ Stored = 'USGovHigh'; Cloud = $null; TokenCloud = 'Commercial' }
        @{ Stored = 'USGovHigh'; Cloud = 'USGovHigh'; TokenCloud = 'Commercial' }
        @{ Stored = 'Commercial'; Cloud = 'USGovHigh'; TokenCloud = 'USGovHigh' }
        @{ Stored = $null; Cloud = 'USGovHigh'; TokenCloud = 'USGovHigh' }
    ) {
        param($Stored, $Cloud, $TokenCloud)
        $script:StoredCloud = $Stored
        (Invoke-DirectUpdate $Cloud $TokenCloud).StatusCode | Should -Be 400
        Should -Invoke Set-CippKeyVaultSecret -Times 0
    }

    It 'keeps the stored token when the sign-in token is for another tenant' {
        (Invoke-DirectUpdate 'USGovHigh' -Tid '66666666-6666-6666-6666-666666666666').StatusCode | Should -Be 400
        Should -Invoke Set-CippKeyVaultSecret -Times 0
    }

    It 'keeps the stored token when no usable access token is sent' {
        (Invoke-DirectUpdate 'USGovHigh' -AccessToken 'not-a-jwt').StatusCode | Should -Be 400
        Should -Invoke Set-CippKeyVaultSecret -Times 0
    }

    It 'still stores a commercial refresh for a legacy row without a cloud (pre-#2 client)' {
        $script:StoredCloud = $null
        (Invoke-DirectUpdate $null).StatusCode | Should -Be 200
        Should -Invoke Set-CippKeyVaultSecret -Times 1
    }
}
