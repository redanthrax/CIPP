BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'Fixtures/CloudBackup/CloudBackupTestStubs.ps1')
    $script:RunId = '11111111-1111-1111-1111-111111111111_0000000000000000001_c1'
    $script:OtherRunId = '11111111-1111-1111-1111-111111111111_0000000000000000002_c2'
    function Invoke-Compare { param($Body) Invoke-ExecCloudBackupCompare -Request (New-CloudBackupRequest -Endpoint 'ExecCloudBackupCompare' -Body $Body) }
}

Describe 'Invoke-ExecCloudBackupCompare' {
    BeforeEach {
        $script:Allowed = @('AllTenants')
        $script:Runs = @(
            New-CloudBackupRunRow
            New-CloudBackupRunRow -RowKey '0000000000000000002_c2' -TenantId 'c2' -Tenant 'fabrikam.com'
        )
        $script:JobWrites = [System.Collections.Generic.List[object]]::new()
        $script:Started = [System.Collections.Generic.List[object]]::new()
        Mock Test-CIPPAccess { $script:Allowed }
        Mock Get-Tenants { $script:CloudBackupTenants }
        Mock Get-CIPPAzDataTableEntity { @($script:Runs).Where({ $Filter -eq "PartitionKey eq '$($_.PartitionKey)' and RowKey eq '$($_.RowKey)'" }) } -ParameterFilter { $TableName -eq 'CloudBackupRuns' }
        Mock Add-CIPPAzDataTableEntity { $script:JobWrites.Add(@{} + $Entity) } -ParameterFilter { $TableName -eq 'CloudBackupJobs' }
        Mock Start-CIPPOrchestrator { $script:Started.Add($InputObject); 'Craft-run' }
        Mock Write-LogMessage { }
    }

    It 'returns 400 for <Case>' -ForEach @(
        @{ Case = 'a bad RunId'; Body = @{ RunId = 'x' } }
        @{ Case = 'a bad CompareTo'; Body = @{ RunId = '11111111-1111-1111-1111-111111111111_0000000000000000001_c1'; CompareTo = 'yesterday' } }
        @{ Case = 'the same run'; Body = @{ RunId = '11111111-1111-1111-1111-111111111111_0000000000000000001_c1'; CompareTo = '11111111-1111-1111-1111-111111111111_0000000000000000001_c1' } }
        @{ Case = 'a bad area'; Body = @{ RunId = '11111111-1111-1111-1111-111111111111_0000000000000000001_c1'; Areas = @('Teams') } }
    ) {
        (Invoke-Compare -Body $Body).StatusCode | Should -Be 400
        Should -Invoke Start-CIPPOrchestrator -Times 0 -Exactly
    }

    It 'returns 404 for an unknown run or CompareTo run' {
        (Invoke-Compare -Body @{ RunId = '11111111-1111-1111-1111-111111111111_0000000000000000009_c1' }).StatusCode | Should -Be 404
        (Invoke-Compare -Body @{ RunId = $script:RunId; CompareTo = '11111111-1111-1111-1111-111111111111_0000000000000000009_c2' }).StatusCode | Should -Be 404
    }

    It 'returns 403 when the caller cannot access either run''s tenant' {
        $script:Allowed = @('c1')
        (Invoke-Compare -Body @{ RunId = $script:RunId; CompareTo = $script:OtherRunId }).StatusCode | Should -Be 403
        $script:Allowed = @('c2')
        (Invoke-Compare -Body @{ RunId = $script:RunId }).StatusCode | Should -Be 403
    }

    It 'returns 400 for a failed backup run' {
        $script:Runs = @(New-CloudBackupRunRow -Status 'Failed')
        (Invoke-Compare -Body @{ RunId = $script:RunId }).StatusCode | Should -Be 400
    }

    It 'queues a compare with the current configuration by default' {
        $Response = Invoke-Compare -Body @{ RunId = $script:RunId; Areas = @('Intune', 'ConditionalAccess') }

        $Response.StatusCode | Should -Be 202
        $Job = $script:JobWrites[0]
        $Response.Body.JobId | Should -Be $Job.RowKey
        $Job.Type | Should -Be 'Compare'
        $Job.Status | Should -Be 'Queued'
        $Job.CompareToRunId | Should -Be ''
        $Job.SourceTenantId | Should -Be 'c1'
        $Job.TargetTenantId | Should -Be 'c1'
        $Job.RequestedBy | Should -Be 'admin@partner.com'
        $Parameters = [CIPP.CippJson]::ConvertFromJson($Job.Parameters)
        $Parameters.CompareTo | Should -Be 'Live'
        @($Parameters.Areas) | Should -Be @('ConditionalAccess', 'Intune')
        $script:Started[0].Batch[0].JobId | Should -Be $Job.RowKey
        $script:Started[0].OrchestratorName | Should -Be "CloudBackupJob_$($Job.RowKey)"
    }

    It 'queues a compare with another run and targets that run''s tenant' {
        (Invoke-Compare -Body @{ RunId = $script:RunId; CompareTo = $script:OtherRunId }).StatusCode | Should -Be 202

        $Job = $script:JobWrites[0]
        $Job.CompareToRunId | Should -Be $script:OtherRunId
        $Job.TargetTenantId | Should -Be 'c2'
        $Job.TargetTenant | Should -Be 'fabrikam.com'
    }
}
