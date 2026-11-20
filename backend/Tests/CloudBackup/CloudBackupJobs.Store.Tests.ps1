BeforeDiscovery {
    $script:StoreAvailable = $false
    $Client = [System.Net.Sockets.TcpClient]::new()
    try { $script:StoreAvailable = $Client.ConnectAsync('127.0.0.1', 10002).Wait(1000) } catch { } finally { $Client.Dispose() }
}

BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'Fixtures/CloudBackup/CloudBackupTestStubs.ps1')
    $BackendRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $BackendRoot 'Modules/AzBobbyTables') -ErrorAction Stop
    foreach ($File in @('Add-CIPPAzDataTableEntity.ps1', 'Get-CIPPAzDatatableEntity.ps1', 'Remove-CIPPAzDataTableEntity.ps1', 'GraphHelper/Test-CIPPTableNotFound.ps1', 'GraphHelper/Repair-CIPPTable.ps1')) {
        . (Join-Path $BackendRoot "Modules/CIPPCore/Public/$File")
    }

    $script:JobId = [guid]::NewGuid().ToString()
    $script:TableName = 'CloudBackupJobsTest' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $script:Context = $null
    # Azurite's well-known development account key
    $ConnectionString = 'DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;AccountKey=Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==;TableEndpoint=http://127.0.0.1:10002/devstoreaccount1;'
    $script:Context = New-AzDataTableContext -ConnectionString $ConnectionString -TableName $script:TableName
    function Get-CIPPTable { param($TableName) @{ Context = $script:Context } }
}

AfterAll {
    if ($script:Context) { try { Remove-AzDataTable -Context $script:Context } catch { } }
}

Describe 'Cloud backup jobs against table storage' -Skip:(-not $script:StoreAvailable) {
    BeforeAll {
        New-AzDataTable -Context $script:Context
        $script:Differences = @(foreach ($i in 1..40) { [pscustomobject]@{ Path = "setting$i"; Reference = ('a' * 2000); Difference = ('b' * 2000) } })
        Mock Get-Tenants { $script:CloudBackupTenants }
        Mock Test-CIPPAccess { @('AllTenants') }
        Mock Write-LogMessage { }
        Mock Get-CIPPCloudBackupSnapshot { [pscustomobject]@{ Areas = [ordered]@{ Intune = [pscustomobject]@{ Sections = [ordered]@{}; References = @{} } } } }
        Mock Get-CIPPCloudBackupConfigData { [pscustomobject]@{ Sections = [ordered]@{}; Warnings = @() } }
        Mock Compare-CIPPCloudBackupConfig {
            foreach ($i in 1..60) { [pscustomobject]@{ Area = 'Intune'; Section = 'configurationPolicies'; SectionLabel = 'Settings'; Key = "k$i"; Name = "Policy $i"; Change = 'Changed'; Differences = $script:Differences } }
        }

        Add-CIPPAzDataTableEntity -Context $script:Context -Force -Entity @{
            PartitionKey   = 'CloudBackupJob'
            RowKey         = $script:JobId
            Type           = 'Compare'
            Status         = 'Queued'
            RunId          = '11111111-1111-1111-1111-111111111111_0000000000000000001_c1'
            CompareToRunId = ''
            SourceTenantId = 'c1'
            SourceTenant   = 'contoso.com'
            TargetTenantId = 'c1'
            TargetTenant   = 'contoso.com'
            Parameters     = '{"RunId":"x","CompareTo":"Live","Areas":["Intune"]}'
            ParametersHash = 'h'
            PreviewJobId   = ''
            RequestedBy    = 'admin@partner.com'
            CreatedAt      = [datetime]::UtcNow.AddDays(-31).ToString('o')
        }
        Push-CloudBackupJob -Item ([pscustomobject]@{ JobId = $script:JobId })
    }

    It 'splits the large result over several rows' {
        @(Get-AzDataTableEntity -Context $script:Context -Filter "PartitionKey eq 'CloudBackupJobResult'" -Property PartitionKey, RowKey).Count | Should -BeGreaterThan 1
    }

    It 'returns the whole result for ListCloudBackupJobs with an id' {
        $Response = Invoke-ListCloudBackupJobs -Request (New-CloudBackupRequest -Endpoint 'ListCloudBackupJobs' -Query @{ Id = $script:JobId })

        $Response.StatusCode | Should -Be 200
        $Response.Body.Status | Should -Be 'Completed'
        @($Response.Body.Result).Count | Should -Be 60
        $Response.Body.Result[59].Differences[39].Difference | Should -Be ('b' * 2000)
    }

    It 'lists the job once without its result' {
        $Rows = @((Invoke-ListCloudBackupJobs -Request (New-CloudBackupRequest -Endpoint 'ListCloudBackupJobs')).Body)

        $Rows.Count | Should -Be 1
        $Rows[0].Id | Should -Be $script:JobId
        $Rows[0].PSObject.Properties['Result'] | Should -BeNullOrEmpty
    }

    It 'prunes the old job and every row of its result' {
        Mock Get-CIPPCloudBackupPolicy { }

        Start-CloudBackupOrchestrator | Out-Null

        @(Get-AzDataTableEntity -Context $script:Context -Filter "PartitionKey eq 'CloudBackupJob' or PartitionKey eq 'CloudBackupJobResult'" -Property PartitionKey, RowKey).Count | Should -Be 0
    }
}
