function Get-CIPPCloudBackupSectionLabel {
    <#
    .SYNOPSIS
        Plain-English label of a Cloud Backup section, or the section name when it has none
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Section
    )

    $Labels = @{
        policies                             = 'Conditional Access policies'
        namedLocations                       = 'Conditional Access named locations'
        authenticationStrengthPolicies       = 'Conditional Access authentication strengths'
        authenticationContextClassReferences = 'Conditional Access authentication contexts'
        deviceConfigurations                 = 'Intune configuration profiles'
        configurationPolicies                = 'Intune settings catalog policies'
        groupPolicyConfigurations            = 'Intune administrative templates'
        deviceCompliancePolicies             = 'Intune compliance policies'
        managedAppPolicies                   = 'Intune app protection policies'
        mobileAppConfigurations              = 'Intune app configuration policies'
        intents                              = 'Intune endpoint security policies'
        windowsFeatureUpdateProfiles         = 'Intune feature update profiles'
        windowsQualityUpdatePolicies         = 'Intune quality update policies'
        windowsQualityUpdateProfiles         = 'Intune expedited quality update profiles'
        windowsDriverUpdateProfiles          = 'Intune driver update profiles'
        deviceManagementScripts              = 'Intune Windows scripts'
        deviceShellScripts                   = 'Intune macOS scripts'
        deviceHealthScripts                  = 'Intune remediations'
        assignmentFilters                    = 'Intune assignment filters'
        roleScopeTags                        = 'Intune scope tags'
        OrganizationConfig                   = 'Exchange organization settings'
        TransportRules                       = 'Exchange mail flow rules'
        InboundConnectors                    = 'Exchange inbound connectors'
        OutboundConnectors                   = 'Exchange outbound connectors'
        AcceptedDomains                      = 'Exchange accepted domains'
        RemoteDomains                        = 'Exchange remote domains'
        HostedContentFilterPolicy            = 'Exchange anti-spam policies'
        HostedContentFilterRule              = 'Exchange anti-spam rules'
        HostedOutboundSpamFilterPolicy       = 'Exchange outbound spam policies'
        HostedOutboundSpamFilterRule         = 'Exchange outbound spam rules'
        AntiPhishPolicy                      = 'Exchange anti-phishing policies'
        AntiPhishRule                        = 'Exchange anti-phishing rules'
        MalwareFilterPolicy                  = 'Exchange anti-malware policies'
        MalwareFilterRule                    = 'Exchange anti-malware rules'
        SafeLinksPolicy                      = 'Exchange Safe Links policies'
        SafeLinksRule                        = 'Exchange Safe Links rules'
        SafeAttachmentPolicy                 = 'Exchange Safe Attachments policies'
        SafeAttachmentRule                   = 'Exchange Safe Attachments rules'
        RecipientPermissions                 = 'Exchange Send As permissions'
        DistributionGroups                   = 'Exchange distribution lists'
        DynamicDistributionGroups            = 'Exchange dynamic distribution lists'
        Mailboxes                            = 'Exchange mailboxes'
        MailboxPermissions                   = 'Exchange mailbox permissions'
        tenantSettings                       = 'SharePoint tenant settings'
        spoTenantSettings                    = 'SharePoint sharing settings'
        sites                                = 'SharePoint sites'
    }
    $Labels[$Section] ?? $Section
}
