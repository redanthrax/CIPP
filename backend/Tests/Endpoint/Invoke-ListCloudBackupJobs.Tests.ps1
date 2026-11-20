BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'Fixtures/CloudBackup/CloudBackupTestStubs.ps1')
    function Invoke-Jobs { param($Query) Invoke-ListCloudBackupJobs -Request (New-CloudBackupRequest -Endpoint 'ListCloudBackupJobs' -Query $Query) }
    function New-JobRow {
        param($Id, $Source = 'c1', $Target = 'c1', $CreatedAt = '2026-11-01T00:00:00.0000000Z', $Type = 'Compare')
        [pscustomobject]@{
            PartitionKey   = 'CloudBackupJob'
            RowKey         = $Id
            Type           = $Type
            Status         = 'Completed'
            RunId          = '11111111-1111-1111-1111-111111111111_0000000000000000001_c1'
            CompareToRunId = ''
            SourceTenantId = $Source
            SourceTenant   = 'old.example'
            TargetTenantId = $Target
            TargetTenant   = 'old.example'
            Parameters     = '{"RunId":"x","CompareTo":"Live","Areas":[]}'
            PreviewJobId   = ''
            RequestedBy    = 'admin@partner.com'
            CreatedAt      = $CreatedAt
            StartedAt      = $CreatedAt
            CompletedAt    = $CreatedAt
            Summary        = '{"Intune":{"Added":1,"Removed":0,"Changed":2,"Unchanged":3}}'
            Error          = ''
        }
    }
}

Describe 'Invoke-ListCloudBackupJobs' {
    BeforeEach {
        $script:Allowed = @('AllTenants')
        $script:JobRows = @(
            New-JobRow -Id 'aaaaaaaa-0000-0000-0000-000000000001' -CreatedAt '2026-11-01T00:00:00.0000000Z'
            New-JobRow -Id 'aaaaaaaa-0000-0000-0000-000000000002' -CreatedAt '2026-11-03T00:00:00.0000000Z' -Target 'c2' -Type 'RestorePreview'
            New-JobRow -Id 'aaaaaaaa-0000-0000-0000-000000000003' -CreatedAt '2026-11-02T00:00:00.0000000Z' -Source 'c3' -Target 'c3'
        )
        $script:ResultRows = @{}
        Mock Test-CIPPAccess { $script:Allowed }
        Mock Get-Tenants { $script:CloudBackupTenants }
        Mock Get-CIPPAzDataTableEntity {
            if ($Filter -match "PartitionKey eq 'CloudBackupJobResult' and RowKey eq '([^']+)'") { return $script:ResultRows[$Matches[1]] }
            if ($Filter -match "RowKey eq '([^']+)'") { $Key = $Matches[1]; return @($script:JobRows).Where({ $_.RowKey -eq $Key }) }
            $script:JobRows
        } -ParameterFilter { $TableName -eq 'CloudBackupJobs' }
        Mock Write-LogMessage { }
    }

    It 'returns 400 for a bad id' {
        (Invoke-Jobs -Query @{ Id = 'nope' }).StatusCode | Should -Be 400
    }

    It 'lists jobs newest first without results, with current tenant names and parsed summaries' {
        $Response = Invoke-Jobs

        $Response.StatusCode | Should -Be 200
        $Rows = @($Response.Body)
        @($Rows.Id) | Should -Be @('aaaaaaaa-0000-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-000000000003', 'aaaaaaaa-0000-0000-0000-000000000001')
        $Rows[0].TargetTenant | Should -Be 'fabrikam.com'
        $Rows[0].SourceTenant | Should -Be 'contoso.com'
        $Rows[0].Summary.Intune.Changed | Should -Be 2
        $Rows[0].Parameters.CompareTo | Should -Be 'Live'
        $Rows[0].PSObject.Properties['Result'] | Should -BeNullOrEmpty
        Should -Invoke Get-CIPPAzDataTableEntity -Times 1 -Exactly -ParameterFilter { $TableName -eq 'CloudBackupJobs' }
    }

    It 'lists only jobs whose source and target tenants the caller can access' {
        $script:Allowed = @('c1', 'c3')
        @((Invoke-Jobs).Body.Id) | Should -Be @('aaaaaaaa-0000-0000-0000-000000000003', 'aaaaaaaa-0000-0000-0000-000000000001')
    }

    It 'returns one job with its parsed result' {
        $script:ResultRows['aaaaaaaa-0000-0000-0000-000000000001'] = [pscustomobject]@{ PartitionKey = 'CloudBackupJobResult'; RowKey = 'aaaaaaaa-0000-0000-0000-000000000001'; Result = '[{"Area":"Intune","Key":"k1","Change":"Changed","Differences":[{"Path":"a","Reference":1,"Difference":2}]}]' }

        $Response = Invoke-Jobs -Query @{ Id = 'aaaaaaaa-0000-0000-0000-000000000001' }

        $Response.StatusCode | Should -Be 200
        $Response.Body.Id | Should -Be 'aaaaaaaa-0000-0000-0000-000000000001'
        @($Response.Body.Result).Count | Should -Be 1
        $Response.Body.Result[0].Differences[0].Path | Should -Be 'a'
    }

    It 'returns an empty result for a job that has none yet' {
        @((Invoke-Jobs -Query @{ Id = 'aaaaaaaa-0000-0000-0000-000000000001' }).Body.Result).Count | Should -Be 0
    }

    It 'returns a provisioning job with its steps and its result as one object' {
        $Row = New-JobRow -Id 'aaaaaaaa-0000-0000-0000-000000000005' -Type 'Provision' -Source '' -Target ''
        $Row.PSObject.Properties.Add([psnoteproperty]::new('Steps', '[{"Name":"ResourceGroup","Status":"Completed","Message":"Created","Error":""},{"Name":"StorageAccount","Status":"Failed","Message":"","Error":"denied"}]'))
        $script:JobRows = @($Row)
        $script:ResultRows['aaaaaaaa-0000-0000-0000-000000000005'] = [pscustomobject]@{ Result = '{"SubscriptionId":"s","ResourceGroup":"rg","StorageAccount":"cippbkabc","Container":"cipp-backups","Region":"westeurope","DestinationId":null}' }

        $Body = (Invoke-Jobs -Query @{ Id = 'aaaaaaaa-0000-0000-0000-000000000005' }).Body

        $Body.Type | Should -Be 'Provision'
        @($Body.Steps).Count | Should -Be 2
        $Body.Steps[1].Status | Should -Be 'Failed'
        $Body.Result | Should -Not -BeOfType [array]
        $Body.Result.StorageAccount | Should -Be 'cippbkabc'
        $Body.Result.Region | Should -Be 'westeurope'
    }

    It 'returns 404 for an unknown job and 403 for a job in another tenant' {
        (Invoke-Jobs -Query @{ Id = 'aaaaaaaa-0000-0000-0000-000000000009' }).StatusCode | Should -Be 404
        $script:Allowed = @('c1')
        (Invoke-Jobs -Query @{ Id = 'aaaaaaaa-0000-0000-0000-000000000002' }).StatusCode | Should -Be 403
    }
}
