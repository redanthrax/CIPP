BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'Fixtures/CloudBackup/CloudBackupTestStubs.ps1')
    $script:JobId = 'bbbbbbbb-0000-0000-0000-000000000001'

    function New-QueuedJob {
        param($Type = 'Compare', $Source = 'c1', $Target = 'c1', $CompareTo = '', [hashtable]$Parameters = @{ Areas = @('ConditionalAccess') })
        [pscustomobject]@{
            PartitionKey   = 'CloudBackupJob'
            RowKey         = $script:JobId
            Type           = $Type
            Status         = 'Queued'
            RunId          = '11111111-1111-1111-1111-111111111111_0000000000000000001_c1'
            CompareToRunId = $CompareTo
            SourceTenantId = $Source
            SourceTenant   = 'contoso.com'
            TargetTenantId = $Target
            TargetTenant   = 'x'
            Parameters     = ($Parameters | ConvertTo-Json -Depth 5 -Compress)
            ParametersHash = 'hash'
            PreviewJobId   = ''
            RequestedBy    = 'tech@partner.com'
            CreatedAt      = '2026-11-20T00:00:00.0000000Z'
        }
    }
    function New-AreaSnapshot([hashtable]$Sections) {
        [pscustomobject]@{ Sections = [ordered]@{} + $Sections; References = @{ Groups = @{}; Users = @{} } }
    }
    function New-RestoreRow([string]$Area, [string]$Key, [string]$Action, [string]$Status) {
        [pscustomobject]@{ Area = $Area; Section = 'policies'; SectionLabel = 'Policies'; Key = $Key; Name = "Name $Key"; Action = $Action; Status = $Status; Message = ''; Unmapped = @() }
    }
    function Invoke-Job { Push-CloudBackupJob -Item ([pscustomobject]@{ FunctionName = 'CloudBackupJob'; JobId = $script:JobId }) }
    function Get-FinalRow { @($script:Writes.Where({ $_.PartitionKey -eq 'CloudBackupJob' }))[-1] }
    function Get-Result { [CIPP.CippJson]::ConvertFromJson(@($script:Writes.Where({ $_.PartitionKey -eq 'CloudBackupJobResult' }))[-1].Result) }
}

