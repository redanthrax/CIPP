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

    $script:Suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $script:Contexts = @{}
    # Azurite's well-known development account key
    $script:ConnectionString = 'DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;AccountKey=Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==;TableEndpoint=http://127.0.0.1:10002/devstoreaccount1;'
    function Get-CIPPTable {
        param($TableName)
        if (-not $script:Contexts.ContainsKey($TableName)) {
            $script:Contexts[$TableName] = New-AzDataTableContext -ConnectionString $script:ConnectionString -TableName ("$TableName$($script:Suffix)" -replace '[^A-Za-z0-9]', '')
            New-AzDataTable -Context $script:Contexts[$TableName]
        }
        @{ Context = $script:Contexts[$TableName] }
    }
    $script:PolicyId = '11111111-1111-1111-1111-111111111111'
    $script:RunId = "$($script:PolicyId)_0000000000000000001_c1_sharepoint"
}

AfterAll {
    foreach ($Context in $script:Contexts.Values) { try { Remove-AzDataTable -Context $Context } catch { } }
}

Describe 'Cloud backup state and run rows against table storage' -Skip:(-not $script:StoreAvailable) {
    BeforeAll {
        $ConfigTable = Get-CIPPTable -TableName 'Config'
        $Policy = New-CloudBackupPolicyRow -Workloads '["sharepoint"]'
        $PolicyEntity = @{}
        foreach ($Property in $Policy.PSObject.Properties) { $PolicyEntity[$Property.Name] = $Property.Value }
        Add-CIPPAzDataTableEntity @ConfigTable -Entity $PolicyEntity -Force

        $RunsTable = Get-CIPPTable -TableName 'CloudBackupRuns'
        Add-CIPPAzDataTableEntity @RunsTable -Entity @{ PartitionKey = $script:PolicyId; RowKey = '0000000000000000001_c1_sharepoint'; Owners = 3; Warnings = '[]'; Status = 'Running'; Tenant = 'contoso.com'; TenantId = 'c1'; Workload = 'sharepoint'; PolicyName = 'Nightly' } -Force

        Mock Get-Tenants { $script:CloudBackupTenants[0] }
        Mock Get-CIPPCloudBackupDestination { [pscustomobject]@{ Id = '22222222-2222-2222-2222-222222222222'; Name = 'Blob'; Provider = 'AzureBlob' } }
        Mock Send-CIPPCloudBackupObjectStream { [pscustomobject]@{ Key = $Key; Bytes = 1; VersionId = 'v1' } }
        Mock Write-LogMessage { }

        $Folders = [ordered]@{}
        foreach ($i in 1..2500) { $Folders["AAMkAD$($i)xYz=="] = "https://graph.microsoft.com/beta/drives/b!$i/root/delta?token=" + ('Qw' * 100) }
        $script:BigState = [ordered]@{ RunId = 'previous'; Drives = $Folders }
        $script:BigJson = [CIPP.CippJson]::ToJson($script:BigState, 20)
        Mock Invoke-CIPPCloudBackupSharePointStep {
            [pscustomobject]@{ State = $script:BigState; Done = $true; Items = 2; Bytes = 20; Deleted = 1; Warnings = @(); IndexEntries = @() }
        }
        foreach ($Owner in @('contoso.sharepoint.com,a1,b1', 'contoso.sharepoint.com,a2,b2', 'contoso.sharepoint.com,a3,b3')) {
            Push-CloudBackupOwner -Item ([pscustomobject]@{ PolicyId = $script:PolicyId; customerId = 'c1'; Workload = 'sharepoint'; OwnerId = $Owner; OwnerType = 'Site'; DisplayName = $Owner; RunId = $script:RunId; RunStamp = '20261120T000000Z' })
        }
    }

    It 'stores and reads back a state of several hundred KB whole' {
        $script:BigJson.Length | Should -BeGreaterThan 500000
        $StateTable = Get-CIPPTable -TableName 'CloudBackupState'
        $Row = @(Get-CIPPAzDataTableEntity @StateTable -Filter "PartitionKey eq '$($script:PolicyId)_c1' and RowKey eq 'sharepoint_contoso.sharepoint.com,a2,b2'")[0]

        $Row.Status | Should -Be 'Idle'
        $Row.OwnerType | Should -Be 'Site'
        $Row.State.Length | Should -Be $script:BigJson.Length
        $Row.State | Should -BeExactly $script:BigJson
    }

    It 'gives the stored state back to the next step intact' {
        $script:Seen = $null
        Mock Invoke-CIPPCloudBackupSharePointStep {
            $script:Seen = $State
            [pscustomobject]@{ State = $State; Done = $true; Items = 0; Bytes = 0; Deleted = 0; Warnings = @(); IndexEntries = @() }
        }

        Push-CloudBackupOwner -Item ([pscustomobject]@{ PolicyId = $script:PolicyId; customerId = 'c1'; Workload = 'sharepoint'; OwnerId = 'contoso.sharepoint.com,a1,b1'; OwnerType = 'Site'; RunId = "$($script:PolicyId)_0000000000000000002_c1_sharepoint"; RunStamp = '20261120T060000Z' })

        $script:Seen.Drives.Count | Should -Be 2500
        $script:Seen.Drives['AAMkAD2500xYz=='] | Should -BeLike '*token=QwQw*'
        $script:Seen.RunId | Should -Be 'previous'
    }

    It 'finalises the run from every owner row of the partition' {
        Push-CloudBackupRunFinalise -Item @{ Parameters = @{ RunId = $script:RunId } }

        $RunsTable = Get-CIPPTable -TableName 'CloudBackupRuns'
        $Run = @(Get-CIPPAzDataTableEntity @RunsTable -Filter "PartitionKey eq '$($script:PolicyId)' and RowKey eq '0000000000000000001_c1_sharepoint'")[0]
        $Run.Status | Should -Be 'Succeeded'
        $Run.Items | Should -Be 6
        $Run.Bytes | Should -Be 60
        $Run.Deleted | Should -Be 3
        $Run.OwnersSucceeded | Should -Be 3
        $Run.OwnersFailed | Should -Be 0
        $Run.Tenant | Should -Be 'contoso.com'
    }

    It 'lists the per-owner results of the run' {
        Mock Test-CIPPAccess { @('AllTenants') }

        $Response = Invoke-ListCloudBackupRunOwners -Request (New-CloudBackupRequest -Endpoint 'ListCloudBackupRunOwners' -Query @{ RunId = $script:RunId })

        $Response.StatusCode | Should -Be 200
        @($Response.Body.OwnerId | Sort-Object) | Should -Be @('contoso.sharepoint.com,a1,b1', 'contoso.sharepoint.com,a2,b2', 'contoso.sharepoint.com,a3,b3')
        @($Response.Body.Status | Select-Object -Unique) | Should -Be @('Succeeded')
    }

    It 'lists and prunes compare and restore jobs with large results' {
        Mock Test-CIPPAccess { @('AllTenants') }
        Mock Get-CIPPCloudBackupPolicy { }
        $JobsTable = Get-CIPPTable -TableName 'CloudBackupJobs'
        $JobId = [guid]::NewGuid().ToString()
        $Result = @(foreach ($i in 1..60) { [pscustomobject]@{ Key = "k$i"; Detail = ('b' * 4000) } })
        Add-CIPPAzDataTableEntity @JobsTable -Force -Entity @{ PartitionKey = 'CloudBackupJob'; RowKey = $JobId; Type = 'Restore'; Status = 'Completed'; SourceTenantId = 'c1'; TargetTenantId = 'c1'; CreatedAt = [datetime]::UtcNow.AddDays(-31).ToString('o') }
        Add-CIPPAzDataTableEntity @JobsTable -Force -Entity @{ PartitionKey = 'CloudBackupJobResult'; RowKey = $JobId; Result = [CIPP.CippJson]::ToJson($Result, 5) }

        $One = Invoke-ListCloudBackupJobs -Request (New-CloudBackupRequest -Endpoint 'ListCloudBackupJobs' -Query @{ Id = $JobId })
        $One.StatusCode | Should -Be 200
        @($One.Body.Result).Count | Should -Be 60
        $One.Body.Result[59].Detail | Should -Be ('b' * 4000)

        Start-CloudBackupOrchestrator | Out-Null
        @(Get-AzDataTableEntity -Context $script:Contexts['CloudBackupJobs'] -Filter "PartitionKey eq 'CloudBackupJob' or PartitionKey eq 'CloudBackupJobResult'" -Property PartitionKey, RowKey).Count | Should -Be 0
    }
}
