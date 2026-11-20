function Get-CIPPCloudBackupItemInfo {
    <#
    .SYNOPSIS
        The key and display name of Cloud Backup items: one { Key; Name } per item, in order
    .DESCRIPTION
        Pass every item of a section in one call; the key identifies an item within its section across backups.
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Section,
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Item
    )

    $ExchangeSections = @(
        'TransportRules', 'InboundConnectors', 'OutboundConnectors', 'AcceptedDomains', 'RemoteDomains',
        'HostedContentFilterPolicy', 'HostedContentFilterRule', 'HostedOutboundSpamFilterPolicy', 'HostedOutboundSpamFilterRule',
        'AntiPhishPolicy', 'AntiPhishRule', 'MalwareFilterPolicy', 'MalwareFilterRule', 'SafeLinksPolicy', 'SafeLinksRule',
        'SafeAttachmentPolicy', 'SafeAttachmentRule', 'DistributionGroups', 'DynamicDistributionGroups', 'Mailboxes'
    )
    $Kind = switch ($Section) {
        'OrganizationConfig' { 'Single' }
        'tenantSettings' { 'Single' }
        'spoTenantSettings' { 'Single' }
        'MailboxPermissions' { 'MailboxPermission' }
        'RecipientPermissions' { 'RecipientPermission' }
        'sites' { 'Site' }
        default { if ($Section -in $ExchangeSections) { 'Exchange' } else { 'Graph' } }
    }
    $SingleName = if ($Section -in 'tenantSettings', 'spoTenantSettings') { Get-CIPPCloudBackupSectionLabel -Section $Section }

    foreach ($Entry in $Item) {
        if ($null -eq $Entry) { continue }
        switch ($Kind) {
            'Graph' {
                $Key = [string]$Entry.id
                $Name = if ($Entry.displayName) { [string]$Entry.displayName } elseif ($Entry.name) { [string]$Entry.name } else { $Key }
            }
            'Exchange' {
                $Key = if ($Entry.Guid) { [string]$Entry.Guid } elseif ($Entry.ExchangeObjectId) { [string]$Entry.ExchangeObjectId } elseif ($Entry.Identity) { [string]$Entry.Identity } else { [string]$Entry.Name }
                $Name = if ($Entry.DisplayName) { [string]$Entry.DisplayName } elseif ($Entry.Name) { [string]$Entry.Name } elseif ($Entry.Identity) { [string]$Entry.Identity } else { $Key }
            }
            'Single' {
                $Key = $Section
                $Name = $SingleName ?? $(if ($Entry.DisplayName) { [string]$Entry.DisplayName } elseif ($Entry.Name) { [string]$Entry.Name } elseif ($Entry.Identity) { [string]$Entry.Identity } else { $Key })
            }
            'MailboxPermission' {
                $Rights = @($Entry.AccessRights) -join ','
                $Key = "$($Entry.Identity)|$($Entry.User)|$Rights"
                $Name = "$($Entry.User): $Rights on $($Entry.Identity)"
            }
            'RecipientPermission' {
                $Rights = @($Entry.AccessRights) -join ','
                $Key = "$($Entry.Identity)|$($Entry.Trustee)|$Rights"
                $Name = "$($Entry.Trustee): $Rights on $($Entry.Identity)"
            }
            'Site' {
                $Key = if ($Entry.Url) { [string]$Entry.Url } else { [string]$Entry.id }
                $Name = if ($Entry.Title) { [string]$Entry.Title } else { $Key }
            }
        }
        [pscustomobject]@{ Key = $Key; Name = $Name }
    }
}
