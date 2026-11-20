BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'Fixtures/CloudBackup/CloudBackupTestStubs.ps1')

    $script:PolicyId = '11111111-1111-1111-1111-111111111111'
    $script:DestId = '22222222-2222-2222-2222-222222222222'
    function New-PolicyBody {
        param([hashtable]$Overrides = @{})
        $Body = @{
            Action         = 'Add'
            Name           = 'Nightly'
            Enabled        = $true
            DestinationId  = @{ label = 'Blob'; value = $script:DestId }
            Tenants        = @(
                [pscustomobject]@{ label = 'Contoso (contoso.com)'; value = 'contoso.com'; type = 'Tenant'; addedFields = [pscustomobject]@{ customerId = 'c1'; defaultDomainName = 'contoso.com'; displayName = 'Contoso' } }
                [pscustomobject]@{ label = 'Fabrikam (fabrikam.com)'; value = 'fabrikam.com'; type = 'Tenant' }
            )
            ConfigAreas    = @(@{ label = 'Conditional Access'; value = 'ConditionalAccess' }, 'Intune')
            ConfigSchedule = @{ label = 'Daily'; value = '1d' }
            RetentionDays  = 30
            Encryption     = $false
        }
        foreach ($Key in $Overrides.Keys) { $Body[$Key] = $Overrides[$Key] }
        $Body
    }
    function Invoke-Policy { param($Body) Invoke-ExecCloudBackupPolicy -Request (New-CloudBackupRequest -Endpoint 'ExecCloudBackupPolicy' -Body $Body) }
}

