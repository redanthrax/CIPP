function Get-CIPPCloudBackupConfigData {
    <#
    .SYNOPSIS
        Reads one configuration area of a tenant live, for Cloud Backup
    .DESCRIPTION
        Returns the area's raw objects per section. A section that cannot be read is left out with a warning, and
        the call throws only when every section of the area failed. A feature the tenant is not licensed for is a
        warning, not a failure.
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TenantFilter,
        [Parameter(Mandatory = $true)]
        [ValidateSet('ConditionalAccess', 'Intune', 'Exchange', 'SharePoint')]
        [string]$Area,
        [switch]$IncludeSecrets
    )

    $AreaLabel = @{ ConditionalAccess = 'Conditional Access'; Intune = 'Intune'; Exchange = 'Exchange'; SharePoint = 'SharePoint' }[$Area]

    $Sections = [ordered]@{}
    $References = @{ Groups = @{}; Users = @{} }
    $Warnings = [System.Collections.Generic.List[string]]::new()
    $Attempted = 0
    $Failed = 0

    $Preset = @{ ConditionalAccess = 'Entra'; Intune = 'Intune'; Exchange = 'Exchange'; SharePoint = 'SharePoint' }[$Area]
    if (-not (Test-CIPPStandardLicense -StandardName 'CloudBackup' -TenantFilter $TenantFilter -Preset $Preset -SkipLog)) {
        $Warnings.Add("$AreaLabel was skipped: the tenant is not licensed for it, or its licences could not be read")
        return [pscustomobject]@{ Sections = $Sections; Warnings = @($Warnings); References = $References }
    }

    switch ($Area) {
        { $_ -in 'ConditionalAccess', 'Intune' } {
            $ListRequests = if ($Area -eq 'ConditionalAccess') {
                @{ id = 'policies'; method = 'GET'; url = '/identity/conditionalAccess/policies' }
                @{ id = 'namedLocations'; method = 'GET'; url = '/identity/conditionalAccess/namedLocations' }
                @{ id = 'authenticationStrengthPolicies'; method = 'GET'; url = '/identity/conditionalAccess/authenticationStrength/policies' }
                @{ id = 'authenticationContextClassReferences'; method = 'GET'; url = '/identity/conditionalAccess/authenticationContextClassReferences' }
            } else {
                @{ id = 'deviceConfigurations'; method = 'GET'; url = '/deviceManagement/deviceConfigurations?$expand=assignments&$top=999' }
                @{ id = 'configurationPolicies'; method = 'GET'; url = '/deviceManagement/configurationPolicies?$expand=assignments,settings&$top=1000' }
                @{ id = 'groupPolicyConfigurations'; method = 'GET'; url = '/deviceManagement/groupPolicyConfigurations?$expand=assignments&$top=1000' }
                @{ id = 'deviceCompliancePolicies'; method = 'GET'; url = '/deviceManagement/deviceCompliancePolicies?$expand=assignments,scheduledActionsForRule($expand=scheduledActionConfigurations)&$top=1000' }
                @{ id = 'managedAppPolicies'; method = 'GET'; url = '/deviceAppManagement/managedAppPolicies' }
                @{ id = 'mobileAppConfigurations'; method = 'GET'; url = '/deviceAppManagement/mobileAppConfigurations?$expand=assignments' }
                @{ id = 'intents'; method = 'GET'; url = '/deviceManagement/intents?$top=1000' }
                @{ id = 'windowsFeatureUpdateProfiles'; method = 'GET'; url = '/deviceManagement/windowsFeatureUpdateProfiles?$expand=assignments&$top=200' }
                @{ id = 'windowsQualityUpdatePolicies'; method = 'GET'; url = '/deviceManagement/windowsQualityUpdatePolicies?$expand=assignments&$top=200' }
                @{ id = 'windowsQualityUpdateProfiles'; method = 'GET'; url = '/deviceManagement/windowsQualityUpdateProfiles?$expand=assignments&$top=200' }
                @{ id = 'windowsDriverUpdateProfiles'; method = 'GET'; url = '/deviceManagement/windowsDriverUpdateProfiles?$expand=assignments&$top=200' }
                @{ id = 'deviceManagementScripts'; method = 'GET'; url = '/deviceManagement/deviceManagementScripts?$expand=assignments' }
                @{ id = 'deviceShellScripts'; method = 'GET'; url = '/deviceManagement/deviceShellScripts?$expand=assignments' }
                @{ id = 'deviceHealthScripts'; method = 'GET'; url = '/deviceManagement/deviceHealthScripts?$expand=assignments' }
                @{ id = 'assignmentFilters'; method = 'GET'; url = '/deviceManagement/assignmentFilters' }
                @{ id = 'roleScopeTags'; method = 'GET'; url = '/deviceManagement/roleScopeTags' }
            }
            $BulkSplat = @{ tenantid = $TenantFilter; MaxConcurrency = 4 }
            if ($Area -eq 'ConditionalAccess') { $BulkSplat['asapp'] = $true }

            $ScriptSections = @('deviceManagementScripts', 'deviceShellScripts', 'deviceHealthScripts')
            $AppPolicyUrls = @{
                '#microsoft.graph.androidManagedAppProtection'          = "androidManagedAppProtections('{0}')?`$expand=apps,assignments"
                '#microsoft.graph.iosManagedAppProtection'              = "iosManagedAppProtections('{0}')?`$expand=apps,assignments"
                '#microsoft.graph.windowsManagedAppProtection'          = "windowsManagedAppProtections('{0}')?`$expand=apps,assignments"
                '#microsoft.graph.targetedManagedAppConfiguration'      = "targetedManagedAppConfigurations('{0}')?`$expand=apps,assignments"
                '#microsoft.graph.mdmWindowsInformationProtectionPolicy' = "mdmWindowsInformationProtectionPolicies('{0}')?`$expand=assignments,protectedAppLockerFiles,exemptAppLockerFiles"
                '#microsoft.graph.windowsInformationProtectionPolicy'   = "windowsInformationProtectionPolicies('{0}')?`$expand=assignments,protectedAppLockerFiles,exemptAppLockerFiles"
            }

            $Replies = @{}
            $ReplyErrors = @{}
            $Requests = @($ListRequests)
            $Round = 0
            while ($Requests.Count -gt 0) {
                $Round++
                $Responses = @{}
                $BatchError = $null
                try {
                    foreach ($Response in @(New-GraphBulkRequest -Requests $Requests @BulkSplat)) { $Responses[[string]$Response.id] = $Response }
                } catch {
                    $BatchError = Get-NormalizedError -Message $_.Exception.Message
                }
                foreach ($Request in $Requests) {
                    $Response = $Responses[$Request.id]
                    $Status = $Response.status -as [int]
                    if ($Status -ge 200 -and $Status -lt 300 -and -not $Response.PagingIncomplete) {
                        $Replies[$Request.id] = if ($null -ne $Response.body -and $null -ne $Response.body.PSObject.Properties['value']) { [object[]]@(foreach ($Item in $Response.body.value) { $Item }) } else { $Response.body }
                        continue
                    }
                    $Reason = if (-not $Response) { $BatchError ?? 'no response from Graph' } elseif ($Response.PagingIncomplete) { $Response.PagingError } else { Get-NormalizedError -Message ($Response.body.error.message ?? "HTTP $Status") }
                    if ($Round -eq 1) {
                        $Attempted++
                        $Failed++
                        $Warnings.Add("$(Get-CIPPCloudBackupSectionLabel -Section $Request.id): $Reason")
                    } else {
                        $ReplyErrors[$Request.id] = $Reason
                    }
                }
                if ($Round -eq 1) { $Attempted += $Replies.Count }

                $Requests = @(
                    if ($Area -eq 'Intune' -and $Round -eq 1) {
                        foreach ($Policy in $Replies['groupPolicyConfigurations']) {
                            @{ id = "groupPolicyConfigurations:$($Policy.id)"; method = 'GET'; url = "/deviceManagement/groupPolicyConfigurations('$($Policy.id)')/definitionValues?`$expand=definition" }
                        }
                        foreach ($Intent in $Replies['intents']) {
                            @{ id = "intentSettings:$($Intent.id)"; method = 'GET'; url = "/deviceManagement/intents/$($Intent.id)/settings" }
                            @{ id = "intentAssignments:$($Intent.id)"; method = 'GET'; url = "/deviceManagement/intents/$($Intent.id)/assignments" }
                        }
                        foreach ($Section in $ScriptSections) {
                            foreach ($Script in $Replies[$Section]) {
                                @{ id = "$($Section):$($Script.id)"; method = 'GET'; url = "/deviceManagement/$Section/$($Script.id)" }
                            }
                        }
                        foreach ($Policy in $Replies['managedAppPolicies']) {
                            $UrlFormat = $AppPolicyUrls[[string]$Policy.'@odata.type']
                            if ($UrlFormat) { @{ id = "managedAppPolicies:$($Policy.id)"; method = 'GET'; url = "/deviceAppManagement/$($UrlFormat -f $Policy.id)" } }
                        }
                    } elseif ($Area -eq 'Intune' -and $Round -eq 2) {
                        foreach ($Policy in $Replies['groupPolicyConfigurations']) {
                            foreach ($Value in $Replies["groupPolicyConfigurations:$($Policy.id)"]) {
                                @{ id = "presentationValues:$($Policy.id):$($Value.id)"; method = 'GET'; url = "/deviceManagement/groupPolicyConfigurations('$($Policy.id)')/definitionValues('$($Value.id)')/presentationValues?`$expand=presentation" }
                            }
                        }
                    }
                )
            }

            foreach ($Request in $ListRequests) {
                $Section = $Request.id
                if (-not $Replies.ContainsKey($Section)) { continue }
                $Left = [System.Collections.Generic.List[string]]::new()
                $LeftReason = $null
                $Items = switch ($Section) {
                    'deviceConfigurations' {
                        $Undecrypted = [System.Collections.Generic.List[string]]::new()
                        $Masked = [System.Collections.Generic.List[string]]::new()
                        foreach ($Policy in $Replies[$Section]) {
                            if (@($Policy.omaSettings).Where({ $_.secretReferenceValueId }).Count -gt 0) {
                                if ($IncludeSecrets) {
                                    $null = Get-CIPPOmaSettingDecryptedValue -DeviceConfiguration $Policy -DeviceConfigurationId $Policy.id -TenantFilter $TenantFilter
                                    if (@($Policy.omaSettings).Where({ $_.secretReferenceValueId }).Count -gt 0) { $Undecrypted.Add([string]$Policy.displayName) }
                                } else {
                                    foreach ($Setting in $Policy.omaSettings) {
                                        if (-not $Setting.secretReferenceValueId) { continue }
                                        if ($null -ne $Setting.PSObject.Properties['value']) {
                                            $Setting.value = '(encrypted)'
                                        } else {
                                            $Setting.PSObject.Properties.Add([psnoteproperty]::new('value', '(encrypted)'))
                                        }
                                    }
                                    $Masked.Add([string]$Policy.displayName)
                                }
                            }
                            $Policy
                        }
                        if ($Undecrypted.Count -gt 0) {
                            $Warnings.Add("Intune configuration profiles: encrypted OMA-URI values could not be read for $($Undecrypted -join ', '); the backup holds Intune's placeholder for them")
                        }
                        if ($Masked.Count -gt 0) {
                            $Warnings.Add("Intune configuration profiles: encrypted OMA-URI values in $($Masked -join ', ') were not backed up because this backup policy doesn't use encryption; turn on encryption to back them up")
                        }
                    }
                    'groupPolicyConfigurations' {
                        foreach ($Policy in $Replies[$Section]) {
                            $ValuesKey = "groupPolicyConfigurations:$($Policy.id)"
                            if (-not $Replies.ContainsKey($ValuesKey)) {
                                $Left.Add([string]$Policy.displayName); $LeftReason ??= $ReplyErrors[$ValuesKey]
                                continue
                            }
                            $Complete = $true
                            foreach ($Value in $Replies[$ValuesKey]) {
                                $PresentationKey = "presentationValues:$($Policy.id):$($Value.id)"
                                if (-not $Replies.ContainsKey($PresentationKey)) {
                                    $Complete = $false; $LeftReason ??= $ReplyErrors[$PresentationKey]
                                    break
                                }
                                $Value.PSObject.Properties.Remove('presentationValues')
                                $Value.PSObject.Properties.Add([psnoteproperty]::new('presentationValues', $Replies[$PresentationKey]))
                            }
                            if (-not $Complete) { $Left.Add([string]$Policy.displayName); continue }
                            $Policy.PSObject.Properties.Remove('definitionValues')
                            $Policy.PSObject.Properties.Add([psnoteproperty]::new('definitionValues', $Replies[$ValuesKey]))
                            $Policy
                        }
                    }
                    'intents' {
                        foreach ($Intent in $Replies[$Section]) {
                            $SettingsKey = "intentSettings:$($Intent.id)"
                            $AssignmentsKey = "intentAssignments:$($Intent.id)"
                            if (-not ($Replies.ContainsKey($SettingsKey) -and $Replies.ContainsKey($AssignmentsKey))) {
                                $Left.Add([string]$Intent.displayName); $LeftReason ??= $ReplyErrors[$SettingsKey] ?? $ReplyErrors[$AssignmentsKey]
                                continue
                            }
                            $Intent.PSObject.Properties.Remove('settings')
                            $Intent.PSObject.Properties.Add([psnoteproperty]::new('settings', $Replies[$SettingsKey]))
                            $Intent.PSObject.Properties.Remove('assignments')
                            $Intent.PSObject.Properties.Add([psnoteproperty]::new('assignments', $Replies[$AssignmentsKey]))
                            $Intent
                        }
                    }
                    { $_ -in $ScriptSections } {
                        foreach ($Script in $Replies[$Section]) {
                            $DetailKey = "$($Section):$($Script.id)"
                            if (-not $Replies.ContainsKey($DetailKey)) {
                                $Left.Add([string]$Script.displayName); $LeftReason ??= $ReplyErrors[$DetailKey]
                                continue
                            }
                            $Detail = $Replies[$DetailKey]
                            $Detail.PSObject.Properties.Remove('assignments')
                            $Detail.PSObject.Properties.Add([psnoteproperty]::new('assignments', @($Script.assignments)))
                            $Detail
                        }
                    }
                    'managedAppPolicies' {
                        foreach ($Policy in $Replies[$Section]) {
                            $Type = [string]$Policy.'@odata.type'
                            if (-not $AppPolicyUrls.ContainsKey($Type)) { $Policy; continue }
                            $DetailKey = "managedAppPolicies:$($Policy.id)"
                            if (-not $Replies.ContainsKey($DetailKey)) {
                                $Left.Add([string]$Policy.displayName); $LeftReason ??= $ReplyErrors[$DetailKey]
                                continue
                            }
                            $Detail = $Replies[$DetailKey]
                            # Graph leaves @odata.type off an entity read through its concrete collection
                            if ($null -eq $Detail.PSObject.Properties['@odata.type']) { $Detail.PSObject.Properties.Add([psnoteproperty]::new('@odata.type', $Type)) }
                            $Detail
                        }
                    }
                    default { $Replies[$Section] }
                }
                $Sections[$Section] = [object[]]@($Items)
                if ($Left.Count -gt 0) {
                    $Warnings.Add("$(Get-CIPPCloudBackupSectionLabel -Section $Section): $($Left.Count) item(s) left out because their details could not be read ($(@($Left)[0..([Math]::Min(9, $Left.Count - 1))] -join ', ')): $LeftReason")
                }
            }

            $DirectoryIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            if ($Area -eq 'ConditionalAccess') {
                foreach ($Policy in $Sections['policies']) {
                    $Users = $Policy.conditions.users
                    foreach ($Id in @($Users.includeGroups) + @($Users.excludeGroups) + @($Users.includeUsers) + @($Users.excludeUsers)) {
                        if ($Id -as [guid]) { $null = $DirectoryIds.Add([string]$Id) }
                    }
                }
            } else {
                foreach ($SectionItems in $Sections.Values) {
                    foreach ($Item in $SectionItems) {
                        foreach ($Assignment in $Item.assignments) {
                            $GroupId = $Assignment.target.groupId
                            if ($GroupId -as [guid]) { $null = $DirectoryIds.Add([string]$GroupId) }
                        }
                    }
                }
            }
            $Ids = [string[]]@($DirectoryIds)
            for ($i = 0; $i -lt $Ids.Count; $i += 1000) {
                $Body = @{ ids = $Ids[$i..([Math]::Min($i + 999, $Ids.Count - 1))]; types = @('group', 'user') }
                try {
                    $Resolved = New-GraphPOSTRequest -uri 'https://graph.microsoft.com/v1.0/directoryObjects/getByIds?$select=id,displayName,userPrincipalName' -tenantid $TenantFilter -body ([CIPP.CippJson]::ToJson($Body, 5) ?? (ConvertTo-Json -InputObject $Body -Compress)) -AsApp ($Area -eq 'ConditionalAccess')
                    foreach ($Object in @($Resolved.value)) {
                        switch ([string]$Object.'@odata.type') {
                            '#microsoft.graph.group' { $References.Groups[[string]$Object.id] = [string]$Object.displayName }
                            '#microsoft.graph.user' { $References.Users[[string]$Object.id] = [string]$Object.userPrincipalName }
                        }
                    }
                } catch {
                    $Warnings.Add("$($AreaLabel): the names of the groups and users it uses could not be read, so a restore to another tenant will not map them: $(Get-NormalizedError -Message $_.Exception.Message)")
                    break
                }
            }
        }
        'Exchange' {
            $ConfigCmdlets = [ordered]@{
                OrganizationConfig             = 'Get-OrganizationConfig'
                TransportRules                 = 'Get-TransportRule'
                InboundConnectors              = 'Get-InboundConnector'
                OutboundConnectors             = 'Get-OutboundConnector'
                AcceptedDomains                = 'Get-AcceptedDomain'
                RemoteDomains                  = 'Get-RemoteDomain'
                HostedContentFilterPolicy      = 'Get-HostedContentFilterPolicy'
                HostedContentFilterRule        = 'Get-HostedContentFilterRule'
                HostedOutboundSpamFilterPolicy = 'Get-HostedOutboundSpamFilterPolicy'
                HostedOutboundSpamFilterRule   = 'Get-HostedOutboundSpamFilterRule'
                AntiPhishPolicy                = 'Get-AntiPhishPolicy'
                AntiPhishRule                  = 'Get-AntiPhishRule'
                MalwareFilterPolicy            = 'Get-MalwareFilterPolicy'
                MalwareFilterRule              = 'Get-MalwareFilterRule'
                SafeLinksPolicy                = 'Get-SafeLinksPolicy'
                SafeLinksRule                  = 'Get-SafeLinksRule'
                SafeAttachmentPolicy           = 'Get-SafeAttachmentPolicy'
                SafeAttachmentRule             = 'Get-SafeAttachmentRule'
                RecipientPermissions           = 'Get-RecipientPermission'
                DistributionGroups             = 'Get-DistributionGroup'
                DynamicDistributionGroups      = 'Get-DynamicDistributionGroup'
            }
            if (-not (Test-CIPPStandardLicense -StandardName 'CloudBackup' -TenantFilter $TenantFilter -Preset DefenderForOffice365 -SkipLog)) {
                foreach ($Section in 'SafeLinksPolicy', 'SafeLinksRule', 'SafeAttachmentPolicy', 'SafeAttachmentRule') { $ConfigCmdlets.Remove($Section) }
                $Warnings.Add('Exchange Safe Links and Safe Attachments were skipped: the tenant is not licensed for Defender for Office 365')
            }

            $Mailboxes = [System.Collections.Generic.List[object]]::new()
            $MailboxError = $null
            $MailboxSelect = 'Identity,Guid,ExchangeGuid,ExternalDirectoryObjectId,UserPrincipalName,Alias,Name,DisplayName,PrimarySmtpAddress,EmailAddresses,WindowsEmailAddress,RecipientTypeDetails,HiddenFromAddressListsEnabled,EmailAddressPolicyEnabled,GrantSendOnBehalfTo,ForwardingAddress,ForwardingSmtpAddress,DeliverToMailboxAndForward,MessageCopyForSentAsEnabled,MessageCopyForSendOnBehalfEnabled,LitigationHoldEnabled,LitigationHoldDuration,RetentionHoldEnabled,RetentionPolicy,RetainDeletedItemsFor,SingleItemRecoveryEnabled,ArchiveGuid,ArchiveStatus,AutoExpandingArchiveEnabled,AuditEnabled,AuditOwner,AuditDelegate,AuditAdmin,DefaultAuditSet,UseDatabaseQuotaDefaults,IssueWarningQuota,ProhibitSendQuota,ProhibitSendReceiveQuota,MaxSendSize,MaxReceiveSize,RecipientLimits,AcceptMessagesOnlyFromSendersOrMembers,RejectMessagesFromSendersOrMembers,RequireSenderAuthenticationEnabled,ModerationEnabled,ModeratedBy,BypassModerationFromSendersOrMembers,SendModerationNotifications,MailTip,MailTipTranslations,ResourceCapacity,RoleAssignmentPolicy,SharingPolicy,AddressBookPolicy,CalendarRepairDisabled,MailboxPlan,Office,CustomAttribute1,CustomAttribute2,CustomAttribute3,CustomAttribute4,CustomAttribute5,CustomAttribute6,CustomAttribute7,CustomAttribute8,CustomAttribute9,CustomAttribute10,CustomAttribute11,CustomAttribute12,CustomAttribute13,CustomAttribute14,CustomAttribute15,ExtensionCustomAttribute1,ExtensionCustomAttribute2,ExtensionCustomAttribute3,ExtensionCustomAttribute4,ExtensionCustomAttribute5'
            try {
                New-ExoRequest -tenantid $TenantFilter -cmdlet 'Get-Mailbox' -cmdParams @{ ResultSize = 'Unlimited' } -Select $MailboxSelect -StreamPages -ErrorAction Stop | & { process { foreach ($Mailbox in $_.Value) { $Mailboxes.Add($Mailbox) } } }
            } catch {
                $MailboxError = Get-NormalizedError -Message $_.Exception.Message
            }

            $ExoRows = @{}
            $ExoErrors = @{}
            $Rounds = [System.Collections.Generic.Queue[object]]::new()
            $Rounds.Enqueue(@{
                    Select   = $null
                    Cmdlets  = @(foreach ($Section in $ConfigCmdlets.Keys) {
                            $Parameters = @{}
                            if ($Section -in 'TransportRules', 'RecipientPermissions', 'DistributionGroups', 'DynamicDistributionGroups') { $Parameters['ResultSize'] = 'Unlimited' }
                            if ($Section -eq 'RecipientPermissions') { $Parameters['AccessRights'] = 'SendAs' }
                            @{ CmdletInput = @{ CmdletName = $ConfigCmdlets[$Section]; Parameters = $Parameters }; OperationGuid = $Section }
                        })
                })
            $Round = 0
            while ($Rounds.Count -gt 0) {
                $Round++
                $Current = $Rounds.Dequeue()
                $BulkError = $null
                $BulkSplat = @{ tenantid = $TenantFilter; cmdletArray = $Current.Cmdlets; MaxConcurrency = 10; ErrorAction = 'Stop' }
                if ($Current.Select) { $BulkSplat['Select'] = $Current.Select }
                $Bulk = try { New-ExoBulkRequest @BulkSplat } catch { $BulkError = Get-NormalizedError -Message $_.Exception.Message }
                foreach ($Row in $Bulk) {
                    $Key = [string]$Row.OperationGuid
                    if (-not $Key) { continue }
                    if ($null -ne $Row.PSObject.Properties['error']) { $ExoErrors[$Key] = Get-NormalizedError -Message ([string]$Row.error); continue }
                    if (-not $ExoRows.ContainsKey($Key)) { $ExoRows[$Key] = [System.Collections.Generic.List[object]]::new() }
                    if ($null -ne $Row.PSObject.Properties['Success'] -and @($Row.PSObject.Properties).Count -eq 2) { continue }
                    if ($Key.StartsWith('MailboxPermissions:') -and ($Row.IsInherited -or $Row.User -eq 'NT AUTHORITY\SELF' -or @($Row.AccessRights) -notcontains 'FullAccess')) { continue }
                    if ($Key -eq 'RecipientPermissions' -and ($Row.IsInherited -or $Row.Trustee -eq 'NT AUTHORITY\SELF')) { continue }
                    $Row.PSObject.Properties.Remove('OperationGuid')
                    $ExoRows[$Key].Add($Row)
                }
                foreach ($Cmdlet in $Current.Cmdlets) {
                    if (-not $ExoRows.ContainsKey($Cmdlet.OperationGuid) -and -not $ExoErrors.ContainsKey($Cmdlet.OperationGuid)) {
                        $ExoErrors[$Cmdlet.OperationGuid] = $BulkError ?? 'no response from Exchange'
                    }
                }

                if ($Round -eq 1) {
                    if ($ExoRows.ContainsKey('DistributionGroups') -and -not $ExoErrors.ContainsKey('DistributionGroups') -and $ExoRows['DistributionGroups'].Count -gt 0) {
                        $Rounds.Enqueue(@{
                                Select  = 'Identity,Guid,Name,DisplayName,PrimarySmtpAddress,ExternalDirectoryObjectId,RecipientTypeDetails'
                                Cmdlets = @(foreach ($Group in $ExoRows['DistributionGroups']) {
                                        @{ CmdletInput = @{ CmdletName = 'Get-DistributionGroupMember'; Parameters = @{ Identity = [string]$Group.Guid; ResultSize = 'Unlimited' } }; OperationGuid = "DistributionGroupMembers:$($Group.Guid)" }
                                    })
                            })
                    }
                    $Upns = @(foreach ($Mailbox in $Mailboxes) { if ($Mailbox.UserPrincipalName) { [string]$Mailbox.UserPrincipalName } })
                    for ($i = 0; $i -lt $Upns.Count; $i += 1000) {
                        $Rounds.Enqueue(@{
                                Select  = 'Identity,User,AccessRights,Deny,IsInherited'
                                Cmdlets = @(foreach ($Upn in $Upns[$i..([Math]::Min($i + 999, $Upns.Count - 1))]) {
                                        @{ CmdletInput = @{ CmdletName = 'Get-MailboxPermission'; Parameters = @{ Identity = $Upn } }; OperationGuid = "MailboxPermissions:$Upn" }
                                    })
                            })
                    }
                }
            }

            foreach ($Section in @(@($ConfigCmdlets.Keys).Where({ $_ -notin 'RecipientPermissions', 'DistributionGroups', 'DynamicDistributionGroups' })) + 'Mailboxes', 'MailboxPermissions', 'RecipientPermissions', 'DistributionGroups', 'DynamicDistributionGroups') {
                $Attempted++
                if ($Section -eq 'Mailboxes') {
                    if ($MailboxError) { $Failed++; $Warnings.Add("Exchange mailboxes: $MailboxError") } else { $Sections[$Section] = $Mailboxes.ToArray() }
                    continue
                }
                if ($Section -eq 'MailboxPermissions') {
                    if ($MailboxError) { $Failed++; $Warnings.Add('Exchange mailbox permissions: skipped because the mailbox list could not be read'); continue }
                    $Unread = [System.Collections.Generic.List[string]]::new()
                    $UnreadReason = $null
                    $Permissions = [System.Collections.Generic.List[object]]::new()
                    foreach ($Upn in $Upns) {
                        $Key = "MailboxPermissions:$Upn"
                        if ($ExoErrors.ContainsKey($Key)) { $Unread.Add($Upn); $UnreadReason ??= $ExoErrors[$Key]; continue }
                        $Permissions.AddRange($ExoRows[$Key])
                    }
                    if ($Upns.Count -gt 0 -and $Unread.Count -eq $Upns.Count) { $Failed++; $Warnings.Add("Exchange mailbox permissions: $UnreadReason"); continue }
                    $Sections[$Section] = $Permissions.ToArray()
                    if ($Unread.Count -gt 0) {
                        $Warnings.Add("Exchange mailbox permissions: permissions of $($Unread.Count) mailbox(es) could not be read ($(@($Unread)[0..([Math]::Min(9, $Unread.Count - 1))] -join ', ')): $UnreadReason")
                    }
                    continue
                }
                if ($ExoErrors.ContainsKey($Section)) { $Failed++; $Warnings.Add("$(Get-CIPPCloudBackupSectionLabel -Section $Section): $($ExoErrors[$Section])"); continue }
                if ($Section -ne 'DistributionGroups') { $Sections[$Section] = $ExoRows[$Section].ToArray(); continue }

                $Left = [System.Collections.Generic.List[string]]::new()
                $LeftReason = $null
                $Sections[$Section] = [object[]]@(foreach ($Group in $ExoRows[$Section]) {
                        $Key = "DistributionGroupMembers:$($Group.Guid)"
                        if ($ExoErrors.ContainsKey($Key)) { $Left.Add([string]$Group.DisplayName); $LeftReason ??= $ExoErrors[$Key]; continue }
                        $Group.PSObject.Properties.Remove('Members')
                        $Group.PSObject.Properties.Add([psnoteproperty]::new('Members', $ExoRows[$Key].ToArray()))
                        $Group
                    })
                if ($Left.Count -gt 0) {
                    $Warnings.Add("Exchange distribution lists: $($Left.Count) group(s) left out because their members could not be read ($(@($Left)[0..([Math]::Min(9, $Left.Count - 1))] -join ', ')): $LeftReason")
                }
            }
        }
        'SharePoint' {
            $Attempted++
            try {
                $Sections['tenantSettings'] = @(New-GraphGetRequest -uri 'https://graph.microsoft.com/beta/admin/sharepoint/settings' -tenantid $TenantFilter -AsApp $true)
            } catch {
                $Failed++; $Warnings.Add("SharePoint tenant settings: $(Get-NormalizedError -Message $_.Exception.Message)")
            }
            $Attempted++
            try {
                $Sections['spoTenantSettings'] = @(Get-CIPPSPOTenant -TenantFilter $TenantFilter -SkipCache -UseCertificate)
            } catch {
                $Failed++; $Warnings.Add("SharePoint sharing settings: $(Get-NormalizedError -Message $_.Exception.Message)")
            }
            $Attempted++
            try {
                $Sites = [System.Collections.Generic.List[object]]::new()
                Get-CIPPSPOSite -TenantFilter $TenantFilter -UseCertificate | & { process { $Sites.Add($_) } }
                $Sections['sites'] = $Sites.ToArray()
            } catch {
                $Failed++; $Warnings.Add("SharePoint sites: $(Get-NormalizedError -Message $_.Exception.Message)")
            }
        }
    }

    if ($Attempted -gt 0 -and $Failed -eq $Attempted) {
        throw "Every $AreaLabel section failed: $($Warnings -join '; ')"
    }
    [pscustomobject]@{ Sections = $Sections; Warnings = @($Warnings); References = $References }
}