Describe 'Push-CloudBackupJob' {
    BeforeEach {
        $script:Job = New-QueuedJob
        $script:Writes = [System.Collections.Generic.List[object]]::new()
        $script:Snapshot = [pscustomobject]@{
            Run      = @{}
            Manifest = @{}
            Areas    = [ordered]@{
                ConditionalAccess = New-AreaSnapshot @{ policies = @([pscustomobject]@{ id = 'p1' }) }
                Intune            = New-AreaSnapshot @{ configurationPolicies = @([pscustomobject]@{ id = 'i1' }) }
                SharePoint        = New-AreaSnapshot @{ tenantSettings = [pscustomobject]@{ SharingCapability = 'Disabled' }; sites = @([pscustomobject]@{ Url = 'https://x/sites/a'; Title = 'A' }) }
            }
        }
        Mock Get-CIPPAzDataTableEntity { $script:Job } -ParameterFilter { $TableName -eq 'CloudBackupJobs' }
        Mock Add-CIPPAzDataTableEntity { $script:Writes.Add(@{} + $Entity) } -ParameterFilter { $TableName -eq 'CloudBackupJobs' }
        Mock Get-Tenants { $script:CloudBackupTenants }
        Mock Get-CIPPCloudBackupSnapshot { $script:Snapshot }
        Mock Get-CIPPCloudBackupConfigData { [pscustomobject]@{ Sections = [ordered]@{ policies = @() }; Warnings = @() } }
        Mock Compare-CIPPCloudBackupConfig {
            [pscustomobject]@{ Area = $Area; Section = 'policies'; SectionLabel = 'Policies'; Key = 'p1'; Name = 'Name p1'; Change = 'Changed'; Differences = @([pscustomobject]@{ Path = 'state'; Reference = 'enabled'; Difference = 'disabled' }) }
            [pscustomobject]@{ Area = $Area; Section = 'policies'; SectionLabel = 'Policies'; Key = 'p2'; Name = 'Name p2'; Change = 'Added'; Differences = @() }
            [pscustomobject]@{ Area = $Area; Section = 'policies'; SectionLabel = 'Policies'; Key = 'p3'; Name = 'Name p3'; Change = 'Unchanged'; Differences = @() }
        }
        Mock Restore-CIPPCloudBackupConditionalAccess { New-RestoreRow 'ConditionalAccess' 'p1' 'Update' $(if ($Apply) { 'Succeeded' } else { 'Planned' }) }
        Mock Restore-CIPPCloudBackupIntune { New-RestoreRow 'Intune' 'i1' 'Create' $(if ($Apply) { 'Failed' } else { 'Planned' }) }
        Mock Restore-CIPPCloudBackupExchange { }
        Mock Write-LogMessage { }
    }

    It 'compares a backup with the current configuration and keeps only changed items' {
        Invoke-Job

        @($script:Writes.Where({ $_.PartitionKey -eq 'CloudBackupJob' })).Status | Should -Be @('Running', 'Completed')
        $Final = Get-FinalRow
        $Final.StartedAt | Should -Not -BeNullOrEmpty
        $Final.CompletedAt | Should -Not -BeNullOrEmpty
        $Final.Error | Should -Be ''
        $Final.Parameters | Should -Be $script:Job.Parameters
        $Summary = [CIPP.CippJson]::ConvertFromJson($Final.Summary)
        $Summary.ConditionalAccess.Changed | Should -Be 1
        $Summary.ConditionalAccess.Added | Should -Be 1
        $Summary.ConditionalAccess.Unchanged | Should -Be 1
        $Summary.ConditionalAccess.Removed | Should -Be 0
        @((Get-Result).Key) | Should -Be @('p1', 'p2')
        Should -Invoke Get-CIPPCloudBackupSnapshot -Times 1 -Exactly -ParameterFilter { @($Area) -join ',' -eq 'ConditionalAccess' }
        Should -Invoke Get-CIPPCloudBackupConfigData -Times 1 -Exactly -ParameterFilter { $TenantFilter -eq 'contoso.com' -and $Area -eq 'ConditionalAccess' -and -not $IncludeSecrets }
        Should -Invoke Compare-CIPPCloudBackupConfig -Times 1 -Exactly -ParameterFilter { -not $MatchByName }
    }

    It 'compares with another tenant''s backup by name, without reading live data' {
        $script:Job = New-QueuedJob -Target 'c2' -CompareTo '11111111-1111-1111-1111-111111111111_0000000000000000002_c2' -Parameters @{ Areas = @() }

        Invoke-Job

        (Get-FinalRow).Status | Should -Be 'Completed'
        Should -Invoke Get-CIPPCloudBackupSnapshot -Times 1 -Exactly -ParameterFilter { $RunId -like '*_c2' -and @($Area).Count -eq 3 }
        Should -Invoke Get-CIPPCloudBackupConfigData -Times 0 -Exactly
        Should -Invoke Compare-CIPPCloudBackupConfig -Times 3 -Exactly -ParameterFilter { $MatchByName }
    }

    It 'previews a restore without -Apply, attaches differences and lists SharePoint as not restorable' {
        $script:Job = New-QueuedJob -Type 'RestorePreview' -Parameters @{ Areas = @('ConditionalAccess', 'Intune', 'SharePoint'); ConflictAction = 'Overwrite'; CAState = 'ReportOnly'; Items = @() }

        Invoke-Job

        (Get-FinalRow).Status | Should -Be 'Completed'
        Should -Invoke Restore-CIPPCloudBackupConditionalAccess -Times 1 -Exactly -ParameterFilter { -not $Apply -and $CAState -eq 'ReportOnly' -and $ConflictAction -eq 'Overwrite' -and $TargetTenantFilter -eq 'contoso.com' -and $SourceTenantId -eq 'c1' -and $null -eq $Items }
        Should -Invoke Restore-CIPPCloudBackupIntune -Times 1 -Exactly -ParameterFilter { -not $Apply }
        Should -Invoke Restore-CIPPCloudBackupExchange -Times 0 -Exactly
        $Result = Get-Result
        $CA = @($Result.Where({ $_.Area -eq 'ConditionalAccess' }))[0]
        $CA.Status | Should -Be 'Planned'
        $CA.Differences[0].Path | Should -Be 'state'
        @($Result.Where({ $_.Area -eq 'Intune' }))[0].Differences.Count | Should -Be 0
        $SharePoint = @($Result.Where({ $_.Area -eq 'SharePoint' }))
        @($SharePoint.Key | Sort-Object) | Should -Be @('https://x/sites/a', 'tenantSettings')
        @($SharePoint.Action | Sort-Object -Unique) | Should -Be @('NotRestorable')
        $Summary = [CIPP.CippJson]::ConvertFromJson((Get-FinalRow).Summary)
        $Summary.Update | Should -Be 1
        $Summary.Create | Should -Be 1
        $Summary.NotRestorable | Should -Be 2
        $Summary.Succeeded | Should -Be 0
        Should -Invoke Write-LogMessage -ParameterFilter { $API -eq 'CloudBackupRestore' -and $message -like '*started by tech@partner.com*' }
    }

    It 'matches preview differences by name when restoring to another tenant' {
        $script:Job = New-QueuedJob -Type 'RestorePreview' -Target 'c2' -Parameters @{ Areas = @('ConditionalAccess'); ConflictAction = 'Skip'; CAState = 'ReportOnly' }
        Mock Restore-CIPPCloudBackupConditionalAccess { $Row = New-RestoreRow 'ConditionalAccess' 'p1' 'Create' 'Planned'; $Row.Key = 'other-id'; $Row }

        Invoke-Job

        Should -Invoke Restore-CIPPCloudBackupConditionalAccess -ParameterFilter { $TargetTenantFilter -eq 'fabrikam.com' }
        Should -Invoke Compare-CIPPCloudBackupConfig -ParameterFilter { $MatchByName }
        (Get-Result)[0].Differences[0].Path | Should -Be 'state'
    }

    It 'restores with -Apply, passes the selected items per area and logs failed items' {
        $script:Job = New-QueuedJob -Type 'Restore' -Parameters @{
            Areas          = @('ConditionalAccess', 'Intune', 'SharePoint')
            ConflictAction = 'Skip'
            CAState        = 'AsBackedUp'
            Items          = @(@{ Area = 'Intune'; Section = 'configurationPolicies'; Key = 'i1' }, @{ Area = 'SharePoint'; Section = 'sites'; Key = 'https://x/sites/a' })
        }

        Invoke-Job

        Should -Invoke Restore-CIPPCloudBackupConditionalAccess -Times 0 -Exactly
        Should -Invoke Restore-CIPPCloudBackupIntune -Times 1 -Exactly -ParameterFilter { $Apply -and @($Items).Count -eq 1 -and $Items[0].Section -eq 'configurationPolicies' -and $Items[0].Key -eq 'i1' }
        Should -Invoke Compare-CIPPCloudBackupConfig -Times 0 -Exactly
        $Result = Get-Result
        @($Result.Key) | Should -Be @('i1', 'https://x/sites/a')
        $Summary = [CIPP.CippJson]::ConvertFromJson((Get-FinalRow).Summary)
        $Summary.Failed | Should -Be 1
        $Summary.NotRestorable | Should -Be 1
        Should -Invoke Write-LogMessage -Times 1 -Exactly -ParameterFilter { $sev -eq 'Warning' -and $message -like "*'Name i1' failed*" }
        Should -Invoke Write-LogMessage -Times 1 -Exactly -ParameterFilter { $message -like 'Restore of backup*finished with status Completed*Failed 1*' }
    }

    It 'records an area that throws as a failed row and finishes the rest' {
        $script:Job = New-QueuedJob -Type 'Restore' -Parameters @{ Areas = @('ConditionalAccess', 'Intune'); ConflictAction = 'Skip'; CAState = 'AsBackedUp' }
        Mock Restore-CIPPCloudBackupConditionalAccess { throw 'Graph is down' }

        Invoke-Job

        (Get-FinalRow).Status | Should -Be 'Completed'
        $Result = Get-Result
        $Result[0].Status | Should -Be 'Failed'
        $Result[0].Message | Should -BeLike '*Graph is down*'
        $Result[1].Area | Should -Be 'Intune'
    }

    It 'finalises the row as Failed without throwing when the snapshot cannot be read' {
        Mock Get-CIPPCloudBackupSnapshot { throw 'checksum mismatch' }

        { Invoke-Job } | Should -Not -Throw

        $Final = Get-FinalRow
        $Final.Status | Should -Be 'Failed'
        $Final.Error | Should -BeLike '*checksum mismatch*'
        $Final.CompletedAt | Should -Not -BeNullOrEmpty
    }

    It 'marks the job failed when the result cannot be saved' {
        Mock Add-CIPPAzDataTableEntity { throw 'too big' } -ParameterFilter { $TableName -eq 'CloudBackupJobs' -and $Entity.PartitionKey -eq 'CloudBackupJobResult' }

        Invoke-Job

        $Final = Get-FinalRow
        $Final.Status | Should -Be 'Failed'
        $Final.Error | Should -BeLike '*too big*'
    }

    It 'does not throw when the job row is missing or the table cannot be written' {
        Mock Get-CIPPAzDataTableEntity { } -ParameterFilter { $TableName -eq 'CloudBackupJobs' }
        { Invoke-Job } | Should -Not -Throw
        $script:Writes.Count | Should -Be 0

        Mock Get-CIPPAzDataTableEntity { $script:Job } -ParameterFilter { $TableName -eq 'CloudBackupJobs' }
        Mock Add-CIPPAzDataTableEntity { throw 'storage down' } -ParameterFilter { $TableName -eq 'CloudBackupJobs' }
        Mock Write-LogMessage { throw 'log down' }
        { Invoke-Job } | Should -Not -Throw
    }
}