Describe 'Invoke-ExecCloudBackupPolicy' {
    BeforeEach {
        $script:Allowed = @('AllTenants')
        $script:PolicyRows = @()
        $script:Writes = [System.Collections.Generic.List[object]]::new()
        $script:Order = [System.Collections.Generic.List[string]]::new()
        Mock Test-CIPPAccess { $script:Allowed }
        Mock Get-Tenants { $script:CloudBackupTenants }
        Mock Get-CIPPAzDataTableEntity { $script:PolicyRows } -ParameterFilter { $TableName -eq 'Config' }
        Mock Add-CIPPAzDataTableEntity { $script:Writes.Add([pscustomobject]@{ Entity = $Entity; OperationType = $OperationType }); $script:Order.Add('save') }
        Mock Remove-CIPPAzDataTableEntity { }
        Mock Get-CIPPCloudBackupDestination { [pscustomobject]@{ RowKey = $Id; Name = 'Blob'; Provider = 'AzureBlob' } }
        Mock Set-CIPPCloudBackupRetentionRule { $script:Order.Add('rule') }
        Mock Remove-CIPPCloudBackupRetentionRule { }
        Mock New-CIPPCloudBackupKey { 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' }
        Mock Write-LogMessage { }
    }

    It 'returns 400 for <Case>' -ForEach @(
        @{ Case = 'an unknown action'; Overrides = @{ Action = 'Nope' } }
        @{ Case = 'Edit without an id'; Overrides = @{ Action = 'Edit' } }
        @{ Case = 'a missing name'; Overrides = @{ Name = ' ' } }
        @{ Case = 'a missing destination'; Overrides = @{ DestinationId = $null } }
        @{ Case = 'no tenants'; Overrides = @{ Tenants = @() } }
        @{ Case = 'no areas'; Overrides = @{ ConfigAreas = @() } }
        @{ Case = 'an unknown area'; Overrides = @{ ConfigAreas = @('Teams') } }
        @{ Case = 'an unknown schedule'; Overrides = @{ ConfigSchedule = '2h' } }
        @{ Case = 'retention below 7 days'; Overrides = @{ RetentionDays = 6 } }
        @{ Case = 'retention above 3650 days'; Overrides = @{ RetentionDays = 3651 } }
        @{ Case = 'retention that is not a number'; Overrides = @{ RetentionDays = 'abc' } }
    ) {
        (Invoke-Policy -Body (New-PolicyBody -Overrides $Overrides)).StatusCode | Should -Be 400
        Should -Invoke Add-CIPPAzDataTableEntity -Times 0 -Exactly
        Should -Invoke Set-CIPPCloudBackupRetentionRule -Times 0 -Exactly
    }

    It 'returns 400 when the destination does not exist' {
        Mock Get-CIPPCloudBackupDestination { }

        (Invoke-Policy -Body (New-PolicyBody)).StatusCode | Should -Be 400
        Should -Invoke Add-CIPPAzDataTableEntity -Times 0 -Exactly
    }

    It 'adds a policy: sets the retention rule first, stores customerIds and sets the next run to now' {
        $Response = Invoke-Policy -Body (New-PolicyBody)

        $Response.StatusCode | Should -Be 200
        @($script:Order) | Should -Be @('rule', 'save')
        $Saved = $script:Writes[0].Entity
        Should -Invoke Set-CIPPCloudBackupRetentionRule -Times 1 -Exactly -ParameterFilter { $RuleName -eq "cipp-$($Saved.RowKey)" -and $Prefix -eq "$($Saved.RowKey)/" -and $Days -eq 30 }
        $Saved.PartitionKey | Should -Be 'CloudBackupPolicy'
        $Saved.DestinationId | Should -Be $script:DestId
        $Tenants = $Saved.Tenants | ConvertFrom-Json
        @($Tenants.type) | Should -Be @('Tenant', 'Tenant')
        @($Tenants.customerId) | Should -Be @('c1', 'c2')
        @($Saved.ConfigAreas | ConvertFrom-Json) | Should -Be @('ConditionalAccess', 'Intune')
        $Saved.ConfigSchedule | Should -Be '1d'
        $Saved.RetentionDays | Should -Be 30
        ([datetimeoffset]::Parse($Saved.ConfigNextRun).UtcDateTime - [datetime]::UtcNow).Duration().TotalMinutes | Should -BeLessThan 1
        $Saved.CurrentKeyId | Should -Be ''
        Should -Invoke New-CIPPCloudBackupKey -Times 0 -Exactly
    }

    It 'stores All Tenants and tenant groups from the selector' {
        $Body = New-PolicyBody -Overrides @{ Tenants = @(
                [pscustomobject]@{ label = '*All Tenants (AllTenants)'; value = 'AllTenants'; type = 'Tenant'; addedFields = [pscustomobject]@{ defaultDomainName = 'AllTenants'; displayName = '*All Tenants'; customerId = 'AllTenants' } }
                [pscustomobject]@{ label = 'EU customers'; value = 'g1'; type = 'Group' }
            )
        }

        (Invoke-Policy -Body $Body).StatusCode | Should -Be 200

        $Saved = $script:Writes[0].Entity.Tenants
        $Saved | Should -Be '[{"type":"AllTenants"},{"type":"Group","id":"g1"}]'
    }

    It 'returns 400 for a tenant that cannot be resolved' {
        $Body = New-PolicyBody -Overrides @{ Tenants = @([pscustomobject]@{ label = 'Gone'; value = 'gone.com'; type = 'Tenant' }) }

        (Invoke-Policy -Body $Body).StatusCode | Should -Be 400
        Should -Invoke Add-CIPPAzDataTableEntity -Times 0 -Exactly
    }

    It 'does not save when the retention rule cannot be set, and returns its status' -ForEach @(
        @{ Error = { throw 'AuthorizationFailed' }; Expected = 500 }
        @{ Error = { throw [System.Management.Automation.ItemNotFoundException]::new('NoSuchBucket') }; Expected = 404 }
        @{ Error = { throw [System.ArgumentException]::new('bad config') }; Expected = 400 }
    ) {
        Mock Set-CIPPCloudBackupRetentionRule $Error

        $Response = Invoke-Policy -Body (New-PolicyBody)

        $Response.StatusCode | Should -Be $Expected
        "$($Response.Body.Results)" | Should -BeLike 'Policy not saved*'
        Should -Invoke Add-CIPPAzDataTableEntity -Times 0 -Exactly
    }

    It 'creates a key when encryption is turned on without one' {
        (Invoke-Policy -Body (New-PolicyBody -Overrides @{ Encryption = $true })).StatusCode | Should -Be 200

        $Saved = $script:Writes[0].Entity
        $Saved.Encryption | Should -BeTrue
        $Saved.CurrentKeyId | Should -Be 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        @($Saved.KeyIds | ConvertFrom-Json) | Should -Be @('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')
    }

    It 'keeps the existing key and next run on Edit, and moves the rule when the destination changes' {
        $script:PolicyRows = @(New-CloudBackupPolicyRow -Encryption $true -CurrentKeyId 'k1' -KeyIds '["k1"]' -ConfigNextRun '2026-12-01T00:00:00.0000000Z')
        $NewDest = '77777777-7777-7777-7777-777777777777'

        $Response = Invoke-Policy -Body (New-PolicyBody -Overrides @{ Action = 'Edit'; Id = $script:PolicyId; Encryption = $true; DestinationId = $NewDest })

        $Response.StatusCode | Should -Be 200
        $Saved = $script:Writes[0].Entity
        $Saved.RowKey | Should -Be $script:PolicyId
        $Saved.CurrentKeyId | Should -Be 'k1'
        $Saved.ConfigNextRun | Should -Be '2026-12-01T00:00:00.0000000Z'
        Should -Invoke New-CIPPCloudBackupKey -Times 0 -Exactly
        Should -Invoke Remove-CIPPCloudBackupRetentionRule -Times 1 -Exactly -ParameterFilter { $Destination.RowKey -eq $script:DestId -and $RuleName -eq "cipp-$($script:PolicyId)" }
    }

    It 'returns 404 when editing a policy that does not exist' {
        (Invoke-Policy -Body (New-PolicyBody -Overrides @{ Action = 'Edit'; Id = $script:PolicyId })).StatusCode | Should -Be 404
    }

    Context 'restricted caller' {
        BeforeEach { $script:Allowed = @('c1') }

        It 'returns 403 for a target outside their tenants: <Case>' -ForEach @(
            @{ Case = 'All Tenants'; Tenants = @([pscustomobject]@{ value = 'AllTenants'; type = 'Tenant' }) }
            @{ Case = 'a tenant group'; Tenants = @([pscustomobject]@{ value = 'g1'; type = 'Group' }) }
            @{ Case = 'another tenant'; Tenants = @([pscustomobject]@{ value = 'fabrikam.com'; type = 'Tenant' }) }
        ) {
            (Invoke-Policy -Body (New-PolicyBody -Overrides @{ Tenants = $Tenants })).StatusCode | Should -Be 403
            Should -Invoke Set-CIPPCloudBackupRetentionRule -Times 0 -Exactly
            Should -Invoke Add-CIPPAzDataTableEntity -Times 0 -Exactly
        }

        It 'saves a policy for their own tenant' {
            $Body = New-PolicyBody -Overrides @{ Tenants = @([pscustomobject]@{ value = 'contoso.com'; type = 'Tenant' }) }
            (Invoke-Policy -Body $Body).StatusCode | Should -Be 200
        }

        It 'returns 403 when editing, deleting or rotating a policy that reaches other tenants' -ForEach @(
            @{ Action = 'Edit' }, @{ Action = 'Delete' }, @{ Action = 'RotateKey' }
        ) {
            $script:PolicyRows = @(New-CloudBackupPolicyRow -Tenants '[{"type":"AllTenants"}]' -Encryption $true)
            $Body = New-PolicyBody -Overrides @{ Action = $Action; Id = $script:PolicyId; Tenants = @([pscustomobject]@{ value = 'contoso.com'; type = 'Tenant' }) }

            (Invoke-Policy -Body $Body).StatusCode | Should -Be 403
            Should -Invoke Add-CIPPAzDataTableEntity -Times 0 -Exactly
            Should -Invoke Remove-CIPPAzDataTableEntity -Times 0 -Exactly
        }
    }

    It 'deletes the policy and removes its retention rule' {
        $script:PolicyRows = @(New-CloudBackupPolicyRow)

        $Response = Invoke-Policy -Body @{ Action = 'Delete'; Id = $script:PolicyId }

        $Response.StatusCode | Should -Be 200
        Should -Invoke Remove-CIPPCloudBackupRetentionRule -Times 1 -Exactly -ParameterFilter { $RuleName -eq "cipp-$($script:PolicyId)" }
        Should -Invoke Remove-CIPPAzDataTableEntity -Times 1 -Exactly -ParameterFilter { $Entity.RowKey -eq $script:PolicyId -and $Entity.PartitionKey -eq 'CloudBackupPolicy' }
    }

    It 'still deletes the policy when the retention rule cannot be removed' {
        $script:PolicyRows = @(New-CloudBackupPolicyRow)
        Mock Remove-CIPPCloudBackupRetentionRule { throw 'denied' }

        (Invoke-Policy -Body @{ Action = 'Delete'; Id = $script:PolicyId }).StatusCode | Should -Be 200
        Should -Invoke Remove-CIPPAzDataTableEntity -Times 1 -Exactly
        Should -Invoke Write-LogMessage -ParameterFilter { $sev -eq 'Warning' }
    }

    It 'rotates the key: appends it to KeyIds and makes it current' {
        $script:PolicyRows = @(New-CloudBackupPolicyRow -Encryption $true -CurrentKeyId 'k1' -KeyIds '["k1"]')

        $Response = Invoke-Policy -Body @{ Action = 'RotateKey'; Id = $script:PolicyId }

        $Response.StatusCode | Should -Be 200
        $Write = $script:Writes[0]
        $Write.OperationType | Should -Be 'UpsertMerge'
        $Write.Entity.CurrentKeyId | Should -Be 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        @($Write.Entity.KeyIds | ConvertFrom-Json) | Should -Be @('k1', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')
    }

    It 'refuses to rotate the key of a policy without encryption' {
        $script:PolicyRows = @(New-CloudBackupPolicyRow)

        (Invoke-Policy -Body @{ Action = 'RotateKey'; Id = $script:PolicyId }).StatusCode | Should -Be 400
        Should -Invoke New-CIPPCloudBackupKey -Times 0 -Exactly
    }
}
