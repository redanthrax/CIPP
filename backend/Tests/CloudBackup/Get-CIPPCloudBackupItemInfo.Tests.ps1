BeforeAll {
    $Folder = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))) 'Modules/CIPPCore/Public/CloudBackup'
    . (Join-Path $Folder 'Get-CIPPCloudBackupSectionLabel.ps1')
    . (Join-Path $Folder 'Get-CIPPCloudBackupItemInfo.ps1')
}

Describe 'Get-CIPPCloudBackupSectionLabel' {
    It 'returns the plain-English label of <Section>' -TestCases @(
        @{ Section = 'policies'; Label = 'Conditional Access policies' }
        @{ Section = 'configurationPolicies'; Label = 'Intune settings catalog policies' }
        @{ Section = 'MailboxPermissions'; Label = 'Exchange mailbox permissions' }
        @{ Section = 'sites'; Label = 'SharePoint sites' }
    ) {
        Get-CIPPCloudBackupSectionLabel -Section $Section | Should -Be $Label
    }

    It 'returns the section name when it has no label' {
        Get-CIPPCloudBackupSectionLabel -Section 'somethingNew' | Should -Be 'somethingNew'
    }
}

Describe 'Get-CIPPCloudBackupItemInfo' {
    It 'keys Graph items by id and names them by displayName, then name' {
        $Info = @(Get-CIPPCloudBackupItemInfo -Section 'configurationPolicies' -Item @(
                [pscustomobject]@{ id = 'a'; displayName = 'Display'; name = 'Other' }
                [pscustomobject]@{ id = 'b'; name = 'Settings catalog name' }
                [pscustomobject]@{ id = 'c' }
            ))
        $Info.Key | Should -Be @('a', 'b', 'c')
        $Info.Name | Should -Be @('Display', 'Settings catalog name', 'c')
    }

    It 'returns one result for a single item' {
        $Info = Get-CIPPCloudBackupItemInfo -Section 'policies' -Item ([pscustomobject]@{ id = 'p1'; displayName = 'Block legacy' })
        $Info.Key | Should -Be 'p1'
        $Info.Name | Should -Be 'Block legacy'
    }

    It 'keys Exchange items by Guid, then ExchangeObjectId, Identity and Name' {
        $Info = @(Get-CIPPCloudBackupItemInfo -Section 'TransportRules' -Item @(
                [pscustomobject]@{ Guid = 'g1'; ExchangeObjectId = 'e1'; Identity = 'Rule'; Name = 'Rule'; DisplayName = 'Rule display' }
                [pscustomobject]@{ ExchangeObjectId = 'e2'; Identity = 'Rule 2'; Name = 'Rule 2' }
                [pscustomobject]@{ Identity = 'Rule 3' }
                [pscustomobject]@{ Name = 'Rule 4' }
            ))
        $Info.Key | Should -Be @('g1', 'e2', 'Rule 3', 'Rule 4')
        $Info.Name | Should -Be @('Rule display', 'Rule 2', 'Rule 3', 'Rule 4')
    }

    It 'does not key Exchange items by an Id property' {
        (Get-CIPPCloudBackupItemInfo -Section 'Mailboxes' -Item ([pscustomobject]@{ Id = 'x'; Guid = 'mbx'; DisplayName = 'Jane' })).Key | Should -Be 'mbx'
    }

    It 'keys the organization config by its section' {
        $Info = Get-CIPPCloudBackupItemInfo -Section 'OrganizationConfig' -Item ([pscustomobject]@{ Guid = 'g'; Name = 'contoso.onmicrosoft.com' })
        $Info.Key | Should -Be 'OrganizationConfig'
        $Info.Name | Should -Be 'contoso.onmicrosoft.com'
    }

    It 'keys mailbox permissions by mailbox, user and rights' {
        $Info = Get-CIPPCloudBackupItemInfo -Section 'MailboxPermissions' -Item ([pscustomobject]@{ Identity = 'jane'; User = 'bob@contoso.com'; AccessRights = @('FullAccess', 'ReadPermission') })
        $Info.Key | Should -Be 'jane|bob@contoso.com|FullAccess,ReadPermission'
        $Info.Name | Should -Be 'bob@contoso.com: FullAccess,ReadPermission on jane'
    }

    It 'keys recipient permissions by recipient, trustee and rights' {
        $Info = Get-CIPPCloudBackupItemInfo -Section 'RecipientPermissions' -Item ([pscustomobject]@{ Identity = 'sales'; Trustee = 'bob@contoso.com'; AccessRights = @('SendAs') })
        $Info.Key | Should -Be 'sales|bob@contoso.com|SendAs'
    }

    It 'keys SharePoint tenant settings by section and sites by Url' {
        $Settings = Get-CIPPCloudBackupItemInfo -Section 'spoTenantSettings' -Item ([pscustomobject]@{ SharingCapability = 1 })
        $Settings.Key | Should -Be 'spoTenantSettings'
        $Settings.Name | Should -Be 'SharePoint sharing settings'
        $Sites = @(Get-CIPPCloudBackupItemInfo -Section 'sites' -Item @(
                [pscustomobject]@{ Url = 'https://contoso.sharepoint.com/sites/a'; Title = 'A' }
                [pscustomobject]@{ id = 'site-2' }
            ))
        $Sites.Key | Should -Be @('https://contoso.sharepoint.com/sites/a', 'site-2')
        $Sites.Name | Should -Be @('A', 'site-2')
    }

    It 'returns nothing for no items and skips null items' {
        @(Get-CIPPCloudBackupItemInfo -Section 'policies' -Item @()).Count | Should -Be 0
        @(Get-CIPPCloudBackupItemInfo -Section 'policies' -Item @($null, [pscustomobject]@{ id = 'p' })).Key | Should -Be @('p')
    }
}
