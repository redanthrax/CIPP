$BackendRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
if (-not ('CIPP.CippJson' -as [type])) { Add-Type -Path (Join-Path $BackendRoot 'Shared/CIPPSharp/bin/CIPPSharp.dll') }

class HttpResponseContext {
    [int]$StatusCode
    [object]$Body
    [object]$ContentType
    [object]$Headers
}
$Accelerators = [psobject].Assembly.GetType('System.Management.Automation.TypeAccelerators')
if (-not $Accelerators::Get.ContainsKey('HttpStatusCode')) { $Accelerators::Add('HttpStatusCode', [System.Net.HttpStatusCode]) }

function Get-CIPPTable { param($TableName) @{ TableName = $TableName } }
function Get-CIPPAzDataTableEntity { param($TableName, $Filter, $Property, $First) }
function Add-CIPPAzDataTableEntity { param($TableName, $Entity, [switch]$Force, $OperationType) }
function Remove-CIPPAzDataTableEntity { param($TableName, $Entity, [switch]$Force) }
function Write-LogMessage { param($headers, $API, $tenant, $tenantid, $message, $sev, $LogData) }
function Get-CippException { param($Exception) [pscustomobject]@{ NormalizedError = $Exception.Exception.Message } }
function Test-CIPPAccess { param($Request, [switch]$TenantList) }
function Get-Tenants { param($TenantFilter, [switch]$IncludeErrors, [switch]$IncludeAll) }
function Get-TenantGroups { param($GroupId) }
function Expand-CIPPTenantGroups { param($TenantFilter) }
function New-CippQueueEntry { param($Name, $TotalTasks) [pscustomobject]@{ RowKey = 'queue-1' } }
function Start-CIPPOrchestrator { param($InputObject) }

function Get-CIPPSecret { param($Name) }
function Set-CIPPSecret { param($Name, $Value) }
function Remove-CIPPSecret { param($Name) }
function Get-CIPPCloudBackupDestination { param($Id, [switch]$IncludeSecret) }
function Test-CIPPCloudBackupDestination { param($Destination) }
function Get-CIPPCloudBackupRetentionRule { param($Destination, $RuleName) }
function Set-CIPPCloudBackupRetentionRule { param($Destination, $RuleName, $Prefix, $Days) }
function Remove-CIPPCloudBackupRetentionRule { param($Destination, $RuleName) }
function Set-CIPPCloudBackupObject { param($Destination, $Key, [byte[]]$Body, $ContentType, $Metadata) }
function New-CIPPCloudBackupKey { }
function Get-CIPPCloudBackupKey { param($KeyId) }
function Protect-CIPPCloudBackupData { param([byte[]]$Bytes, $KeyId, [byte[]]$Key) }
function Get-CIPPCloudBackupConfigData { param($TenantFilter, $Area, [switch]$IncludeSecrets) }
function Get-CIPPCloudBackupSnapshot { param($RunId, $Area) }
function Compare-CIPPCloudBackupConfig { param($Area, $Reference, $Difference, [switch]$MatchByName) }
function Get-CIPPCloudBackupSectionLabel { param($Section) "Label $Section" }
function Get-CIPPCloudBackupItemInfo {
    param($Section, $Item)
    foreach ($Entry in @($Item)) {
        $Key = $Entry.id ?? $Entry.Url ?? $Entry.Identity ?? $Section
        [pscustomobject]@{ Key = $Key; Name = $Entry.displayName ?? $Entry.Title ?? $Entry.Name ?? $Key }
    }
}
function Restore-CIPPCloudBackupConditionalAccess { param($Snapshot, $SourceTenantId, $TargetTenantFilter, $Items, $ConflictAction, $CAState, [switch]$Apply) }
function Restore-CIPPCloudBackupIntune { param($Snapshot, $SourceTenantId, $TargetTenantFilter, $Items, $ConflictAction, $CAState, [switch]$Apply) }
function Restore-CIPPCloudBackupExchange { param($Snapshot, $SourceTenantId, $TargetTenantFilter, $Items, $ConflictAction, [switch]$Apply) }

