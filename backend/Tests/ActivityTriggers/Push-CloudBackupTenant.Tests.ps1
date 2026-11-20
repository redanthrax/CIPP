BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'Fixtures/CloudBackup/CloudBackupTestStubs.ps1')

    function ConvertFrom-GzipBytes {
        param([byte[]]$Bytes)
        $Source = [System.IO.MemoryStream]::new($Bytes)
        $Gzip = [System.IO.Compression.GZipStream]::new($Source, [System.IO.Compression.CompressionMode]::Decompress)
        $Reader = [System.IO.StreamReader]::new($Gzip)
        try { $Reader.ReadToEnd() } finally { $Reader.Dispose() }
    }
}

Describe 'Push-CloudBackupTenant' {
    BeforeEach {
        $script:RunWrites = [System.Collections.Generic.List[object]]::new()
        $script:Uploads = [System.Collections.Generic.List[object]]::new()
        $script:PolicyRow = New-CloudBackupPolicyRow
        Mock Get-CIPPAzDataTableEntity { $script:PolicyRow } -ParameterFilter { $TableName -eq 'Config' }
        Mock Add-CIPPAzDataTableEntity { $script:RunWrites.Add(@{} + $Entity) } -ParameterFilter { $TableName -eq 'CloudBackupRuns' }
        Mock Get-Tenants { $script:CloudBackupTenants[0] }
        Mock Get-CIPPCloudBackupDestination { [pscustomobject]@{ RowKey = '22222222-2222-2222-2222-222222222222'; Name = 'Blob'; Provider = 'AzureBlob' } }
        Mock Get-CIPPCloudBackupConfigData {
            [pscustomobject]@{
                Sections = [ordered]@{
                    policies       = @([pscustomobject]@{ id = 'p1' }, [pscustomobject]@{ id = 'p2' })
                    namedLocations = @([pscustomobject]@{ id = 'n1' })
                }
                Warnings = @()
            }
        }
        Mock Set-CIPPCloudBackupObject { $script:Uploads.Add([pscustomobject]@{ Key = $Key; Body = $Body; ContentType = $ContentType }) }
        Mock Write-LogMessage { }
    }

    It 'writes a Running row first and finalises it as Succeeded' {
        Push-CloudBackupTenant -Item ([pscustomobject]@{ PolicyId = '11111111-1111-1111-1111-111111111111'; customerId = 'c1'; QueueName = 'contoso.com' })

        $script:RunWrites.Count | Should -Be 2
        $script:RunWrites[0].Status | Should -Be 'Running'
        $Final = $script:RunWrites[1]
        $Final.Status | Should -Be 'Succeeded'
        $Final.RowKey | Should -Be $script:RunWrites[0].RowKey
        $Final.RowKey | Should -Match '^\d{19}_c1$'
        $Final.PartitionKey | Should -Be '11111111-1111-1111-1111-111111111111'
        $Final.PolicyName | Should -Be 'Nightly'
        $Final.DestinationId | Should -Be '22222222-2222-2222-2222-222222222222'
        $Final.Tenant | Should -Be 'contoso.com'
        $Final.Workload | Should -Be 'Config'
        $Final.Items | Should -Be 6
        $Final.Bytes | Should -BeGreaterThan 0
        $Final.CompletedAt | Should -Not -BeNullOrEmpty
        $Areas = [CIPP.CippJson]::ConvertFromJson($Final.Areas)
        @($Areas.Area) | Should -Be @('ConditionalAccess', 'Intune')
        @($Areas.Status) | Should -Be @('Succeeded', 'Succeeded')
    }

    It 'uploads gzip area files and a manifest under the policy, tenant and timestamp prefix' {
        Push-CloudBackupTenant -Item ([pscustomobject]@{ PolicyId = '11111111-1111-1111-1111-111111111111'; customerId = 'c1' })

        $script:Uploads.Count | Should -Be 3
        $Prefix = $script:RunWrites[1].Location
        $Prefix | Should -Match '^11111111-1111-1111-1111-111111111111/c1/config/\d{8}T\d{6}Z/$'
        @($script:Uploads.Key) | Should -Be @("${Prefix}ConditionalAccess.json.gz", "${Prefix}Intune.json.gz", "${Prefix}manifest.json")

        $Document = ConvertFrom-GzipBytes $script:Uploads[0].Body | ConvertFrom-Json
        $Document.Area | Should -Be 'ConditionalAccess'
        $Document.TenantId | Should -Be 'c1'
        $Document.CapturedAt | Should -Not -BeNullOrEmpty
        @($Document.Sections.policies.id) | Should -Be @('p1', 'p2')

        $Manifest = [System.Text.Encoding]::UTF8.GetString($script:Uploads[2].Body) | ConvertFrom-Json
        $Manifest.PolicyId | Should -Be '11111111-1111-1111-1111-111111111111'
        $Manifest.TenantId | Should -Be 'c1'
        $Manifest.Encrypted | Should -BeFalse
        $Manifest.KeyId | Should -BeNullOrEmpty
        $Manifest.StartedAt | Should -Not -BeNullOrEmpty
        $Manifest.CompletedAt | Should -Not -BeNullOrEmpty
        $Manifest.Areas.Count | Should -Be 2
        $Manifest.Areas[0].Key | Should -Be $script:Uploads[0].Key
        $Manifest.Areas[0].Items | Should -Be 3
        $Manifest.Areas[0].Bytes | Should -Be $script:Uploads[0].Body.Length
        $Manifest.Areas[0].Sha256 | Should -Be ([Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($script:Uploads[0].Body)).ToLowerInvariant())
        @($Manifest.PSObject.Properties.Name) | Should -Be @('PolicyId', 'TenantId', 'DestinationId', 'StartedAt', 'CompletedAt', 'Encrypted', 'KeyId', 'Areas')
        $Manifest.DestinationId | Should -Be '22222222-2222-2222-2222-222222222222'
    }

    It 'stores the referenced group and user names in each area file' {
        Mock Get-CIPPCloudBackupConfigData { [pscustomobject]@{ Sections = [ordered]@{ policies = @() }; Warnings = @(); References = @{ Groups = @{ g1 = 'Sales' }; Users = @{ u1 = 'jane@contoso.com' } } } }

        Push-CloudBackupTenant -Item ([pscustomobject]@{ PolicyId = '11111111-1111-1111-1111-111111111111'; customerId = 'c1' })

        $Document = ConvertFrom-GzipBytes $script:Uploads[0].Body | ConvertFrom-Json
        @($Document.PSObject.Properties.Name) | Should -Be @('Area', 'TenantId', 'CapturedAt', 'Sections', 'References')
        $Document.References.Groups.g1 | Should -Be 'Sales'
        $Document.References.Users.u1 | Should -Be 'jane@contoso.com'
    }

    It 'stores empty references when the area returns none' {
        Push-CloudBackupTenant -Item ([pscustomobject]@{ PolicyId = '11111111-1111-1111-1111-111111111111'; customerId = 'c1' })

        $Document = ConvertFrom-GzipBytes $script:Uploads[0].Body | ConvertFrom-Json
        @($Document.References.Groups.PSObject.Properties).Count | Should -Be 0
        @($Document.References.Users.PSObject.Properties).Count | Should -Be 0
    }

    It 'encrypts area files with the current key when encryption is on' {
        $script:PolicyRow = New-CloudBackupPolicyRow -Encryption $true -CurrentKeyId 'key-1' -KeyIds '["key-1"]'
        Mock Get-CIPPCloudBackupKey { [byte[]]::new(32) }
        Mock Protect-CIPPCloudBackupData { [byte[]](1, 2, 3) }

        Push-CloudBackupTenant -Item ([pscustomobject]@{ PolicyId = '11111111-1111-1111-1111-111111111111'; customerId = 'c1' })

        Should -Invoke Protect-CIPPCloudBackupData -Times 2 -Exactly -ParameterFilter { $KeyId -eq 'key-1' -and $Key.Length -eq 32 }
        $script:Uploads[0].Key | Should -BeLike '*ConditionalAccess.json.gz.enc'
        $script:Uploads[0].ContentType | Should -Be 'application/octet-stream'
        $Manifest = [System.Text.Encoding]::UTF8.GetString($script:Uploads[2].Body) | ConvertFrom-Json
        $Manifest.Encrypted | Should -BeTrue
        $Manifest.KeyId | Should -Be 'key-1'
        $Manifest.Areas[0].Bytes | Should -Be 3
        $script:Uploads[2].Key | Should -BeLike '*manifest.json'
    }

    It 'reads secret values only when the policy encrypts its backups' {
        Push-CloudBackupTenant -Item ([pscustomobject]@{ PolicyId = '11111111-1111-1111-1111-111111111111'; customerId = 'c1' })
        Should -Invoke Get-CIPPCloudBackupConfigData -ParameterFilter { -not $IncludeSecrets } -Times 2 -Exactly

        $script:PolicyRow = New-CloudBackupPolicyRow -Encryption $true -CurrentKeyId 'key-1' -KeyIds '["key-1"]'
        Mock Get-CIPPCloudBackupKey { [byte[]]::new(32) }
        Mock Protect-CIPPCloudBackupData { [byte[]](1, 2, 3) }
        Push-CloudBackupTenant -Item ([pscustomobject]@{ PolicyId = '11111111-1111-1111-1111-111111111111'; customerId = 'c1' })
        Should -Invoke Get-CIPPCloudBackupConfigData -ParameterFilter { $IncludeSecrets } -Times 2 -Exactly
    }

    It 'fails the run when encryption is on but no key exists' {
        $script:PolicyRow = New-CloudBackupPolicyRow -Encryption $true

        Push-CloudBackupTenant -Item ([pscustomobject]@{ PolicyId = '11111111-1111-1111-1111-111111111111'; customerId = 'c1' })

        $script:RunWrites[1].Status | Should -Be 'Failed'
        $script:Uploads.Count | Should -Be 0
        $script:RunWrites[1].Warnings | Should -Match 'no encryption key'
    }

    It 'keeps backing up other areas when one fails and marks the run PartialSuccess' {
        Mock Get-CIPPCloudBackupConfigData { throw 'Graph said no' } -ParameterFilter { $Area -eq 'ConditionalAccess' }

        Push-CloudBackupTenant -Item ([pscustomobject]@{ PolicyId = '11111111-1111-1111-1111-111111111111'; customerId = 'c1' })

        $Final = $script:RunWrites[1]
        $Final.Status | Should -Be 'PartialSuccess'
        $Areas = [CIPP.CippJson]::ConvertFromJson($Final.Areas)
        $Areas[0].Status | Should -Be 'Failed'
        $Areas[0].Error | Should -Be 'Graph said no'
        $Areas[1].Status | Should -Be 'Succeeded'
        @($script:Uploads.Key).Where({ $_ -like '*Intune.json.gz' }).Count | Should -Be 1
    }

    It 'marks the run PartialSuccess when an area returns warnings' {
        Mock Get-CIPPCloudBackupConfigData { [pscustomobject]@{ Sections = [ordered]@{ policies = @() }; Warnings = @('ConditionalAccess namedLocations: forbidden') } }

        Push-CloudBackupTenant -Item ([pscustomobject]@{ PolicyId = '11111111-1111-1111-1111-111111111111'; customerId = 'c1' })

        $Final = $script:RunWrites[1]
        $Final.Status | Should -Be 'PartialSuccess'
        @([CIPP.CippJson]::ConvertFromJson($Final.Warnings)) | Should -Contain 'ConditionalAccess namedLocations: forbidden'
    }

    It 'marks the run Failed when no area uploads' {
        Mock Set-CIPPCloudBackupObject { throw 'AuthorizationFailure' }

        Push-CloudBackupTenant -Item ([pscustomobject]@{ PolicyId = '11111111-1111-1111-1111-111111111111'; customerId = 'c1' })

        $script:RunWrites[1].Status | Should -Be 'Failed'
        $script:RunWrites[1].Items | Should -Be 0
    }

    It 'finalises the row as Failed when the policy is gone, without throwing' {
        Mock Get-CIPPAzDataTableEntity { } -ParameterFilter { $TableName -eq 'Config' }

        { Push-CloudBackupTenant -Item ([pscustomobject]@{ PolicyId = '11111111-1111-1111-1111-111111111111'; customerId = 'c1' }) } | Should -Not -Throw

        $script:RunWrites.Count | Should -Be 2
        $script:RunWrites[1].Status | Should -Be 'Failed'
        $script:RunWrites[1].Warnings | Should -Match 'no longer exists'
    }

    It 'finalises the row as Failed when the tenant cannot be found' {
        Mock Get-Tenants { }

        Push-CloudBackupTenant -Item ([pscustomobject]@{ PolicyId = '11111111-1111-1111-1111-111111111111'; customerId = 'c9' })

        $script:RunWrites[1].Status | Should -Be 'Failed'
        Should -Invoke Get-CIPPCloudBackupConfigData -Times 0 -Exactly
    }
}
