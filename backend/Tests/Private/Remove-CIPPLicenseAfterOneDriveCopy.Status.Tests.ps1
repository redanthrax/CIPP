# The licence gate's scheduled check run against the real status function: with polling capped per
# check, the gate keeps making progress and only removes licences once every job is confirmed.

BeforeAll {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    . (Join-Path $RepoRoot 'Modules/CIPPCore/Public/Update-CIPPOneDriveCopyToUserStatus.ps1')
    . (Join-Path $RepoRoot 'Modules/CIPPCore/Public/Remove-CIPPLicenseAfterOneDriveCopy.ps1')

    function Get-CIPPTable { param($TableName) @{ TableName = $TableName } }
    function Get-CippTable { param($tablename) @{ TableName = $tablename } }
    function Get-CIPPAzDataTableEntity { param($Filter, $TableName) }
    function Add-CIPPAzDataTableEntity { param($Entity, [switch]$Force, $OperationType, $TableName) }
    function Update-AzDataTableEntity { param($Entity, [switch]$Force, $TableName) }
    function Get-CIPPSharePointLibraryCopyOperation { param($TenantFilter, $OperationId, $TableName) }
    function Get-CIPPSharePointCopyJobProgress { param($TenantFilter, $SourceSiteUrl, $CopyJobInfo) }
    function Remove-CIPPLicense { param($Headers, $userid, $username, $APIName, $TenantFilter, [switch]$Schedule) }
    function Add-CIPPScheduledTask { param($Task, $hidden, $DisallowDuplicateName) }
    function Write-LogMessage { param($headers, $API, $tenant, $message, $sev) }

    $script:OpId = '11111111-2222-3333-4444-555555555555'
    $script:UserId = 'aaaaaaaa-1111-2222-3333-444444444444'
}

Describe 'Licence gate with rate-limited, capped status checks' {
    BeforeEach {
        $script:Store = @{}
        $script:Store[$script:OpId] = [pscustomobject]@{
            PartitionKey = 'contoso.com'; RowKey = $script:OpId; Kind = 'Operation'; LeaverId = $script:UserId; LeaverUPN = 'pat@contoso.com'
            RootItemCount = 250; ExpectedBytes = 250
            Recipients = (ConvertTo-Json -Compress -InputObject @([pscustomobject]@{ Index = 0; UserPrincipalName = 'bob@contoso.com'; FolderName = 'pat@contoso.com'; SubOperationId = "$($script:OpId)-r0"; JobCount = 250 }))
        }
        Mock Get-CIPPAzDataTableEntity {
            if ($Filter -match "RowKey eq '([^']+)'") { $script:Store[$Matches[1]] }
            elseif ($Filter -match "RowKey ge '([^']+)' and RowKey lt '([^']+)'") {
                $Low = $Matches[1]; $High = $Matches[2]
                $script:Store.Values | Where-Object { [string]::CompareOrdinal($_.RowKey, $Low) -ge 0 -and [string]::CompareOrdinal($_.RowKey, $High) -lt 0 }
            }
        }
        Mock Add-CIPPAzDataTableEntity {
            foreach ($Item in @($Entity)) {
                $Existing = $script:Store[$Item.RowKey]
                if ($OperationType -eq 'UpsertMerge' -and $Existing) { foreach ($Key in $Item.Keys) { $Existing | Add-Member -NotePropertyName $Key -NotePropertyValue $Item[$Key] -Force } }
                else { $script:Store[$Item.RowKey] = [pscustomobject]$Item }
            }
        }
        Mock Get-CIPPSharePointLibraryCopyOperation { [pscustomobject]@{ SourceSiteUrl = 'https://contoso-my.sharepoint.com/personal/pat'; CopyJobInfos = @(0..249 | ForEach-Object { [pscustomobject]@{ JobId = "$_" } }) } }
        Mock Get-CIPPSharePointCopyJobProgress { [pscustomobject]@{ IsComplete = $true; ObjectsProcessed = 1; FilesCreated = 1; BytesProcessed = 1; TotalErrors = 0; ErrorMessages = @(); WarningMessages = @() } }
        Mock Remove-CIPPLicense { 'Removed licenses for pat@contoso.com.' }
        Mock Update-AzDataTableEntity { }
        Mock Write-LogMessage { }
        $script:CippScheduledTaskIdStorage = [pscustomobject]@{ Value = 'task-1' }
    }

    It 'removes the licences only on the check that confirms the last job' {
        $Params = @{ TenantFilter = 'contoso.com'; userid = $script:UserId; username = 'pat@contoso.com'; OperationId = $script:OpId; Deadline = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 3600 }

        # 250 jobs, 100 per check: the first two scheduled checks wait, the third removes the licences.
        foreach ($Check in 1..2) {
            Remove-CIPPLicenseAfterOneDriveCopy @Params | Should -BeLike '*is InProgress*'
            Should -Invoke Remove-CIPPLicense -Times 0 -Exactly
            $script:Store[$script:OpId].LastCheckedUnix = 0   # the next scheduled check is 30 minutes later
        }
        Remove-CIPPLicenseAfterOneDriveCopy @Params | Should -BeLike '*completed. Removed licenses*'
        Should -Invoke Remove-CIPPLicense -Times 1 -Exactly
        Should -Invoke Get-CIPPSharePointCopyJobProgress -Times 250 -Exactly
        Should -Invoke Update-AzDataTableEntity -Times 1 -Exactly -ParameterFilter { $Entity.Recurrence -eq '0' }
    }
}
