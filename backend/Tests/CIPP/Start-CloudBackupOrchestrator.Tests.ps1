BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'Fixtures/CloudBackup/CloudBackupTestStubs.ps1')
}

Describe 'Start-CloudBackupOrchestrator' {
    BeforeEach {
        $script:Policies = @()
        $script:Started = [System.Collections.Generic.List[object]]::new()
        $script:ConfigWrites = [System.Collections.Generic.List[object]]::new()
        $script:Removed = $null
        $script:OldRuns = @()
        Mock Get-CIPPAzDataTableEntity { $script:Policies } -ParameterFilter { $TableName -eq 'Config' }
        Mock Get-CIPPAzDataTableEntity { $script:OldRuns } -ParameterFilter { $TableName -eq 'CloudBackupRuns' }
        Mock Add-CIPPAzDataTableEntity { $script:ConfigWrites.Add($Entity) } -ParameterFilter { $TableName -eq 'Config' }
        Mock Remove-CIPPAzDataTableEntity { $script:Removed = $Entity } -ParameterFilter { $TableName -eq 'CloudBackupRuns' }
        $script:OldJobs = @()
        $script:RemovedJobs = $null
        $script:StuckJobs = @()
        $script:JobWrites = [System.Collections.Generic.List[object]]::new()
        Mock Get-CIPPAzDataTableEntity { if ($Filter -like '*Status eq*') { $script:StuckJobs } else { $script:OldJobs } } -ParameterFilter { $TableName -eq 'CloudBackupJobs' }
        Mock Add-CIPPAzDataTableEntity { $script:JobWrites.Add($Entity) } -ParameterFilter { $TableName -eq 'CloudBackupJobs' }
        Mock Remove-CIPPAzDataTableEntity { $script:RemovedJobs = $Entity } -ParameterFilter { $TableName -eq 'CloudBackupJobs' }
        Mock Get-Tenants { $script:CloudBackupTenants }
        Mock Get-CIPPCloudBackupDestination { [pscustomobject]@{ RowKey = '22222222-2222-2222-2222-222222222222'; Name = 'Blob'; Provider = 'AzureBlob' } }
        Mock Get-CIPPCloudBackupRetentionRule { @{ Prefix = '11111111-1111-1111-1111-111111111111/'; Days = 90 } }
        Mock Set-CIPPCloudBackupRetentionRule { }
        Mock New-CippQueueEntry { [pscustomobject]@{ RowKey = 'queue-1' } }
        Mock Start-CIPPOrchestrator { $script:Started.Add($InputObject); 'run-1' }
        Mock Write-LogMessage { }
    }

    It 'queues only enabled policies whose next run has passed' {
        $script:Policies = @(
            New-CloudBackupPolicyRow -Id '11111111-1111-1111-1111-111111111111' -Name 'Due'
            New-CloudBackupPolicyRow -Id '33333333-3333-3333-3333-333333333333' -Name 'Later' -ConfigNextRun ([datetime]::UtcNow.AddHours(2).ToString('o'))
            New-CloudBackupPolicyRow -Id '44444444-4444-4444-4444-444444444444' -Name 'Off' -Enabled $false
        )

        Start-CloudBackupOrchestrator | Should -Be 'run-1'

        $script:Started.Count | Should -Be 1
        $script:Started[0].OrchestratorName | Should -Be 'CloudBackup_11111111-1111-1111-1111-111111111111'
        $script:Started[0].AllowCollision | Should -BeFalse
        $Item = $script:Started[0].Batch[0]
        $Item.FunctionName | Should -Be 'CloudBackupTenant'
        $Item.PolicyId | Should -Be '11111111-1111-1111-1111-111111111111'
        $Item.customerId | Should -Be 'c1'
        $Item.QueueId | Should -Be 'queue-1'
        $Item.QueueName | Should -Be 'contoso.com'
    }

    It 'advances ConfigNextRun by the schedule interval before queueing' {
        $script:Policies = @(New-CloudBackupPolicyRow -ConfigSchedule '4h')
        $script:Order = [System.Collections.Generic.List[string]]::new()
        Mock Add-CIPPAzDataTableEntity { $script:ConfigWrites.Add($Entity); $script:Order.Add('advance') } -ParameterFilter { $TableName -eq 'Config' }
        Mock Start-CIPPOrchestrator { $script:Order.Add('start'); 'run-1' }
        $Before = [datetime]::UtcNow

        Start-CloudBackupOrchestrator | Out-Null

        @($script:Order) | Should -Be @('advance', 'start')
        Should -Invoke Add-CIPPAzDataTableEntity -Times 1 -Exactly -ParameterFilter { $OperationType -eq 'UpsertMerge' }
        $Update = @($script:ConfigWrites[0])[0]
        $Update.RowKey | Should -Be '11111111-1111-1111-1111-111111111111'
        $Next = [datetimeoffset]::Parse($Update.ConfigNextRun).UtcDateTime
        $Next | Should -BeGreaterOrEqual $Before.AddHours(4).AddSeconds(-1)
        $Next | Should -BeLessOrEqual ([datetime]::UtcNow.AddHours(4).AddSeconds(1))
    }

    It 'returns 0 and queues nothing when no policy is due' {
        $script:Policies = @(New-CloudBackupPolicyRow -ConfigNextRun ([datetime]::UtcNow.AddDays(1).ToString('o')))

        Start-CloudBackupOrchestrator | Should -Be 0

        Should -Invoke Start-CIPPOrchestrator -Times 0 -Exactly
        Should -Invoke Add-CIPPAzDataTableEntity -Times 0 -Exactly
    }

    It 'runs the given policy with -Force without moving its schedule, even when not due' {
        $script:Policies = @(New-CloudBackupPolicyRow -ConfigNextRun ([datetime]::UtcNow.AddDays(1).ToString('o')))

        Start-CloudBackupOrchestrator -PolicyId '11111111-1111-1111-1111-111111111111' -Force | Should -Be 'run-1'

        Should -Invoke Add-CIPPAzDataTableEntity -Times 0 -Exactly
        $script:Started.Count | Should -Be 1
    }

    It 'expands AllTenants to every tenant' {
        $script:Policies = @(New-CloudBackupPolicyRow -Tenants '[{"type":"AllTenants"}]')

        Start-CloudBackupOrchestrator | Out-Null

        @($script:Started[0].Batch.customerId | Sort-Object) | Should -Be @('c1', 'c2', 'c3')
        Should -Invoke New-CippQueueEntry -ParameterFilter { $TotalTasks -eq 3 }
    }

    It 'expands tenant groups through Expand-CIPPTenantGroups and drops unknown tenants' {
        $script:Policies = @(New-CloudBackupPolicyRow -Tenants '[{"type":"Group","id":"g1"},{"type":"Tenant","customerId":"c1"},{"type":"Tenant","customerId":"gone"}]')
        Mock Expand-CIPPTenantGroups {
            @(
                [pscustomobject]@{ value = 'fabrikam.com'; addedFields = [pscustomobject]@{ customerId = 'c2' }; type = 'Tenant' }
                [pscustomobject]@{ value = 'excluded.com'; addedFields = [pscustomobject]@{ customerId = 'excluded' }; type = 'Tenant' }
            )
        }

        Start-CloudBackupOrchestrator | Out-Null

        Should -Invoke Expand-CIPPTenantGroups -Times 1 -Exactly -ParameterFilter { $TenantFilter[0].type -eq 'Group' -and $TenantFilter[0].value -eq 'g1' }
        @($script:Started[0].Batch.customerId | Sort-Object) | Should -Be @('c1', 'c2')
    }

    It 'limits a forced run to the given tenant' {
        $script:Policies = @(New-CloudBackupPolicyRow -Tenants '[{"type":"AllTenants"}]')

        Start-CloudBackupOrchestrator -PolicyId '11111111-1111-1111-1111-111111111111' -TenantFilter 'fabrikam.com' -Force | Out-Null

        @($script:Started[0].Batch.customerId) | Should -Be @('c2')
    }

    It 'returns 0 when the given tenant is not part of the policy' {
        $script:Policies = @(New-CloudBackupPolicyRow)

        Start-CloudBackupOrchestrator -PolicyId '11111111-1111-1111-1111-111111111111' -TenantFilter 'fabrikam.com' -Force | Should -Be 0
        Should -Invoke Start-CIPPOrchestrator -Times 0 -Exactly
    }

    It 'passes the orchestrator Skipped result through' {
        $script:Policies = @(New-CloudBackupPolicyRow)
        Mock Start-CIPPOrchestrator { 'Craft-CloudBackup_x-Skipped' }

        Start-CloudBackupOrchestrator | Should -Be 'Craft-CloudBackup_x-Skipped'
    }

    It 'sets the retention rule when it is missing or different, and leaves a matching one alone' {
        $script:Policies = @(New-CloudBackupPolicyRow)
        Start-CloudBackupOrchestrator | Out-Null
        Should -Invoke Set-CIPPCloudBackupRetentionRule -Times 0 -Exactly

        Mock Get-CIPPCloudBackupRetentionRule { @{ Prefix = '11111111-1111-1111-1111-111111111111/'; Days = 30 } }
        Start-CloudBackupOrchestrator | Out-Null
        Should -Invoke Set-CIPPCloudBackupRetentionRule -Times 1 -Exactly -ParameterFilter { $RuleName -eq 'cipp-11111111-1111-1111-1111-111111111111' -and $Prefix -eq '11111111-1111-1111-1111-111111111111/' -and $Days -eq 90 }

        Mock Get-CIPPCloudBackupRetentionRule { }
        Start-CloudBackupOrchestrator | Out-Null
        Should -Invoke Set-CIPPCloudBackupRetentionRule -Times 2 -Exactly
    }

    It 'still queues the backup when the retention rule check fails' {
        $script:Policies = @(New-CloudBackupPolicyRow)
        Mock Get-CIPPCloudBackupRetentionRule { throw 'AuthorizationFailed' }

        Start-CloudBackupOrchestrator | Should -Be 'run-1'

        Should -Invoke Write-LogMessage -ParameterFilter { $sev -eq 'Warning' -and $message -like '*retention rule*' }
    }

    It 'prunes runs older than the retention with one delete over the policy partition' {
        $script:Policies = @(New-CloudBackupPolicyRow -RetentionDays 30)
        $script:OldRuns = @([pscustomobject]@{ PartitionKey = '11111111-1111-1111-1111-111111111111'; RowKey = 'old' })
        $Expected = '{0:D19}' -f ([datetime]::MaxValue.Ticks - [datetime]::UtcNow.AddDays(-30).Ticks)

        Start-CloudBackupOrchestrator | Out-Null

        Should -Invoke Get-CIPPAzDataTableEntity -Times 1 -Exactly -ParameterFilter {
            $TableName -eq 'CloudBackupRuns' -and $Filter -match "^PartitionKey eq '11111111-1111-1111-1111-111111111111' and RowKey gt '(\d{19})'$" -and
            [math]::Abs([long]$Matches[1] - [long]$Expected) -lt [timespan]::TicksPerMinute -and ($Property -contains 'RowKey')
        }
        @($script:Removed.RowKey) | Should -Be @('old')
    }

    It 'prunes compare and restore jobs older than 30 days with their results' {
        $script:OldJobs = @([pscustomobject]@{ PartitionKey = 'CloudBackupJob'; RowKey = 'job-1' })

        Start-CloudBackupOrchestrator | Out-Null

        Should -Invoke Get-CIPPAzDataTableEntity -Times 1 -Exactly -ParameterFilter {
            $TableName -eq 'CloudBackupJobs' -and $Filter -match "^PartitionKey eq 'CloudBackupJob' and CreatedAt lt '([^']+)'$" -and
            [math]::Abs(([datetimeoffset]::Parse($Matches[1]).UtcDateTime - [datetime]::UtcNow.AddDays(-30)).TotalMinutes) -lt 1 -and
            ($Property -contains 'PartitionKey') -and ($Property -contains 'RowKey')
        }
        Should -Invoke Remove-CIPPAzDataTableEntity -Times 1 -Exactly -ParameterFilter { $TableName -eq 'CloudBackupJobs' }
        @($script:RemovedJobs | ForEach-Object { "$($_.PartitionKey)/$($_.RowKey)" }) | Should -Be @('CloudBackupJob/job-1', 'CloudBackupJobResult/job-1')
    }

    It 'marks jobs still queued or running after 12 hours as failed' {
        $script:StuckJobs = @([pscustomobject]@{ PartitionKey = 'CloudBackupJob'; RowKey = 'job-2'; Status = 'Running'; Error = ''; CompletedAt = '' })

        Start-CloudBackupOrchestrator | Out-Null

        Should -Invoke Get-CIPPAzDataTableEntity -Times 1 -Exactly -ParameterFilter {
            $TableName -eq 'CloudBackupJobs' -and $Filter -match "^PartitionKey eq 'CloudBackupJob' and \(Status eq 'Queued' or Status eq 'Running'\) and CreatedAt lt '([^']+)'$" -and
            [math]::Abs(([datetimeoffset]::Parse($Matches[1]).UtcDateTime - [datetime]::UtcNow.AddHours(-12)).TotalMinutes) -lt 1
        }
        $script:JobWrites.Count | Should -Be 1
        $script:JobWrites[0].Status | Should -Be 'Failed'
        $script:JobWrites[0].Error | Should -Be 'The job did not finish within 12 hours'
    }

    It 'does not prune jobs on a forced run of one policy, and keeps backing up when pruning fails' {
        $script:Policies = @(New-CloudBackupPolicyRow)
        Start-CloudBackupOrchestrator -PolicyId '11111111-1111-1111-1111-111111111111' -Force | Out-Null
        Should -Invoke Get-CIPPAzDataTableEntity -Times 0 -Exactly -ParameterFilter { $TableName -eq 'CloudBackupJobs' }

        Mock Get-CIPPAzDataTableEntity { throw 'table down' } -ParameterFilter { $TableName -eq 'CloudBackupJobs' }
        Start-CloudBackupOrchestrator | Should -Be 'run-1'
        Should -Invoke Write-LogMessage -ParameterFilter { $sev -eq 'Warning' -and $message -like '*compare and restore jobs*' }
    }

    It 'skips a policy whose destination is gone' {
        $script:Policies = @(New-CloudBackupPolicyRow)
        Mock Get-CIPPCloudBackupDestination { }

        Start-CloudBackupOrchestrator | Should -BeFalse

        Should -Invoke Start-CIPPOrchestrator -Times 0 -Exactly
    }
}

