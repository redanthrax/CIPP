BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'Fixtures/CloudBackup/CloudBackupTestStubs.ps1')
    $Folder = Join-Path $BackendRoot 'Modules/CIPPCore/Public/CloudBackup'
    . (Join-Path $Folder 'Protect-CIPPCloudBackupData.ps1')
    . (Join-Path $Folder 'Unprotect-CIPPCloudBackupData.ps1')
    . (Join-Path $Folder 'Get-CIPPCloudBackupSnapshot.ps1')
    function Get-CIPPCloudBackupObject { param($Destination, $Key) }

    $script:PolicyId = '11111111-1111-1111-1111-111111111111'
    $script:KeyId = '33333333-3333-3333-3333-333333333333'
    $script:Key = [System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32)

    function script:Invoke-Backup {
        Push-CloudBackupTenant -Item ([pscustomobject]@{ PolicyId = $script:PolicyId; customerId = 'c1'; QueueName = 'contoso.com' })
        "$($script:PolicyId)_$($script:RunWrites[-1].RowKey)"
    }

    function script:ConvertTo-GzipBytes {
        param([string]$Text)
        $Buffer = [System.IO.MemoryStream]::new()
        $Gzip = [System.IO.Compression.GZipStream]::new($Buffer, [System.IO.Compression.CompressionLevel]::Optimal, $true)
        $Writer = [System.IO.StreamWriter]::new($Gzip, [System.Text.UTF8Encoding]::new($false))
        $Writer.Write($Text)
        $Writer.Dispose()
        , $Buffer.ToArray()
    }
}

