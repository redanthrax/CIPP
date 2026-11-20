function Restore-CIPPCloudBackupExchange {
    <#
    .SYNOPSIS
        Restores Exchange configuration from a Cloud Backup snapshot
    .DESCRIPTION
        Plans every selected item against the target tenant's live configuration and writes it only with -Apply.
        Mailbox settings and permissions restore only to the source tenant. Permissions and group members are only
        added, never removed. Default policies are only updated.
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Snapshot,
        [Parameter(Mandatory = $true)]
        [string]$SourceTenantId,
        [Parameter(Mandatory = $true)]
        [string]$TargetTenantFilter,
        [object[]]$Items,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Skip', 'Overwrite', 'Copy')]
        [string]$ConflictAction,
        [switch]$Apply
    )

    # Parameter lists follow the Exchange Online cmdlet reference: https://learn.microsoft.com/powershell/module/exchangepowershell/
    $CustomAttributes = @(foreach ($i in 1..15) { "CustomAttribute$i" }) + @(foreach ($i in 1..5) { "ExtensionCustomAttribute$i" })
    $RecipientRuleParams = @('Comments', 'ExceptIfRecipientDomainIs', 'ExceptIfSentTo', 'ExceptIfSentToMemberOf', 'RecipientDomainIs', 'SentTo', 'SentToMemberOf')
    $Specs = @{
        OrganizationConfig             = @{ Kind = 'Singleton'; Noun = 'OrganizationConfig'; SameTenantParams = @('DefaultAuthenticationPolicy'); Params = @(
                'ActionableMessagesExtenalAccessTokenEnabled', 'ActivityBasedAuthenticationTimeoutEnabled', 'ActivityBasedAuthenticationTimeoutInterval',
                'ActivityBasedAuthenticationTimeoutWithSingleSignOnEnabled', 'AppsForOfficeEnabled', 'AsyncSendEnabled', 'AuditDisabled',
                'AutoArchivingThresholdPercentage', 'AutodiscoverPartialDirSync', 'AutoEnableArchiveMailbox', 'AutomaticForcedReadReceiptEnabled',
                'BlockMoveMessagesForGroupFolders', 'BookingsAddressEntryRestricted', 'BookingsAuthEnabled', 'BookingsBlockedWordsEnabled',
                'BookingsCreationOfCustomQuestionsRestricted', 'BookingsEnabled', 'BookingsExposureOfStaffDetailsRestricted', 'BookingsMembershipApprovalRequired',
                'BookingsNamingPolicyEnabled', 'BookingsNamingPolicyPrefix', 'BookingsNamingPolicyPrefixEnabled', 'BookingsNamingPolicySuffix',
                'BookingsNamingPolicySuffixEnabled', 'BookingsNotesEntryRestricted', 'BookingsPaymentsEnabled', 'BookingsPhoneNumberEntryRestricted',
                'BookingsSearchEngineIndexDisabled', 'BookingsSmsMicrosoftEnabled', 'BookingsSocialSharingRestricted', 'ByteEncoderTypeFor7BitCharsets',
                'ComplianceMLBgdCrawlEnabled', 'ConnectorsActionableMessagesEnabled', 'ConnectorsEnabled', 'ConnectorsEnabledForOutlook',
                'ConnectorsEnabledForSharepoint', 'ConnectorsEnabledForTeams', 'ConnectorsEnabledForYammer', 'DefaultAuthenticationPolicy',
                'DefaultFolderPermissionRestricted', 'DefaultGroupAccessType', 'DefaultPublicFolderAgeLimit', 'DefaultPublicFolderDeletedItemRetention',
                'DefaultPublicFolderIssueWarningQuota', 'DefaultPublicFolderMaxItemSize', 'DefaultPublicFolderMovedItemRetention', 'DefaultPublicFolderProhibitPostQuota',
                'DirectReportsGroupAutoCreationEnabled', 'DisablePlusAddressInRecipients', 'DistributionGroupNameBlockedWordsList', 'DistributionGroupNamingPolicy',
                'DLPViaDcsEnabled', 'DLPWaitOnSendEnabled', 'DLPWaitOnSendTimeout', 'ElcProcessingDisabled', 'EnableOutlookEvents', 'EndUserDLUpgradeFlowsDisabled',
                'EnforceExoAppRbacPermissions', 'EwsAllowEntourage', 'EwsAllowList', 'EwsAllowMacOutlook', 'EwsAllowOutlook', 'EwsAllowedAppIDs',
                'EwsApplicationAccessPolicy', 'EwsBlockList', 'EwsEnabled', 'ExchangeNotificationEnabled', 'ExchangeNotificationRecipients',
                'FindTimeAttendeeAuthenticationEnabled', 'FindTimeAutoScheduleDisabled', 'FindTimeLockPollForAttendeesEnabled', 'FindTimeOnlineMeetingOptionDisabled',
                'FocusedInboxOn', 'HybridRSVPEnabled', 'InRegionRoutingEnabled', 'IPListBlocked', 'IsAgendaMailEnabled', 'IsGroupFoldersAndRulesEnabled',
                'IsGroupMemberAllowedToEditContent', 'LeanPopoutEnabled', 'LinkPreviewEnabled', 'MailTipsAllTipsEnabled', 'MailTipsExternalRecipientsTipsEnabled',
                'MailTipsGroupMetricsEnabled', 'MailTipsLargeAudienceThreshold', 'MailTipsMailboxSourcedTipsEnabled', 'MaskClientIpInReceivedHeadersEnabled',
                'MatchSenderOrganizerProperties', 'MessageHighlightsEnabled', 'MessageRecallEnabled', 'MessageRemindersEnabled', 'MobileAppEducationEnabled',
                'OAuth2ClientProfileEnabled', 'OnlineMeetingsByDefaultEnabled', 'OutlookGifPickerDisabled', 'OutlookMobileGCCRestrictionsEnabled',
                'OutlookMobileHelpShiftEnabled', 'OutlookMobileSingleAccountEnabled', 'OutlookPayEnabled', 'OutlookTextPredictionDisabled',
                'PostponeRoamingSignaturesUntilLater', 'PreferredInternetCodePageForShiftJis', 'PublicComputersDetectionEnabled', 'PublicFoldersEnabled',
                'PublicFolderShowClientControl', 'ReadTrackingEnabled', 'RefreshSessionEnabled', 'RecipientDelimiters', 'RejectDirectSend', 'RequiredCharsetCoverage',
                'SendFromAliasEnabled', 'SharedDomainEmailAddressFlowEnabled', 'SmtpActionableMessagesEnabled', 'TwoClickMailPreviewEnabled',
                'UnblockUnsafeSenderPromptEnabled', 'VisibleMeetingUpdateProperties', 'WebPushNotificationsDisabled', 'WebSuggestedRepliesDisabled', 'WorkspaceTenantEnabled')
        }
        TransportRules                 = @{ Kind = 'Rule'; Noun = 'TransportRule'; Params = @(
                'ActivationDate', 'ADComparisonAttribute', 'ADComparisonOperator', 'AddManagerAsRecipientType', 'AddToRecipients', 'AnyOfCcHeader', 'AnyOfCcHeaderMemberOf',
                'AnyOfRecipientAddressContainsWords', 'AnyOfRecipientAddressMatchesPatterns', 'AnyOfToCcHeader', 'AnyOfToCcHeaderMemberOf', 'AnyOfToHeader',
                'AnyOfToHeaderMemberOf', 'ApplyClassification', 'ApplyHtmlDisclaimerFallbackAction', 'ApplyHtmlDisclaimerLocation', 'ApplyHtmlDisclaimerText', 'ApplyOME',
                'ApplyRightsProtectionCustomizationTemplate', 'ApplyRightsProtectionTemplate', 'AttachmentContainsWords', 'AttachmentExtensionMatchesWords',
                'AttachmentHasExecutableContent', 'AttachmentIsPasswordProtected', 'AttachmentIsUnsupported', 'AttachmentMatchesPatterns', 'AttachmentNameMatchesPatterns',
                'AttachmentProcessingLimitExceeded', 'AttachmentPropertyContainsWords', 'AttachmentSizeOver', 'BetweenMemberOf1', 'BetweenMemberOf2', 'BlindCopyTo',
                'Comments', 'ContentCharacterSetContainsWords', 'CopyTo', 'DeleteMessage', 'ExceptIfADComparisonAttribute', 'ExceptIfADComparisonOperator',
                'ExceptIfAnyOfCcHeader', 'ExceptIfAnyOfCcHeaderMemberOf', 'ExceptIfAnyOfRecipientAddressContainsWords', 'ExceptIfAnyOfRecipientAddressMatchesPatterns',
                'ExceptIfAnyOfToCcHeader', 'ExceptIfAnyOfToCcHeaderMemberOf', 'ExceptIfAnyOfToHeader', 'ExceptIfAnyOfToHeaderMemberOf', 'ExceptIfAttachmentContainsWords',
                'ExceptIfAttachmentExtensionMatchesWords', 'ExceptIfAttachmentHasExecutableContent', 'ExceptIfAttachmentIsPasswordProtected',
                'ExceptIfAttachmentIsUnsupported', 'ExceptIfAttachmentMatchesPatterns', 'ExceptIfAttachmentNameMatchesPatterns', 'ExceptIfAttachmentProcessingLimitExceeded',
                'ExceptIfAttachmentPropertyContainsWords', 'ExceptIfAttachmentSizeOver', 'ExceptIfBetweenMemberOf1', 'ExceptIfBetweenMemberOf2',
                'ExceptIfContentCharacterSetContainsWords', 'ExceptIfFrom', 'ExceptIfFromAddressContainsWords', 'ExceptIfFromAddressMatchesPatterns', 'ExceptIfFromMemberOf',
                'ExceptIfFromScope', 'ExceptIfHasClassification', 'ExceptIfHasNoClassification', 'ExceptIfHeaderContainsMessageHeader', 'ExceptIfHeaderContainsWords',
                'ExceptIfHeaderMatchesMessageHeader', 'ExceptIfHeaderMatchesPatterns', 'ExceptIfManagerAddresses', 'ExceptIfManagerForEvaluatedUser',
                'ExceptIfMessageSizeOver', 'ExceptIfMessageTypeMatches', 'ExceptIfRecipientADAttributeContainsWords', 'ExceptIfRecipientADAttributeMatchesPatterns',
                'ExceptIfRecipientAddressContainsWords', 'ExceptIfRecipientAddressMatchesPatterns', 'ExceptIfRecipientDomainIs', 'ExceptIfSCLOver',
                'ExceptIfSenderADAttributeContainsWords', 'ExceptIfSenderADAttributeMatchesPatterns', 'ExceptIfSenderDomainIs', 'ExceptIfSenderInRecipientList',
                'ExceptIfSenderIpRanges', 'ExceptIfSenderManagementRelationship', 'ExceptIfSentTo', 'ExceptIfSentToMemberOf', 'ExceptIfSentToScope',
                'ExceptIfSubjectContainsWords', 'ExceptIfSubjectMatchesPatterns', 'ExceptIfSubjectOrBodyContainsWords', 'ExceptIfSubjectOrBodyMatchesPatterns',
                'ExceptIfWithImportance', 'ExpiryDate', 'From', 'FromAddressContainsWords', 'FromAddressMatchesPatterns', 'FromMemberOf', 'FromScope',
                'GenerateIncidentReport', 'GenerateNotification', 'HasClassification', 'HasNoClassification', 'HeaderContainsMessageHeader', 'HeaderContainsWords',
                'HeaderMatchesMessageHeader', 'HeaderMatchesPatterns', 'IncidentReportContent', 'IncidentReportOriginalMail', 'LogEventText', 'ManagerAddresses',
                'ManagerForEvaluatedUser', 'MessageSizeOver', 'MessageTypeMatches', 'Mode', 'ModerateMessageByManager', 'ModerateMessageByUser', 'NotifySender',
                'PrependSubject', 'Quarantine', 'RecipientADAttributeContainsWords', 'RecipientADAttributeMatchesPatterns', 'RecipientAddressContainsWords',
                'RecipientAddressMatchesPatterns', 'RecipientAddressType', 'RecipientDomainIs', 'RecipientInSenderList', 'RedirectMessageTo',
                'RejectMessageEnhancedStatusCode', 'RejectMessageReasonText', 'RemoveHeader', 'RemoveOME', 'RemoveOMEv2', 'RemoveRMSAttachmentEncryption',
                'RouteMessageOutboundConnector', 'RouteMessageOutboundRequireTls', 'RuleErrorAction', 'SCLOver', 'SenderADAttributeContainsWords',
                'SenderADAttributeMatchesPatterns', 'SenderAddressLocation', 'SenderDomainIs', 'SenderInRecipientList', 'SenderIpRanges', 'SenderManagementRelationship',
                'SentTo', 'SentToMemberOf', 'SentToScope', 'SetAuditSeverity', 'SetHeaderName', 'SetHeaderValue', 'SetSCL', 'SmtpRejectMessageRejectStatusCode',
                'SmtpRejectMessageRejectText', 'StopRuleProcessing', 'SubjectContainsWords', 'SubjectMatchesPatterns', 'SubjectOrBodyContainsWords',
                'SubjectOrBodyMatchesPatterns', 'WithImportance')
        }
        InboundConnectors              = @{ Kind = 'Object'; Noun = 'InboundConnector'; NewOnlyParams = @('ClientHostNames'); Params = @(
                'AssociatedAcceptedDomains', 'CloudServicesMailEnabled', 'Comment', 'ConnectorSource', 'ConnectorType', 'EFSkipIPs', 'EFSkipLastIP', 'EFUsers', 'Enabled',
                'RequireTls', 'RestrictDomainsToCertificate', 'RestrictDomainsToIPAddresses', 'SenderDomains', 'SenderIPAddresses', 'TlsSenderCertificateName',
                'TreatMessagesAsInternal', 'TrustedOrganizations')
        }
        OutboundConnectors             = @{ Kind = 'Object'; Noun = 'OutboundConnector'; Params = @(
                'AllAcceptedDomains', 'CloudServicesMailEnabled', 'Comment', 'ConnectorSource', 'ConnectorType', 'Enabled', 'IsTransportRuleScoped', 'MtaStsMode',
                'RecipientDomains', 'RouteAllMessagesViaOnPremises', 'SenderRewritingEnabled', 'SmartHosts', 'SmtpDaneMode', 'TestMode', 'TlsDomain', 'TlsSettings', 'UseMXRecord')
        }
        AcceptedDomains                = @{ Kind = 'AcceptedDomain'; Noun = 'AcceptedDomain'; Params = @('DomainType', 'MatchSubDomains', 'OutboundOnly') }
        RemoteDomains                  = @{ Kind = 'RemoteDomain'; Noun = 'RemoteDomain'; Params = @(
                'AllowedOOFType', 'AutoForwardEnabled', 'AutoReplyEnabled', 'ByteEncoderTypeFor7BitCharsets', 'CharacterSet', 'ContentType', 'DeliveryReportEnabled',
                'DisplaySenderName', 'IsInternal', 'LineWrapSize', 'MeetingForwardNotificationEnabled', 'NDREnabled', 'NonMimeCharacterSet',
                'PreferredInternetCodePageForShiftJis', 'RequiredCharsetCoverage', 'TargetDeliveryDomain', 'TNEFEnabled', 'TrustedMailInboundEnabled',
                'TrustedMailOutboundEnabled', 'UseSimpleDisplayName')
        }
        HostedContentFilterPolicy      = @{ Kind = 'Policy'; Noun = 'HostedContentFilterPolicy'; Params = @(
                'AddXHeaderValue', 'AdminDisplayName', 'AllowedSenderDomains', 'AllowedSenders', 'BlockedSenderDomains', 'BlockedSenders', 'BulkMovesEnabled',
                'BulkQuarantineTag', 'BulkSpamAction', 'BulkThreshold', 'EnableLanguageBlockList', 'EnableRegionBlockList', 'HighConfidencePhishAction',
                'HighConfidencePhishQuarantineTag', 'HighConfidenceSpamAction', 'HighConfidenceSpamQuarantineTag', 'IncreaseScoreWithBizOrInfoUrls',
                'IncreaseScoreWithImageLinks', 'IncreaseScoreWithNumericIps', 'IncreaseScoreWithRedirectToOtherPort', 'InlineSafetyTipsEnabled', 'IntraOrgFilterState',
                'LanguageBlockList', 'MarkAsSpamBulkMail', 'MarkAsSpamEmbedTagsInHtml', 'MarkAsSpamEmptyMessages', 'MarkAsSpamFormTagsInHtml', 'MarkAsSpamFramesInHtml',
                'MarkAsSpamFromAddressAuthFail', 'MarkAsSpamJavaScriptInHtml', 'MarkAsSpamNdrBackscatter', 'MarkAsSpamObjectTagsInHtml', 'MarkAsSpamSensitiveWordList',
                'MarkAsSpamSpfRecordHardFail', 'MarkAsSpamWebBugsInHtml', 'ModifySubjectValue', 'PhishQuarantineTag', 'PhishSpamAction', 'PhishZapEnabled',
                'QuarantineRetentionPeriod', 'RedirectToRecipients', 'RegionBlockList', 'SpamAction', 'SpamQuarantineTag', 'SpamZapEnabled', 'TestModeAction',
                'TestModeBccToRecipients')
        }
        HostedContentFilterRule        = @{ Kind = 'Rule'; Noun = 'HostedContentFilterRule'; PolicySection = 'HostedContentFilterPolicy'; Params = $RecipientRuleParams }
        HostedOutboundSpamFilterPolicy = @{ Kind = 'Policy'; Noun = 'HostedOutboundSpamFilterPolicy'; Params = @(
                'ActionWhenThresholdReached', 'AdminDisplayName', 'AutoForwardingMode', 'BccSuspiciousOutboundAdditionalRecipients', 'BccSuspiciousOutboundMail',
                'RecipientLimitExternalPerHour', 'RecipientLimitInternalPerHour', 'RecipientLimitPerDay')
        }
        HostedOutboundSpamFilterRule   = @{ Kind = 'Rule'; Noun = 'HostedOutboundSpamFilterRule'; PolicySection = 'HostedOutboundSpamFilterPolicy'; Params = @(
                'Comments', 'ExceptIfFrom', 'ExceptIfFromMemberOf', 'ExceptIfSenderDomainIs', 'From', 'FromMemberOf', 'SenderDomainIs')
        }
        AntiPhishPolicy                = @{ Kind = 'Policy'; Noun = 'AntiPhishPolicy'; Params = @(
                'AdminDisplayName', 'AuthenticationFailAction', 'DmarcQuarantineAction', 'DmarcRejectAction', 'EnableFirstContactSafetyTips', 'EnableMailboxIntelligence',
                'EnableMailboxIntelligenceProtection', 'EnableOrganizationDomainsProtection', 'EnableSimilarDomainsSafetyTips', 'EnableSimilarUsersSafetyTips',
                'EnableSpoofIntelligence', 'EnableTargetedDomainsProtection', 'EnableTargetedUserProtection', 'EnableUnauthenticatedSender',
                'EnableUnusualCharactersSafetyTips', 'EnableViaTag', 'ExcludedDomains', 'ExcludedSenders', 'HonorDmarcPolicy', 'ImpersonationProtectionState',
                'MailboxIntelligenceProtectionAction', 'MailboxIntelligenceProtectionActionRecipients', 'MailboxIntelligenceQuarantineTag', 'PhishThresholdLevel',
                'SpoofQuarantineTag', 'TargetedDomainActionRecipients', 'TargetedDomainProtectionAction', 'TargetedDomainQuarantineTag', 'TargetedDomainsToProtect',
                'TargetedUserActionRecipients', 'TargetedUserProtectionAction', 'TargetedUserQuarantineTag', 'TargetedUsersToProtect')
        }
        AntiPhishRule                  = @{ Kind = 'Rule'; Noun = 'AntiPhishRule'; PolicySection = 'AntiPhishPolicy'; Params = $RecipientRuleParams }
        MalwareFilterPolicy            = @{ Kind = 'Policy'; Noun = 'MalwareFilterPolicy'; Params = @(
                'AdminDisplayName', 'CustomExternalBody', 'CustomExternalSubject', 'CustomFromAddress', 'CustomFromName', 'CustomInternalBody', 'CustomInternalSubject',
                'CustomNotifications', 'EnableExternalSenderAdminNotifications', 'EnableFileFilter', 'EnableInternalSenderAdminNotifications', 'ExternalSenderAdminAddress',
                'FileTypeAction', 'FileTypes', 'InternalSenderAdminAddress', 'QuarantineTag', 'ZapEnabled')
        }
        MalwareFilterRule              = @{ Kind = 'Rule'; Noun = 'MalwareFilterRule'; PolicySection = 'MalwareFilterPolicy'; Params = $RecipientRuleParams }
        SafeLinksPolicy                = @{ Kind = 'Policy'; Noun = 'SafeLinksPolicy'; Params = @(
                'AdminDisplayName', 'AllowClickThrough', 'CustomNotificationText', 'DeliverMessageAfterScan', 'DisableUrlRewrite', 'DoNotRewriteUrls',
                'EnableForInternalSenders', 'EnableOrganizationBranding', 'EnableSafeLinksForEmail', 'EnableSafeLinksForOffice', 'EnableSafeLinksForTeams', 'ScanUrls',
                'TrackClicks', 'UseTranslatedNotificationText')
        }
        SafeLinksRule                  = @{ Kind = 'Rule'; Noun = 'SafeLinksRule'; PolicySection = 'SafeLinksPolicy'; Params = $RecipientRuleParams }
        SafeAttachmentPolicy           = @{ Kind = 'Policy'; Noun = 'SafeAttachmentPolicy'; Params = @('Action', 'AdminDisplayName', 'Enable', 'QuarantineTag', 'Redirect', 'RedirectAddress') }
        SafeAttachmentRule             = @{ Kind = 'Rule'; Noun = 'SafeAttachmentRule'; PolicySection = 'SafeAttachmentPolicy'; Params = $RecipientRuleParams }
        DistributionGroups             = @{ Kind = 'Group'; Noun = 'DistributionGroup'
            SameTenantParams = @('ManagedBy', 'ModeratedBy', 'BypassModerationFromSendersOrMembers', 'AcceptMessagesOnlyFromSendersOrMembers', 'RejectMessagesFromSendersOrMembers', 'GrantSendOnBehalfTo')
            NewParams        = @('DisplayName', 'ManagedBy', 'MemberJoinRestriction', 'MemberDepartRestriction', 'ModerationEnabled', 'ModeratedBy', 'RequireSenderAuthenticationEnabled',
                'SendModerationNotifications', 'BypassNestedModerationEnabled', 'HiddenGroupMembershipEnabled', 'Description', 'BccBlocked')
            Params           = @('DisplayName', 'Description', 'ManagedBy', 'MemberJoinRestriction', 'MemberDepartRestriction', 'ModerationEnabled', 'ModeratedBy',
                'BypassModerationFromSendersOrMembers', 'AcceptMessagesOnlyFromSendersOrMembers', 'RejectMessagesFromSendersOrMembers', 'GrantSendOnBehalfTo',
                'RequireSenderAuthenticationEnabled', 'HiddenFromAddressListsEnabled', 'MailTip', 'MailTipTranslations', 'ReportToManagerEnabled', 'ReportToOriginatorEnabled',
                'SendOofMessageToOriginatorEnabled', 'SendModerationNotifications', 'BypassNestedModerationEnabled', 'BccBlocked') + $CustomAttributes
        }
        DynamicDistributionGroups      = @{ Kind = 'Group'; Noun = 'DynamicDistributionGroup'
            SameTenantParams = @('ManagedBy', 'ModeratedBy', 'BypassModerationFromSendersOrMembers', 'AcceptMessagesOnlyFromSendersOrMembers', 'RejectMessagesFromSendersOrMembers', 'GrantSendOnBehalfTo')
            NewParams        = @('DisplayName', 'ManagedBy', 'ModerationEnabled', 'ModeratedBy', 'SendModerationNotifications', 'Notes')
            Params           = @('DisplayName', 'ManagedBy', 'ModerationEnabled', 'ModeratedBy', 'BypassModerationFromSendersOrMembers', 'AcceptMessagesOnlyFromSendersOrMembers',
                'RejectMessagesFromSendersOrMembers', 'GrantSendOnBehalfTo', 'RequireSenderAuthenticationEnabled', 'HiddenFromAddressListsEnabled', 'MailTip',
                'MailTipTranslations', 'Notes', 'ReportToManagerEnabled', 'ReportToOriginatorEnabled', 'SendOofMessageToOriginatorEnabled', 'SendModerationNotifications',
                'PhoneticDisplayName', 'SimpleDisplayName') + $CustomAttributes
        }
        Mailboxes                      = @{ Kind = 'Mailbox'; Noun = 'Mailbox'; Params = @(
                'HiddenFromAddressListsEnabled', 'GrantSendOnBehalfTo', 'ForwardingAddress', 'ForwardingSmtpAddress', 'DeliverToMailboxAndForward', 'MessageCopyForSentAsEnabled',
                'MessageCopyForSendOnBehalfEnabled', 'LitigationHoldEnabled', 'LitigationHoldDuration', 'RetentionHoldEnabled', 'RetentionPolicy', 'RetainDeletedItemsFor',
                'SingleItemRecoveryEnabled', 'AuditEnabled', 'AuditOwner', 'AuditDelegate', 'AuditAdmin', 'UseDatabaseQuotaDefaults', 'IssueWarningQuota', 'ProhibitSendQuota',
                'ProhibitSendReceiveQuota', 'MaxSendSize', 'MaxReceiveSize', 'RecipientLimits', 'AcceptMessagesOnlyFromSendersOrMembers', 'RejectMessagesFromSendersOrMembers',
                'RequireSenderAuthenticationEnabled', 'ModerationEnabled', 'ModeratedBy', 'BypassModerationFromSendersOrMembers', 'SendModerationNotifications', 'MailTip',
                'MailTipTranslations', 'ResourceCapacity', 'RoleAssignmentPolicy', 'SharingPolicy', 'AddressBookPolicy', 'CalendarRepairDisabled', 'Office') + $CustomAttributes
        }
        MailboxPermissions             = @{ Kind = 'MailboxPermission' }
        RecipientPermissions           = @{ Kind = 'RecipientPermission' }
    }
    $GetCmdlets = @{
        OrganizationConfig = 'Get-OrganizationConfig'; TransportRules = 'Get-TransportRule'; InboundConnectors = 'Get-InboundConnector'; OutboundConnectors = 'Get-OutboundConnector'
        AcceptedDomains = 'Get-AcceptedDomain'; RemoteDomains = 'Get-RemoteDomain'; HostedContentFilterPolicy = 'Get-HostedContentFilterPolicy'; HostedContentFilterRule = 'Get-HostedContentFilterRule'
        HostedOutboundSpamFilterPolicy = 'Get-HostedOutboundSpamFilterPolicy'; HostedOutboundSpamFilterRule = 'Get-HostedOutboundSpamFilterRule'; AntiPhishPolicy = 'Get-AntiPhishPolicy'
        AntiPhishRule = 'Get-AntiPhishRule'; MalwareFilterPolicy = 'Get-MalwareFilterPolicy'; MalwareFilterRule = 'Get-MalwareFilterRule'; SafeLinksPolicy = 'Get-SafeLinksPolicy'
        SafeLinksRule = 'Get-SafeLinksRule'; SafeAttachmentPolicy = 'Get-SafeAttachmentPolicy'; SafeAttachmentRule = 'Get-SafeAttachmentRule'; RecipientPermissions = 'Get-RecipientPermission'
        DistributionGroups = 'Get-DistributionGroup'; DynamicDistributionGroups = 'Get-DynamicDistributionGroup'
    }
    $MailboxSections = @('Mailboxes', 'MailboxPermissions', 'RecipientPermissions')
    $CopySuffix = " (restored $([datetime]::UtcNow.ToString('yyyy-MM-dd')))"

    $SameTenant = $false
    foreach ($Tenant in @(Get-Tenants -TenantFilter $TargetTenantFilter -IncludeErrors)) { $SameTenant = [string]$Tenant.customerId -eq $SourceTenantId; break }

    $Selected = $null
    if ($null -ne $Items) {
        $Selected = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($Selection in $Items) {
            if ($Selection.Area -and $Selection.Area -ne 'Exchange') { continue }
            [void]$Selected.Add("$($Selection.Section)`n$($Selection.Key)")
        }
    }

    $SectionNames = if ($Snapshot.Sections -is [System.Collections.IDictionary]) { @($Snapshot.Sections.Keys) } else { @($Snapshot.Sections.PSObject.Properties.Name) }
    $Plan = [System.Collections.Generic.List[hashtable]]::new()
    $Work = [ordered]@{}
    foreach ($Section in $SectionNames) {
        $Label = Get-CIPPCloudBackupSectionLabel -Section $Section
        $Entries = [System.Collections.Generic.List[hashtable]]::new()
        $SectionItems = [object[]]@(foreach ($Item in $Snapshot.Sections.$Section) { if ($null -ne $Item) { $Item } })
        if ($SectionItems.Count -eq 0) { continue }
        $Infos = @(Get-CIPPCloudBackupItemInfo -Section $Section -Item $SectionItems)
        for ($ItemIndex = 0; $ItemIndex -lt $SectionItems.Count; $ItemIndex++) {
            $Item = $SectionItems[$ItemIndex]
            $Info = $Infos[$ItemIndex]
            if ($null -ne $Selected -and -not $Selected.Contains("$Section`n$($Info.Key)")) { continue }
            $Entry = @{ Section = $Section; SectionLabel = $Label; Key = $Info.Key; Name = $Info.Name; Item = $Item; Action = $null; Message = $null
                Unmapped = [System.Collections.Generic.List[string]]::new(); Commands = [System.Collections.Generic.List[hashtable]]::new(); DependsOn = -1; Errors = [System.Collections.Generic.List[string]]::new(); Done = $false
            }
            $Plan.Add($Entry)
            if (-not $Specs.ContainsKey($Section)) {
                $Entry.Action = 'NotRestorable'; $Entry.Message = 'This kind of item cannot be restored'
            } elseif ($Section -in $MailboxSections -and -not $SameTenant) {
                $Entry.Action = 'NotRestorable'; $Entry.Message = 'Mailbox settings and permissions can only be restored to the tenant they were backed up from'
            } else {
                $Entries.Add($Entry)
            }
        }
        if ($Entries.Count -gt 0) { $Work[$Section] = $Entries }
    }

    $ReadSections = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($Section in $Work.Keys) {
        if ($GetCmdlets.ContainsKey($Section)) { [void]$ReadSections.Add($Section) }
        if ($Specs[$Section].PolicySection) { [void]$ReadSections.Add($Specs[$Section].PolicySection) }
        if ($Specs[$Section].Kind -eq 'Group' -and -not $SameTenant) { [void]$ReadSections.Add('AcceptedDomains') }
    }
    $LiveRows = @{}
    $LiveErrors = @{}
    $PermissionIdentities = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($Work.Contains('MailboxPermissions')) {
        foreach ($Entry in $Work['MailboxPermissions']) { if ($Entry.Item.Identity) { [void]$PermissionIdentities.Add([string]$Entry.Item.Identity) } }
    }
    $ReadRounds = [System.Collections.Generic.List[hashtable]]::new()
    if ($ReadSections.Count -gt 0) {
        $ReadRounds.Add(@{ Select = $null; Cmdlets = @(foreach ($Section in $ReadSections) {
                    $Parameters = @{}
                    if ($Section -in 'TransportRules', 'RecipientPermissions', 'DistributionGroups', 'DynamicDistributionGroups') { $Parameters['ResultSize'] = 'Unlimited' }
                    if ($Section -eq 'RecipientPermissions') { $Parameters['AccessRights'] = 'SendAs' }
                    @{ CmdletInput = @{ CmdletName = $GetCmdlets[$Section]; Parameters = $Parameters }; OperationGuid = $Section }
                })
            })
    }
    if ($PermissionIdentities.Count -gt 0) {
        $ReadRounds.Add(@{ Select = 'Identity,User,AccessRights,Deny,IsInherited'; Cmdlets = @(foreach ($Identity in $PermissionIdentities) {
                    @{ CmdletInput = @{ CmdletName = 'Get-MailboxPermission'; Parameters = @{ Identity = $Identity } }; OperationGuid = "MailboxPermissions:$Identity" }
                })
            })
    }
    foreach ($Round in $ReadRounds) {
        $BulkError = $null
        $BulkSplat = @{ tenantid = $TargetTenantFilter; cmdletArray = $Round.Cmdlets; MaxConcurrency = 10; ErrorAction = 'Stop' }
        if ($Round.Select) { $BulkSplat['Select'] = $Round.Select }
        $Bulk = try { New-ExoBulkRequest @BulkSplat } catch { $BulkError = Get-NormalizedError -Message $_.Exception.Message }
        foreach ($Row in $Bulk) {
            $Key = [string]$Row.OperationGuid
            if (-not $Key) { continue }
            if ($null -ne $Row.PSObject.Properties['error']) { $LiveErrors[$Key] = Get-NormalizedError -Message ([string]$Row.error); continue }
            if (-not $LiveRows.ContainsKey($Key)) { $LiveRows[$Key] = [System.Collections.Generic.List[object]]::new() }
            if ($null -ne $Row.PSObject.Properties['Success'] -and $null -eq $Row.PSObject.Properties['Identity']) { continue }
            $LiveRows[$Key].Add($Row)
        }
        foreach ($Cmdlet in $Round.Cmdlets) {
            if (-not $LiveRows.ContainsKey($Cmdlet.OperationGuid) -and -not $LiveErrors.ContainsKey($Cmdlet.OperationGuid)) { $LiveErrors[$Cmdlet.OperationGuid] = $BulkError ?? 'no response from Exchange' }
        }
    }

    $Live = @{}
    foreach ($Section in $ReadSections) {
        if ($LiveErrors.ContainsKey($Section) -or $Section -eq 'RecipientPermissions') { continue }
        $Index = @{ ById = @{}; ByName = @{}; Default = $null; Rows = $LiveRows[$Section] }
        foreach ($Row in $LiveRows[$Section]) {
            foreach ($Id in $Row.Guid, $Row.ExchangeObjectId) { if ($Id) { $Index.ById[[string]$Id] = $Row } }
            $MatchName = if ($Section -in 'AcceptedDomains', 'RemoteDomains') { $Row.DomainName } else { $Row.Name }
            if ($MatchName) { $Index.ByName[([string]$MatchName -replace '\p{Cf}', '').Trim()] = $Row }
            if ($Row.IsDefault -eq $true) { $Index.Default = $Row }
        }
        $Live[$Section] = $Index
    }
    $TargetDomains = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($Live.ContainsKey('AcceptedDomains')) { foreach ($Row in $Live['AcceptedDomains'].Rows) { if ($Row.DomainName) { [void]$TargetDomains.Add([string]$Row.DomainName) } } }

    $LiveMailboxes = $null
    if ($Work.Contains('Mailboxes')) {
        $LiveMailboxes = @{
            ByExchangeGuid = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
            ByGuid         = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
            ByUpn          = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
        }
        $MailboxSelect = (@('Identity', 'Guid', 'ExchangeGuid', 'UserPrincipalName', 'RecipientTypeDetails', 'DefaultAuditSet') + $Specs['Mailboxes'].Params) -join ','
        try {
            New-ExoRequest -tenantid $TargetTenantFilter -cmdlet 'Get-Mailbox' -cmdParams @{ ResultSize = 'Unlimited' } -Select $MailboxSelect -StreamPages -ErrorAction Stop | & { process {
                    foreach ($Mailbox in $_.Value) {
                        if ($Mailbox.ExchangeGuid) { $LiveMailboxes.ByExchangeGuid[[string]$Mailbox.ExchangeGuid] = $Mailbox }
                        if ($Mailbox.Guid) { $LiveMailboxes.ByGuid[[string]$Mailbox.Guid] = $Mailbox }
                        if ($Mailbox.UserPrincipalName) { $LiveMailboxes.ByUpn[[string]$Mailbox.UserPrincipalName] = $Mailbox }
                    }
                } }
        } catch {
            $LiveErrors['Mailboxes'] = Get-NormalizedError -Message $_.Exception.Message
        }
    }

    $GroupMemberReads = [System.Collections.Generic.List[hashtable]]::new()
    $PolicyNames = @{}
    $PolicyEntries = @{}
    foreach ($Section in $Specs.Keys) { if ($Specs[$Section].Kind -eq 'Policy') { $PolicyNames[$Section] = @{}; $PolicyEntries[$Section] = @{} } }

    foreach ($Section in @(@($Work.Keys).Where({ $Specs[$_].Kind -eq 'Policy' })) + @(@($Work.Keys).Where({ $Specs[$_].Kind -ne 'Policy' }))) {
        $Spec = $Specs[$Section]
        $Kind = $Spec.Kind
        $ReadError = if ($Kind -eq 'Mailbox') { $LiveErrors['Mailboxes'] } elseif ($Kind -ne 'MailboxPermission') { $LiveErrors[$Section] } else { $null }
        if (-not $ReadError -and $Spec.PolicySection) { $ReadError = $LiveErrors[$Spec.PolicySection] }
        $LiveIndex = $Live[$Section]
        $RuleCount = if ($LiveIndex) { $LiveIndex.Rows.Count } else { 0 }

        $LivePermissions = $null
        if ($Kind -eq 'RecipientPermission' -and -not $ReadError) {
            $LivePermissions = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($Row in $LiveRows['RecipientPermissions']) { if (@($Row.AccessRights) -contains 'SendAs' -and -not $Row.Deny) { [void]$LivePermissions.Add("$($Row.Identity)`n$($Row.Trustee)") } }
        }

        foreach ($Entry in $Work[$Section]) {
            try {
                $Item = $Entry.Item
                if ($ReadError) {
                    $Entry.Action = 'Skip'; $Entry.Errors.Add("Could not read the current $($Entry.SectionLabel) from the target tenant: $ReadError")
                    continue
                }

                if ($Kind -in 'MailboxPermission', 'RecipientPermission') {
                    $Trustee = if ($Kind -eq 'MailboxPermission') { [string]$Item.User } else { [string]$Item.Trustee }
                    if ($Item.Deny) { $Entry.Action = 'NotRestorable'; $Entry.Message = 'Deny entries are not restored'; continue }
                    if ($Trustee -match '^S-1-5-') { $Entry.Action = 'NotRestorable'; $Entry.Message = 'The user this was granted to no longer exists'; continue }
                    $Granted = $false
                    if ($Kind -eq 'MailboxPermission') {
                        $PermissionKey = "MailboxPermissions:$($Item.Identity)"
                        if ($LiveErrors.ContainsKey($PermissionKey)) { $Entry.Action = 'Skip'; $Entry.Errors.Add("Could not read the mailbox's current permissions: $($LiveErrors[$PermissionKey])"); continue }
                        foreach ($Row in $LiveRows[$PermissionKey]) { if ([string]$Row.User -eq $Trustee -and @($Row.AccessRights) -contains 'FullAccess' -and -not $Row.Deny) { $Granted = $true; break } }
                    } else {
                        $Granted = $LivePermissions.Contains("$($Item.Identity)`n$Trustee")
                    }
                    if ($Granted) { $Entry.Action = 'Skip'; $Entry.Message = 'Already granted'; continue }
                    $Entry.Action = 'Create'
                    $Entry.Message = if ($Kind -eq 'MailboxPermission') { "Grants $Trustee full access" } else { "Grants $Trustee Send As" }
                    $Entry.Commands.Add($(if ($Kind -eq 'MailboxPermission') {
                                @{ Phase = 1; Cmdlet = 'Add-MailboxPermission'; Params = @{ Identity = [string]$Item.Identity; User = $Trustee; AccessRights = @('FullAccess'); InheritanceType = 'All'; Confirm = $false } }
                            } else {
                                @{ Phase = 1; Cmdlet = 'Add-RecipientPermission'; Params = @{ Identity = [string]$Item.Identity; Trustee = $Trustee; AccessRights = @('SendAs'); Confirm = $false } }
                            }))
                    continue
                }

                $Target = $null
                $IsDefault = $false
                if ($Kind -eq 'Mailbox') {
                    foreach ($Lookup in @(@($LiveMailboxes.ByExchangeGuid, $Item.ExchangeGuid), @($LiveMailboxes.ByGuid, $Item.Guid), @($LiveMailboxes.ByUpn, $Item.UserPrincipalName))) {
                        if ($Lookup[1] -and $Lookup[0].ContainsKey([string]$Lookup[1])) { $Target = $Lookup[0][[string]$Lookup[1]]; break }
                    }
                    if (-not $Target) { $Entry.Action = 'NotRestorable'; $Entry.Message = 'The mailbox no longer exists; restore the mailbox first'; continue }
                } elseif ($Kind -eq 'Singleton') {
                    $Target = @($LiveIndex.Rows)[0]
                    $IsDefault = $true
                } else {
                    if ($Kind -eq 'Policy') {
                        $Entry.Index = $Plan.IndexOf($Entry)
                        $PolicyEntries[$Section][[string]$Item.Name] = $Entry
                    }
                    if ($Item.RecommendedPolicyType -in 'Standard', 'Strict' -or $Item.IsBuiltInProtection -eq $true) {
                        $Entry.Action = 'NotRestorable'; $Entry.Message = 'Part of a Microsoft preset security policy, which Microsoft manages'; continue
                    }
                    $IsDefault = $Item.IsDefault -eq $true -or ($Kind -eq 'RemoteDomain' -and [string]$Item.DomainName -eq '*')
                    if ($IsDefault -and $LiveIndex.Default) {
                        $Target = $LiveIndex.Default
                    } else {
                        if ($SameTenant) { foreach ($Id in $Item.Guid, $Item.ExchangeObjectId) { if ($Id -and $LiveIndex.ById.ContainsKey([string]$Id)) { $Target = $LiveIndex.ById[[string]$Id]; break } } }
                        $MatchName = if ($Kind -in 'AcceptedDomain', 'RemoteDomain') { $Item.DomainName } else { $Item.Name }
                        if (-not $Target -and $MatchName) { $Target = $LiveIndex.ByName[([string]$MatchName -replace '\p{Cf}', '').Trim()] }
                    }
                }

                $Notes = [System.Collections.Generic.List[string]]::new()
                $PolicyTarget = $null
                if ($Kind -eq 'Rule' -and $Spec.PolicySection) {
                    $PolicyName = [string]$Item.($Spec.PolicySection)
                    $PolicyEntry = $PolicyEntries[$Spec.PolicySection][$PolicyName]
                    if ($PolicyEntry -and $PolicyEntry.Action -eq 'NotRestorable') { $Entry.Action = 'NotRestorable'; $Entry.Message = "Its policy '$PolicyName' cannot be restored"; continue }
                    if ($PolicyEntry -and $PolicyEntry.Action -in 'Create', 'CreateCopy') {
                        $PolicyTarget = $PolicyNames[$Spec.PolicySection][$PolicyName]
                        $Entry.DependsOn = $PolicyEntry.Index
                    } elseif ($Live[$Spec.PolicySection].ByName.ContainsKey(($PolicyName -replace '\p{Cf}', '').Trim())) {
                        $LivePolicy = $Live[$Spec.PolicySection].ByName[($PolicyName -replace '\p{Cf}', '').Trim()]
                        if ($LivePolicy.RecommendedPolicyType -in 'Standard', 'Strict' -or $LivePolicy.IsBuiltInProtection -eq $true) {
                            $Entry.Action = 'NotRestorable'; $Entry.Message = 'Part of a Microsoft preset security policy, which Microsoft manages'; continue
                        }
                        $PolicyTarget = [string]$LivePolicy.Name
                    } else {
                        $Entry.Action = 'NotRestorable'; $Entry.Message = "Its policy '$PolicyName' is not in the target tenant and is not part of this restore"; continue
                    }
                }

                $Mode = if (-not $Target) { 'Create' } elseif ($ConflictAction -eq 'Overwrite') { 'Update' } elseif ($ConflictAction -eq 'Copy') { 'CreateCopy' } else { 'Skip' }
                if ($Mode -eq 'Create' -and ($IsDefault -or $Kind -in 'Singleton', 'AcceptedDomain')) {
                    $Entry.Action = 'NotRestorable'
                    $Entry.Message = if ($Kind -eq 'AcceptedDomain') { "Add and verify $($Item.DomainName) in Microsoft 365 first; Exchange then lists it as an accepted domain" } else { 'Default items can only be updated, and the target has no matching default' }
                    continue
                }
                if ($Mode -eq 'CreateCopy' -and ($IsDefault -or $Kind -in 'Singleton', 'AcceptedDomain', 'RemoteDomain', 'Mailbox')) {
                    $Entry.Action = 'Skip'; $Entry.Message = 'This item cannot be copied; choose Overwrite to update it'; continue
                }
                if ($Mode -eq 'CreateCopy' -and $Kind -eq 'Rule' -and $Spec.PolicySection -and -not ($PolicyEntries[$Spec.PolicySection][[string]$Item.($Spec.PolicySection)].Action -eq 'CreateCopy')) {
                    $Entry.Action = 'Skip'; $Entry.Message = 'A rule can only be copied together with its policy'; continue
                }
                if ($Mode -eq 'Skip') { $Entry.Action = 'Skip'; $Entry.Message = 'Already exists in the target tenant'; continue }

                $TargetName = if ($Mode -eq 'CreateCopy') { "$($Item.Name)$CopySuffix" } elseif ($Target) { [string]$Target.Name } else { [string]$Item.Name }
                if ($Kind -eq 'Policy') { $PolicyNames[$Section][[string]$Item.Name] = $TargetName }
                $Identity = if ($Kind -eq 'Mailbox') { [string]$Target.UserPrincipalName } elseif ($Mode -eq 'Update') { [string]($Target.Identity ?? $Target.Guid ?? $Target.Name) } else { $TargetName }

                if ($Section -eq 'DistributionGroups') {
                    $Members = @($Item.Members).Where({ $_ })
                    if (-not $SameTenant) {
                        if ($Members.Count -gt 0) { $Entry.Unmapped.Add("$($Members.Count) member(s) are only restored to the tenant the backup came from") }
                    } elseif ($Members.Count -gt 0) {
                        $Entry.GroupIdentity = $Identity
                        $Entry.MemberCount = $Members.Count
                        if ($Mode -eq 'Update') {
                            $GroupMemberReads.Add(@{ Entry = $Entry; Guid = [string]$Target.Guid })
                        } else {
                            foreach ($Member in $Members) { $Entry.Commands.Add(@{ Phase = 3; Cmdlet = 'Add-DistributionGroupMember'; Params = @{ Identity = $Identity; Member = [string]($Member.Guid ?? $Member.PrimarySmtpAddress); BypassSecurityGroupManagerCheck = $true; Confirm = $false } }) }
                            $Notes.Add("Adds $($Members.Count) member(s)")
                        }
                    }
                }
                $Compare = if ($Mode -eq 'Update') { $Target } else { $null }
                $ParamNames = if ($Mode -ne 'Update' -and $Spec.NewParams) { $Spec.NewParams } else { @($Spec.Params) + @(if ($Mode -ne 'Update') { foreach ($Param in $Spec.NewOnlyParams) { $Param } }) }
                if ($Kind -eq 'Group' -and $Section -eq 'DynamicDistributionGroups') {
                    $Precanned = @($Item.IncludedRecipients).Where({ $_ }).Count -gt 0
                    $FilterParams = if ($Precanned) { @('IncludedRecipients', 'ConditionalCompany', 'ConditionalDepartment', 'ConditionalStateOrProvince') + @(foreach ($i in 1..15) { "ConditionalCustomAttribute$i" }) } else { @('RecipientFilter') }
                    if ($Mode -eq 'Update' -and $Precanned -ne (@($Target.IncludedRecipients).Where({ $_ }).Count -gt 0)) {
                        $Notes.Add('The membership filter was not restored because the target group uses a different kind of filter')
                    } else {
                        $ParamNames = @($ParamNames) + $FilterParams
                    }
                }

                $Changes = [ordered]@{}
                foreach ($Param in $ParamNames) {
                    if ($null -eq $Item.PSObject.Properties[$Param]) { continue }
                    $Value = $Item.$Param
                    if ($Value -is [System.Management.Automation.PSCustomObject]) { $Notes.Add("$Param was not restored"); continue }
                    $Canonical = [string[]]::new(2)
                    $Pair = @($Value, $(if ($Compare) { $Compare.$Param }))
                    for ($i = 0; $i -lt 2; $i++) {
                        $Values = foreach ($V in @($Pair[$i])) {
                            if ($null -eq $V -or "$V" -eq '') { continue }
                            if ($V -is [datetime]) { $V.ToUniversalTime().ToString('o') }
                            elseif ($V -is [string] -and $V.EndsWith(' bytes)') -and $V -match '\(([\d,]+) bytes\)$') { $Matches[1].Replace(',', '') }
                            else { [string]$V }
                        }
                        $Values = [string[]]@($Values)
                        if ($Pair[$i] -is [System.Collections.IList]) { [System.Array]::Sort($Values, [System.StringComparer]::Ordinal) }
                        $Canonical[$i] = $Values -join "`n"
                        if ($i -eq 0) { $SendValue = if ($Values.Count -eq 0) { $null } elseif ($Pair[0] -is [System.Collections.IList]) { $Values } elseif ($Value -is [string]) { $Values[0] } else { $Value } }
                    }
                    if ($Compare) {
                        if ($Canonical[0] -ceq $Canonical[1]) { continue }
                    } elseif ($null -eq $SendValue) {
                        continue
                    }
                    if (-not $SameTenant -and $Param -in $Spec.SameTenantParams) { $Entry.Unmapped.Add("$Param ($($Canonical[0] -replace "`n", ', ')) refers to objects in the source tenant and was not restored"); continue }
                    if ($Param -eq 'IntraOrgFilterState' -and $SendValue -eq 'Default') { $SendValue = 'HighConfidencePhish' }
                    $Changes[$Param] = $SendValue
                }

                if ($Kind -eq 'Mailbox') {
                    if ($Changes.Contains('LitigationHoldEnabled') -and $Changes['LitigationHoldEnabled'] -ne $true) {
                        $Changes.Remove('LitigationHoldEnabled')
                        $Notes.Add('Litigation hold is only switched on, never off')
                    }
                    if ($Changes.Contains('LitigationHoldDuration') -and -not ($Item.LitigationHoldEnabled -eq $true)) { $Changes.Remove('LitigationHoldDuration') }
                    if ($Item.UseDatabaseQuotaDefaults -eq $true) { foreach ($Param in 'IssueWarningQuota', 'ProhibitSendQuota', 'ProhibitSendReceiveQuota') { $Changes.Remove($Param) } }
                    if ([string]$Item.RecipientTypeDetails -notin 'RoomMailbox', 'EquipmentMailbox') { $Changes.Remove('ResourceCapacity') }
                    $DefaultAudit = @(foreach ($Set in @($Item.DefaultAuditSet)) { if ($Set) { [string]$Set } })
                    $MissingDefaults = @(foreach ($Set in $DefaultAudit) { if (@($Target.DefaultAuditSet) -notcontains $Set) { $Set } })
                    foreach ($Set in $DefaultAudit) { $Changes.Remove("Audit$Set") }
                    if ($MissingDefaults.Count -gt 0) { $Changes['DefaultAuditSet'] = $MissingDefaults }
                    if ($Changes.Contains('GrantSendOnBehalfTo')) {
                        $Missing = @(foreach ($Delegate in @($Item.GrantSendOnBehalfTo)) { if ($Delegate -and @($Target.GrantSendOnBehalfTo) -notcontains $Delegate) { [string]$Delegate } })
                        if ($Missing.Count -gt 0) { $Changes['GrantSendOnBehalfTo'] = @{ '@odata.type' = '#Exchange.GenericHashTable'; Add = $Missing } } else { $Changes.Remove('GrantSendOnBehalfTo') }
                    }
                }

                if ($Mode -eq 'Update') {
                    if ($Kind -eq 'Rule' -and $Spec.PolicySection -and $PolicyTarget -and $PolicyTarget -ne [string]$Target.($Spec.PolicySection)) { $Changes[$Spec.PolicySection] = $PolicyTarget }
                    if ($Kind -eq 'Rule' -and $null -ne $Item.Priority -and $RuleCount -gt 0) {
                        $Priority = [Math]::Min([int]$Item.Priority, $RuleCount - 1)
                        if ($Priority -ne [int]$Target.Priority) { $Changes['Priority'] = $Priority }
                    }
                    $StateChange = $Kind -eq 'Rule' -and $Item.State -and [string]$Item.State -ne [string]$Target.State
                    if ($Changes.Count -eq 0 -and -not $StateChange) {
                        $Entry.Action = 'Skip'; $Entry.Message = (@('Already matches the backup') + $Notes) -join '. '
                        continue
                    }
                    if ($Kind -eq 'Singleton') {
                        foreach ($Param in $Changes.Keys) { $Entry.Commands.Add(@{ Phase = 1; Cmdlet = "Set-$($Spec.Noun)"; Params = @{ $Param = $Changes[$Param] } }) }
                    } elseif ($Changes.Count -gt 0) {
                        $Params = @{ Identity = $Identity }
                        foreach ($Param in $Changes.Keys) { $Params[$Param] = $Changes[$Param] }
                        $Entry.Commands.Add(@{ Phase = $(if ($Kind -eq 'Rule' -and $Spec.PolicySection) { 2 } else { 1 }); Cmdlet = "Set-$($Spec.Noun)"; Params = $Params; Anchor = $Kind -eq 'Mailbox' })
                    }
                    if ($StateChange) {
                        $Entry.Commands.Add(@{ Phase = 3; Cmdlet = "$(if ([string]$Item.State -eq 'Enabled') { 'Enable' } else { 'Disable' })-$($Spec.Noun)"; Params = @{ Identity = $Identity; Confirm = $false } })
                    }
                    $Entry.Action = 'Update'
                    $Changed = @($Changes.Keys) + @(if ($StateChange) { 'State' })
                    $Notes.Insert(0, "$($Changed.Count) setting(s) differ from the backup: $(@($Changed)[0..([Math]::Min(9, $Changed.Count - 1))] -join ', ')$(if ($Changed.Count -gt 10) { ', ...' })")
                } else {
                    $Params = @{ Name = $TargetName }
                    foreach ($Param in $Changes.Keys) { $Params[$Param] = $Changes[$Param] }
                    $FollowUp = $null
                    switch ($Kind) {
                        'Rule' {
                            if ($Spec.PolicySection) { $Params[$Spec.PolicySection] = $PolicyTarget }
                            if ($Item.State) { $Params['Enabled'] = [string]$Item.State -eq 'Enabled' }
                        }
                        'RemoteDomain' {
                            $FollowUp = $Params
                            $FollowUp.Remove('Name')
                            $FollowUp['Identity'] = $TargetName
                            $Params = @{ Name = $TargetName; DomainName = [string]$Item.DomainName }
                        }
                        'Group' {
                            if ($Mode -eq 'Create') {
                                if ($Item.Alias) { $Params['Alias'] = [string]$Item.Alias }
                                $Address = [string]$Item.PrimarySmtpAddress
                                if ($Address -and ($SameTenant -or $TargetDomains.Contains($Address.Split('@')[-1]))) {
                                    $Params['PrimarySmtpAddress'] = $Address
                                } elseif ($Address) {
                                    $Entry.Unmapped.Add("The address $Address uses a domain the target tenant doesn't have; Exchange assigns a new address")
                                }
                            } else {
                                $Params['DisplayName'] = $TargetName
                            }
                            if ($Section -eq 'DistributionGroups') {
                                $Params['Type'] = if ([string]$Item.RecipientTypeDetails -eq 'MailUniversalSecurityGroup') { 'Security' } else { 'Distribution' }
                                if ([string]$Item.RecipientTypeDetails -eq 'RoomList') { $Params['RoomList'] = $true }
                            }
                            $SetOnly = [ordered]@{}
                            foreach ($Param in $Spec.Params) {
                                if ($Param -in $Spec.NewParams -or $null -eq $Item.PSObject.Properties[$Param]) { continue }
                                $Value = $Item.$Param
                                if ($null -eq $Value -or @($Value).Where({ $null -ne $_ -and "$_" -ne '' }).Count -eq 0 -or $Value -is [System.Management.Automation.PSCustomObject]) { continue }
                                if (-not $SameTenant -and $Param -in $Spec.SameTenantParams) { $Entry.Unmapped.Add("$Param ($(@($Value) -join ', ')) refers to objects in the source tenant and was not restored"); continue }
                                $SetOnly[$Param] = $Value
                            }
                            if ($SetOnly.Count -gt 0) {
                                $FollowUp = @{ Identity = $TargetName }
                                foreach ($Param in $SetOnly.Keys) { $FollowUp[$Param] = $SetOnly[$Param] }
                            }
                        }
                    }
                    $DisabledCopy = $Mode -eq 'CreateCopy' -and ($Kind -eq 'Rule' -or $Spec.Noun -like '*Connector')
                    if ($DisabledCopy) { $Params['Enabled'] = $false }
                    $Entry.Commands.Add(@{ Phase = $(if ($Kind -eq 'Rule' -and $Spec.PolicySection) { 2 } else { 1 }); Cmdlet = "New-$($Spec.Noun)"; Params = $Params })
                    if ($FollowUp -and $FollowUp.Count -gt 1) { $Entry.Commands.Add(@{ Phase = 2; Cmdlet = "Set-$($Spec.Noun)"; Params = $FollowUp }) }
                    $Entry.Action = $Mode
                    $Notes.Insert(0, $(if ($DisabledCopy) { "$(if ($Apply) { 'Created' } else { 'Will be created' }) as a disabled copy named '$TargetName'" } elseif ($Mode -eq 'CreateCopy') { "$(if ($Apply) { 'Created' } else { 'Will be created' }) as a copy named '$TargetName'" } elseif ($Apply) { 'Created' } else { 'Will be created' }))
                }

                $Entry.Message = $Notes -join '. '
            } catch {
                $Entry.Action = $Entry.Action ?? 'Skip'
                $Entry.Errors.Add("Could not plan this item: $($_.Exception.Message)")
            }
        }
    }

    if ($GroupMemberReads.Count -gt 0) {
        $BulkError = $null
        $Reads = @(foreach ($Read in $GroupMemberReads) {
                @{ CmdletInput = @{ CmdletName = 'Get-DistributionGroupMember'; Parameters = @{ Identity = $Read.Guid; ResultSize = 'Unlimited' } }; OperationGuid = "Members:$($Read.Guid)" }
            })
        $MemberRows = @{}
        $MemberErrors = @{}
        $Bulk = try { New-ExoBulkRequest -tenantid $TargetTenantFilter -cmdletArray $Reads -Select 'Guid,PrimarySmtpAddress' -MaxConcurrency 10 -ErrorAction Stop } catch { $BulkError = Get-NormalizedError -Message $_.Exception.Message }
        foreach ($Row in $Bulk) {
            $Key = [string]$Row.OperationGuid
            if (-not $Key) { continue }
            if ($null -ne $Row.PSObject.Properties['error']) { $MemberErrors[$Key] = Get-NormalizedError -Message ([string]$Row.error); continue }
            if (-not $MemberRows.ContainsKey($Key)) { $MemberRows[$Key] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase) }
            foreach ($Id in $Row.Guid, $Row.PrimarySmtpAddress) { if ($Id) { [void]$MemberRows[$Key].Add([string]$Id) } }
        }
        foreach ($Read in $GroupMemberReads) {
            $Entry = $Read.Entry
            $Key = "Members:$($Read.Guid)"
            if (-not $MemberRows.ContainsKey($Key)) {
                $Entry.Errors.Add("Could not read the group's current members: $($MemberErrors[$Key] ?? $BulkError ?? 'no response from Exchange')")
                continue
            }
            $Missing = @(foreach ($Member in @($Entry.Item.Members)) {
                    if (-not $Member) { continue }
                    if (-not ($MemberRows[$Key].Contains([string]$Member.Guid) -or ($Member.PrimarySmtpAddress -and $MemberRows[$Key].Contains([string]$Member.PrimarySmtpAddress)))) { $Member }
                })
            if ($Missing.Count -eq 0) { continue }
            foreach ($Member in $Missing) { $Entry.Commands.Add(@{ Phase = 3; Cmdlet = 'Add-DistributionGroupMember'; Params = @{ Identity = $Entry.GroupIdentity; Member = [string]($Member.Guid ?? $Member.PrimarySmtpAddress); BypassSecurityGroupManagerCheck = $true; Confirm = $false } }) }
            if ($Entry.Action -eq 'Skip' -and -not $Entry.Errors.Count) { $Entry.Action = 'Update'; $Entry.Message = '' }
            $Entry.Message = (@($Entry.Message, "Adds $($Missing.Count) missing member(s)").Where({ $_ })) -join '. '
        }
    }

    if ($Apply) {
        foreach ($Phase in 1..3) {
            $Batches = @{ Normal = [System.Collections.Generic.List[hashtable]]::new(); Anchored = [System.Collections.Generic.List[hashtable]]::new() }
            for ($Index = 0; $Index -lt $Plan.Count; $Index++) {
                $Entry = $Plan[$Index]
                if ($Entry.Errors.Count -gt 0 -or $Entry.Commands.Count -eq 0) { continue }
                if ($Entry.DependsOn -ge 0 -and $Plan[$Entry.DependsOn].Errors.Count -gt 0) {
                    $Entry.Errors.Add("Its policy '$($Plan[$Entry.DependsOn].Name)' could not be restored")
                    continue
                }
                for ($n = 0; $n -lt $Entry.Commands.Count; $n++) {
                    $Command = $Entry.Commands[$n]
                    if ($Command.Phase -ne $Phase) { continue }
                    $Batches[$(if ($Command.Anchor) { 'Anchored' } else { 'Normal' })].Add(@{ CmdletInput = @{ CmdletName = $Command.Cmdlet; Parameters = $Command.Params }; OperationGuid = "$Index|$n" })
                }
            }
            foreach ($BatchName in 'Normal', 'Anchored') {
                $Operations = $Batches[$BatchName]
                if ($Operations.Count -eq 0) { continue }
                $BulkError = $null
                $Answered = [System.Collections.Generic.HashSet[string]]::new()
                $Bulk = try {
                    New-ExoBulkRequest -tenantid $TargetTenantFilter -cmdletArray $Operations.ToArray() -MaxConcurrency 10 -AnchorPerMailbox:($BatchName -eq 'Anchored') -ErrorAction Stop
                } catch {
                    $BulkError = Get-NormalizedError -Message $_.Exception.Message
                }
                foreach ($Row in $Bulk) {
                    $OperationId = [string]$Row.OperationGuid
                    if (-not $OperationId) { continue }
                    [void]$Answered.Add($OperationId)
                    if ($null -ne $Row.PSObject.Properties['error']) {
                        $Parts = $OperationId.Split('|')
                        $Entry = $Plan[[int]$Parts[0]]
                        $Entry.Errors.Add("$($Entry.Commands[[int]$Parts[1]].Cmdlet): $(Get-NormalizedError -Message ([string]$Row.error))")
                    }
                }
                foreach ($Operation in $Operations) {
                    if ($Answered.Contains($Operation.OperationGuid)) { continue }
                    $Parts = $Operation.OperationGuid.Split('|')
                    $Plan[[int]$Parts[0]].Errors.Add("$($Operation.CmdletInput.CmdletName): $($BulkError ?? 'no response from Exchange')")
                }
            }
        }
    }

    foreach ($Entry in $Plan) {
        $Status = if ($Entry.Errors.Count -gt 0) { 'Failed' } elseif ($Entry.Action -in 'Skip', 'NotRestorable') { 'Skipped' } elseif ($Apply) { 'Succeeded' } else { 'Planned' }
        $Message = if ($Entry.Errors.Count -gt 0) { (@($Entry.Errors) + @($Entry.Message).Where({ $_ })) -join '. ' } else { $Entry.Message }
        [pscustomobject]@{
            Area         = 'Exchange'
            Section      = $Entry.Section
            SectionLabel = $Entry.SectionLabel
            Key          = $Entry.Key
            Name         = $Entry.Name
            Action       = $Entry.Action
            Status       = $Status
            Message      = $Message
            Unmapped     = @($Entry.Unmapped)
        }
    }
}