Describe 'Cloud backup policy helpers' {
    It 'Get-CIPPCloudBackupPolicy parses JSON columns and ignores ids that are not GUIDs' {
        Mock Get-CIPPAzDataTableEntity { New-CloudBackupPolicyRow -Encryption $true -KeyIds '["k1","k2"]' -Tenants '[]' }

        $Policy = Get-CIPPCloudBackupPolicy -Id '11111111-1111-1111-1111-111111111111'
        $Policy.Id | Should -Be '11111111-1111-1111-1111-111111111111'
        @($Policy.ConfigAreas) | Should -Be @('ConditionalAccess', 'Intune')
        @($Policy.KeyIds) | Should -Be @('k1', 'k2')
        $Policy.Tenants.Count | Should -Be 0
        $Policy.Encryption | Should -BeTrue
        $Policy.RetentionDays | Should -Be 90

        Get-CIPPCloudBackupPolicy -Id "x' or PartitionKey ne '" | Should -BeNullOrEmpty
        Should -Invoke Get-CIPPAzDataTableEntity -Times 1 -Exactly
    }

    It 'Test-CIPPCloudBackupPolicyScope allows <Case>' -ForEach @(
        @{ Case = 'an unrestricted caller any target'; Allowed = @('AllTenants'); Tenants = @([pscustomobject]@{ type = 'AllTenants' }); Expected = $true }
        @{ Case = 'a restricted caller their own tenants'; Allowed = @('c1', 'c2'); Tenants = @([pscustomobject]@{ type = 'Tenant'; customerId = 'c1' }); Expected = $true }
        @{ Case = 'no other tenant'; Allowed = @('c1'); Tenants = @([pscustomobject]@{ type = 'Tenant'; customerId = 'c2' }); Expected = $false }
        @{ Case = 'no AllTenants target for a restricted caller'; Allowed = @('c1'); Tenants = @([pscustomobject]@{ type = 'AllTenants' }); Expected = $false }
        @{ Case = 'no group target for a restricted caller'; Allowed = @('c1'); Tenants = @([pscustomobject]@{ type = 'Group'; id = 'g1' }); Expected = $false }
        @{ Case = 'nothing to a caller with no tenants'; Allowed = @(); Tenants = @([pscustomobject]@{ type = 'Tenant'; customerId = 'c1' }); Expected = $false }
    ) {
        Test-CIPPCloudBackupPolicyScope -Tenants $Tenants -AllowedTenants $Allowed | Should -Be $Expected
    }
}