$Modules = Join-Path $BackendRoot 'Modules'
. (Join-Path $Modules 'CIPPCore/Public/Get-CippErrorStatusCode.ps1')
. (Join-Path $Modules 'CIPPCore/Public/Get-CippBulkStatusCode.ps1')
. (Join-Path $Modules 'CIPPCore/Public/Get-CIPPTenantLookup.ps1')
. (Join-Path $Modules 'CIPPCore/Public/CloudBackup/Get-CIPPCloudBackupPolicy.ps1')
. (Join-Path $Modules 'CIPPCore/Public/CloudBackup/Get-CIPPCloudBackupPolicyTenantId.ps1')
. (Join-Path $Modules 'CIPPCore/Public/CloudBackup/Test-CIPPCloudBackupPolicyScope.ps1')
. (Join-Path $Modules 'CIPPCore/Public/Entrypoints/Orchestrator Functions/Start-CloudBackupOrchestrator.ps1')
. (Join-Path $Modules 'CIPPActivityTriggers/Public/Entrypoints/Activity Triggers/Cloud Backup/Push-CloudBackupTenant.ps1')
. (Join-Path $Modules 'CIPPActivityTriggers/Public/Entrypoints/Activity Triggers/Cloud Backup/Push-CloudBackupJob.ps1')
foreach ($File in Get-ChildItem -Path (Join-Path $Modules 'CIPPHTTP/Public/Entrypoints/HTTP Functions/CIPP/CloudBackup') -Filter '*.ps1') { . $File.FullName }

function New-CloudBackupPolicyRow {
    param(
        $Id = '11111111-1111-1111-1111-111111111111',
        $Name = 'Nightly',
        $Enabled = $true,
        $DestinationId = '22222222-2222-2222-2222-222222222222',
        $Tenants = '[{"type":"Tenant","customerId":"c1"}]',
        $ConfigAreas = '["ConditionalAccess","Intune"]',
        $ConfigSchedule = '1d',
        $ConfigNextRun = '2026-01-01T00:00:00.0000000Z',
        $RetentionDays = 90,
        $Encryption = $false,
        $CurrentKeyId = '',
        $KeyIds = '[]'
    )
    [pscustomobject]@{
        PartitionKey   = 'CloudBackupPolicy'
        RowKey         = $Id
        Name           = $Name
        Enabled        = $Enabled
        DestinationId  = $DestinationId
        Tenants        = $Tenants
        ConfigAreas    = $ConfigAreas
        ConfigSchedule = $ConfigSchedule
        ConfigNextRun  = $ConfigNextRun
        RetentionDays  = $RetentionDays
        Encryption     = $Encryption
        CurrentKeyId   = $CurrentKeyId
        KeyIds         = $KeyIds
    }
}

function New-CloudBackupRequest {
    param($Endpoint, $Body, $Query)
    [pscustomobject]@{
        Params  = @{ CIPPEndpoint = $Endpoint }
        Headers = @{ 'x-ms-client-principal-name' = 'admin@partner.com' }
        Query   = [pscustomobject]($Query ?? @{})
        Body    = [pscustomobject]($Body ?? @{})
    }
}

$script:CloudBackupTenants = @(
    [pscustomobject]@{ customerId = 'c1'; defaultDomainName = 'contoso.com'; initialDomainName = 'contoso.onmicrosoft.com'; displayName = 'Contoso' }
    [pscustomobject]@{ customerId = 'c2'; defaultDomainName = 'fabrikam.com'; initialDomainName = 'fabrikam.onmicrosoft.com'; displayName = 'Fabrikam' }
    [pscustomobject]@{ customerId = 'c3'; defaultDomainName = 'tailspin.com'; initialDomainName = 'tailspin.onmicrosoft.com'; displayName = 'Tailspin' }
)

function New-CloudBackupRunRow {
    param(
        $PolicyId = '11111111-1111-1111-1111-111111111111',
        $RowKey = '0000000000000000001_c1',
        $TenantId = 'c1',
        $Tenant = 'contoso.com',
        $Status = 'Succeeded',
        $Areas = '[{"Area":"ConditionalAccess","Status":"Succeeded"},{"Area":"Intune","Status":"Succeeded"},{"Area":"Exchange","Status":"Failed"}]'
    )
    [pscustomobject]@{
        PartitionKey = $PolicyId
        RowKey       = $RowKey
        PolicyId     = $PolicyId
        TenantId     = $TenantId
        Tenant       = $Tenant
        Status       = $Status
        StartedAt    = '2026-11-01T00:00:00.0000000Z'
        Areas        = $Areas
    }
}