Describe 'Get-CIPPCloudBackupSnapshot' {
    BeforeEach {
        $script:RunWrites = [System.Collections.Generic.List[object]]::new()
        $script:Store = @{}
        $script:PolicyRow = New-CloudBackupPolicyRow
        Mock Get-CIPPAzDataTableEntity { $script:PolicyRow } -ParameterFilter { $TableName -eq 'Config' }
        Mock Get-CIPPAzDataTableEntity {
            $Latest = $null
            foreach ($Run in $script:RunWrites) { if ($Filter -eq "PartitionKey eq '$($Run.PartitionKey)' and RowKey eq '$($Run.RowKey)'") { $Latest = [pscustomobject]$Run } }
            $Latest
        } -ParameterFilter { $TableName -eq 'CloudBackupRuns' }
        Mock Add-CIPPAzDataTableEntity { $script:RunWrites.Add(@{} + $Entity) } -ParameterFilter { $TableName -eq 'CloudBackupRuns' }
        Mock Get-Tenants { $script:CloudBackupTenants[0] }
        Mock Get-CIPPCloudBackupDestination { [pscustomobject]@{ Id = '22222222-2222-2222-2222-222222222222'; Name = 'Blob'; Provider = 'AzureBlob' } }
        Mock Get-CIPPCloudBackupConfigData {
            if ($Area -eq 'ConditionalAccess') {
                [pscustomobject]@{
                    Sections   = [ordered]@{
                        policies       = @([pscustomobject]@{ id = 'p1'; displayName = 'MFA'; conditions = [pscustomobject]@{ users = [pscustomobject]@{ includeGroups = @('g1') } } }, [pscustomobject]@{ id = 'p2'; displayName = 'Block' })
                        namedLocations = @()
                    }
                    Warnings   = @()
                    References = @{ Groups = @{ g1 = 'Sales' }; Users = @{ u1 = 'jane@contoso.com' } }
                }
            } else {
                [pscustomobject]@{ Sections = [ordered]@{ roleScopeTags = @([pscustomobject]@{ id = '0'; displayName = 'Default' }) }; Warnings = @(); References = @{ Groups = @{}; Users = @{} } }
            }
        }
        Mock Set-CIPPCloudBackupObject { $script:Store[$Key] = $Body }
        Mock Get-CIPPCloudBackupObject { if ($script:Store.ContainsKey($Key)) { [pscustomobject]@{ Body = $script:Store[$Key]; Metadata = @{} } } }
        Mock Get-CIPPCloudBackupKey { , ([byte[]]$script:Key.Clone()) }
        Mock Write-LogMessage { }
    }

    It 'reads back what a backup run wrote' {
        $RunId = Invoke-Backup

        $Snapshot = Get-CIPPCloudBackupSnapshot -RunId $RunId

        $Snapshot.Run.Id | Should -Be $RunId
        $Snapshot.Run.PolicyId | Should -Be $script:PolicyId
        $Snapshot.Run.TenantId | Should -Be 'c1'
        $Snapshot.Run.Tenant | Should -Be 'contoso.com'
        $Snapshot.Run.Status | Should -Be 'Succeeded'
        $Snapshot.Run.Location | Should -BeLike "$($script:PolicyId)/c1/config/*/"
        @($Snapshot.Run.Areas.Area) | Should -Be @('ConditionalAccess', 'Intune')
        $Snapshot.Manifest.Areas.Count | Should -Be 2
        @($Snapshot.Areas.Keys) | Should -Be @('ConditionalAccess', 'Intune')

        $CA = $Snapshot.Areas['ConditionalAccess']
        $CA.Sections | Should -BeOfType [System.Collections.Specialized.OrderedDictionary]
        @($CA.Sections.Keys) | Should -Be @('policies', 'namedLocations')
        $CA.Sections['policies'].id | Should -Be @('p1', 'p2')
        $CA.Sections['policies'][0].conditions.users.includeGroups | Should -Be @('g1')
        $CA.Sections['namedLocations'].Count | Should -Be 0
        $CA.References.Groups | Should -BeOfType [hashtable]
        $CA.References.Groups['g1'] | Should -Be 'Sales'
        $CA.References.Users['u1'] | Should -Be 'jane@contoso.com'
        $Snapshot.Areas['Intune'].Sections['roleScopeTags'][0].displayName | Should -Be 'Default'
        Should -Invoke Get-CIPPCloudBackupDestination -ParameterFilter { $Id -eq '22222222-2222-2222-2222-222222222222' -and $IncludeSecret }
    }

    It 'decrypts encrypted area files' {
        $script:PolicyRow = New-CloudBackupPolicyRow -Encryption $true -CurrentKeyId $script:KeyId -KeyIds "[`"$($script:KeyId)`"]"
        $RunId = Invoke-Backup
        @($script:Store.Keys).Where({ $_ -like '*.enc' }).Count | Should -Be 2

        $Snapshot = Get-CIPPCloudBackupSnapshot -RunId $RunId

        $Snapshot.Manifest.Encrypted | Should -BeTrue
        $Snapshot.Areas['ConditionalAccess'].Sections['policies'].id | Should -Be @('p1', 'p2')
        Should -Invoke Get-CIPPCloudBackupKey -ParameterFilter { $KeyId -eq $script:KeyId }
    }

    It 'reads only the requested areas' {
        $RunId = Invoke-Backup
        $Snapshot = Get-CIPPCloudBackupSnapshot -RunId $RunId -Area 'Intune'
        @($Snapshot.Areas.Keys) | Should -Be @('Intune')
        Should -Invoke Get-CIPPCloudBackupObject -Times 2 -Exactly
    }

    It 'throws when an area file does not match its checksum' {
        $RunId = Invoke-Backup
        $AreaKey = @($script:Store.Keys).Where({ $_ -like '*ConditionalAccess.json.gz' })[0]
        $Tampered = [byte[]]$script:Store[$AreaKey].Clone()
        $Tampered[20] = $Tampered[20] -bxor 0x01
        $script:Store[$AreaKey] = $Tampered

        { Get-CIPPCloudBackupSnapshot -RunId $RunId } | Should -Throw '*ConditionalAccess*does not match its checksum*'
    }

    It 'returns empty references for a backup made before references were stored' {
        $RunId = Invoke-Backup
        $Prefix = $script:RunWrites[-1].Location
        $Body = ConvertTo-GzipBytes '{"Area":"ConditionalAccess","TenantId":"c1","CapturedAt":"2026-01-01T00:00:00Z","Sections":{"policies":[{"id":"p1"}]}}'
        $script:Store["${Prefix}ConditionalAccess.json.gz"] = $Body
        $Manifest = [ordered]@{ PolicyId = $script:PolicyId; TenantId = 'c1'; Encrypted = $false; Areas = @([ordered]@{ Area = 'ConditionalAccess'; Key = "${Prefix}ConditionalAccess.json.gz"; Sha256 = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($Body)) }) }
        $script:Store["${Prefix}manifest.json"] = [System.Text.Encoding]::UTF8.GetBytes(($Manifest | ConvertTo-Json -Depth 5))

        $Area = (Get-CIPPCloudBackupSnapshot -RunId $RunId).Areas['ConditionalAccess']

        $Area.Sections['policies'][0].id | Should -Be 'p1'
        $Area.References.Groups.Count | Should -Be 0
        $Area.References.Users.Count | Should -Be 0
    }

    It 'throws ItemNotFoundException when <Case>' -TestCases @(
        @{ Case = 'the run does not exist'; Setup = { $script:RunWrites.Clear() }; Message = '*was not found*' }
        @{ Case = 'the manifest is missing'; Setup = { $script:Store.Remove(@($script:Store.Keys).Where({ $_ -like '*manifest.json' })[0]) }; Message = '*manifest*' }
        @{ Case = 'an area file is missing'; Setup = { $script:Store.Remove(@($script:Store.Keys).Where({ $_ -like '*Intune.json.gz' })[0]) }; Message = '*Intune file*' }
        @{ Case = 'the destination is gone'; Setup = { Mock Get-CIPPCloudBackupDestination { } }; Message = '*destination*' }
    ) {
        $RunId = Invoke-Backup
        & $Setup
        $Thrown = $null
        try { Get-CIPPCloudBackupSnapshot -RunId $RunId } catch { $Thrown = $_ }
        $Thrown.Exception | Should -BeOfType ([System.Management.Automation.ItemNotFoundException])
        $Thrown.Exception.Message | Should -BeLike $Message
    }

    It 'reads the destination recorded on the run even when the policy now uses another one' {
        $RunId = Invoke-Backup
        $script:PolicyRow = New-CloudBackupPolicyRow -DestinationId '44444444-4444-4444-4444-444444444444'

        $Snapshot = Get-CIPPCloudBackupSnapshot -RunId $RunId

        $Snapshot.Run.DestinationId | Should -Be '22222222-2222-2222-2222-222222222222'
        $Snapshot.Areas.Count | Should -Be 2
        Should -Invoke Get-CIPPCloudBackupDestination -Times 2 -Exactly -ParameterFilter { $Id -eq '22222222-2222-2222-2222-222222222222' -and $IncludeSecret } -Because 'the backup and the read each use it'
        Should -Invoke Get-CIPPCloudBackupDestination -Times 0 -Exactly -ParameterFilter { $Id -eq '44444444-4444-4444-4444-444444444444' }
    }

    It 'reads a run whose policy was deleted' {
        $RunId = Invoke-Backup
        Mock Get-CIPPAzDataTableEntity { } -ParameterFilter { $TableName -eq 'Config' }

        (Get-CIPPCloudBackupSnapshot -RunId $RunId).Areas['ConditionalAccess'].Sections['policies'].id | Should -Be @('p1', 'p2')
    }

    It 'falls back to the current destination of the policy for a run that did not record one' {
        $RunId = Invoke-Backup
        $script:RunWrites[-1].Remove('DestinationId')
        $script:PolicyRow = New-CloudBackupPolicyRow -DestinationId '44444444-4444-4444-4444-444444444444'

        $Snapshot = Get-CIPPCloudBackupSnapshot -RunId $RunId

        $Snapshot.Run.DestinationId | Should -Be ''
        $Snapshot.Areas.Count | Should -Be 2
        Should -Invoke Get-CIPPCloudBackupDestination -Times 1 -Exactly -ParameterFilter { $Id -eq '44444444-4444-4444-4444-444444444444' -and $IncludeSecret }
    }

    It 'throws ItemNotFoundException for a run that did not record its destination and whose policy was deleted' {
        $RunId = Invoke-Backup
        $script:RunWrites[-1].Remove('DestinationId')
        Mock Get-CIPPAzDataTableEntity { } -ParameterFilter { $TableName -eq 'Config' }

        { Get-CIPPCloudBackupSnapshot -RunId $RunId } | Should -Throw -ExceptionType ([System.Management.Automation.ItemNotFoundException]) -ExpectedMessage '*policy*'
    }

    It 'throws ItemNotFoundException for a run that stored nothing' {
        $script:RunWrites.Add(@{ PartitionKey = $script:PolicyId; RowKey = '0000000000000000001_c1'; PolicyId = $script:PolicyId; TenantId = 'c1'; Status = 'Failed'; Location = '' })
        { Get-CIPPCloudBackupSnapshot -RunId "$($script:PolicyId)_0000000000000000001_c1" } | Should -Throw -ExceptionType ([System.Management.Automation.ItemNotFoundException])
    }

    It 'rejects a malformed run id: <RunId>' -TestCases @(
        @{ RunId = 'nope' }
        @{ RunId = '11111111-1111-1111-1111-111111111111_abc' }
        @{ RunId = "11111111-1111-1111-1111-111111111111_0000000000000000001_c1' or true" }
        @{ RunId = 'zzzzzzzz-1111-1111-1111-111111111111_0000000000000000001_c1' }
    ) {
        { Get-CIPPCloudBackupSnapshot -RunId $RunId } | Should -Throw -ExceptionType ([System.ArgumentException])
        Should -Invoke Get-CIPPAzDataTableEntity -Times 0 -Exactly
    }
}
