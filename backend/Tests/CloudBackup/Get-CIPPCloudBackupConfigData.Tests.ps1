BeforeAll {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    if (-not ('CIPP.CippJson' -as [type])) { Add-Type -Path (Join-Path $RepoRoot 'Shared/CIPPSharp/bin/CIPPSharp.dll') }
    . (Join-Path $RepoRoot 'Modules/CIPPCore/Public/CloudBackup/Get-CIPPCloudBackupConfigData.ps1')
    . (Join-Path $RepoRoot 'Modules/CIPPCore/Public/CloudBackup/Get-CIPPCloudBackupSectionLabel.ps1')

    function Test-CIPPStandardLicense { param($StandardName, $TenantFilter, $Preset, [switch]$SkipLog) }
    function Get-NormalizedError { param($Message) $Message }
    function New-GraphBulkRequest { param($tenantid, $asapp, $Requests, $MaxConcurrency) }
    function New-GraphGetRequest { param($uri, $tenantid, $AsApp) }
    function New-GraphPOSTRequest { param($uri, $tenantid, $body, $AsApp) }
    function New-ExoRequest { param($tenantid, $cmdlet, $cmdParams, $Select, [switch]$StreamPages) }
    function New-ExoBulkRequest { param($tenantid, $cmdletArray, $Select, $MaxConcurrency) }
    function Get-CIPPSPOTenant { param($TenantFilter, [switch]$SkipCache, [switch]$UseCertificate) }
    function Get-CIPPSPOSite { param($TenantFilter, [switch]$UseCertificate) }
    function Get-CIPPOmaSettingDecryptedValue { param($DeviceConfiguration, $DeviceConfigurationId, $TenantFilter) }

    $script:Tenant = 'contoso.onmicrosoft.com'

    function script:Reply {
        param($Request, $Body, $Status = 200)
        [pscustomobject]@{ id = $Request.id; status = $Status; body = $Body }
    }
}

Describe 'Get-CIPPCloudBackupConfigData' {
    BeforeEach {
        $script:GraphCalls = [System.Collections.Generic.List[object]]::new()
        $script:FailIds = @()
        Mock Test-CIPPStandardLicense { $true }
        Mock New-GraphBulkRequest {
            $script:GraphCalls.Add([pscustomobject]@{ Requests = @($Requests); AsApp = $asapp; TenantId = $tenantid })
            foreach ($Request in $Requests) {
                if ($Request.id -in $script:FailIds) {
                    Reply $Request ([pscustomobject]@{ error = [pscustomobject]@{ message = "denied $($Request.id)" } }) 403
                } else {
                    Reply $Request (& $script:GraphBody $Request)
                }
            }
        }
        $script:GraphBody = { param($Request) [pscustomobject]@{ value = @([pscustomobject]@{ id = "$($Request.id)-1"; displayName = 'One' }) } }
    }

    Context 'ConditionalAccess' {
        It 'reads the four sections in one app-only batch' {
            $Result = Get-CIPPCloudBackupConfigData -TenantFilter $script:Tenant -Area ConditionalAccess

            $script:GraphCalls.Count | Should -Be 1
            $script:GraphCalls[0].AsApp | Should -BeTrue
            $script:GraphCalls[0].TenantId | Should -Be $script:Tenant
            $script:GraphCalls[0].Requests.url | Should -Contain '/identity/conditionalAccess/policies'
            @($Result.Sections.Keys) | Should -Be @('policies', 'namedLocations', 'authenticationStrengthPolicies', 'authenticationContextClassReferences')
            $Result.Sections['policies'][0].id | Should -Be 'policies-1'
            $Result.Warnings.Count | Should -Be 0
        }

        It 'leaves a failing section out with a warning' {
            $script:FailIds = @('namedLocations')
            $Result = Get-CIPPCloudBackupConfigData -TenantFilter $script:Tenant -Area ConditionalAccess

            $Result.Sections.Contains('namedLocations') | Should -BeFalse
            $Result.Sections.Count | Should -Be 3
            $Result.Warnings | Should -Be @('Conditional Access named locations: denied namedLocations')
        }

        It 'treats an incomplete page as a failed section' {
            Mock New-GraphBulkRequest {
                foreach ($Request in $Requests) {
                    $Reply = Reply $Request ([pscustomobject]@{ value = @() })
                    if ($Request.id -eq 'policies') { $Reply | Add-Member -NotePropertyMembers @{ PagingIncomplete = $true; PagingError = 'page 2 failed' } }
                    $Reply
                }
            }
            $Result = Get-CIPPCloudBackupConfigData -TenantFilter $script:Tenant -Area ConditionalAccess
            $Result.Sections.Contains('policies') | Should -BeFalse
            $Result.Sections['namedLocations'].Count | Should -Be 0
            $Result.Warnings | Should -Be @('Conditional Access policies: page 2 failed')
        }

        It 'throws when every section failed' {
            Mock New-GraphBulkRequest { throw 'Graph is down' }
            { Get-CIPPCloudBackupConfigData -TenantFilter $script:Tenant -Area ConditionalAccess } | Should -Throw '*Every Conditional Access section failed*Graph is down*'
        }

        It 'returns a warning and no sections when the tenant is not licensed' {
            Mock Test-CIPPStandardLicense { $false }
            $Result = Get-CIPPCloudBackupConfigData -TenantFilter $script:Tenant -Area ConditionalAccess
            $Result.Sections.Count | Should -Be 0
            $Result.Warnings[0] | Should -BeLike 'Conditional Access was skipped*'
            Should -Invoke New-GraphBulkRequest -Times 0
        }
    }

    Context 'Intune' {
        BeforeEach {
            $script:GraphBody = {
                param($Request)
                switch -Wildcard ($Request.id) {
                    'groupPolicyConfigurations' { [pscustomobject]@{ value = @([pscustomobject]@{ id = 'gp1'; displayName = 'GP One' }, [pscustomobject]@{ id = 'gp2'; displayName = 'GP Two' }) } }
                    'groupPolicyConfigurations:*' { [pscustomobject]@{ value = @([pscustomobject]@{ id = "dv-$($Request.id.Split(':')[1])"; enabled = $true }) } }
                    'presentationValues:*' { [pscustomobject]@{ value = @([pscustomobject]@{ id = 'pv1'; value = 'x' }) } }
                    'intents' { [pscustomobject]@{ value = @([pscustomobject]@{ id = 'in1'; displayName = 'Intent' }) } }
                    'intentSettings:*' { [pscustomobject]@{ value = @([pscustomobject]@{ definitionId = 'd1' }) } }
                    'intentAssignments:*' { [pscustomobject]@{ value = @() } }
                    'deviceManagementScripts' { [pscustomobject]@{ value = @([pscustomobject]@{ id = 's1'; displayName = 'Script'; assignments = @([pscustomobject]@{ id = 'a1' }) }) } }
                    'deviceManagementScripts:*' { [pscustomobject]@{ id = 's1'; displayName = 'Script'; scriptContent = 'abc' } }
                    'managedAppPolicies' {
                        [pscustomobject]@{ value = @(
                                [pscustomobject]@{ id = 'ios1'; displayName = 'iOS'; '@odata.type' = '#microsoft.graph.iosManagedAppProtection' }
                                [pscustomobject]@{ id = 'def1'; displayName = 'Default'; '@odata.type' = '#microsoft.graph.defaultManagedAppProtection' }
                            )
                        }
                    }
                    'managedAppPolicies:*' { [pscustomobject]@{ id = 'ios1'; displayName = 'iOS'; apps = @(); assignments = @() } }
                    'deviceConfigurations' { [pscustomobject]@{ value = @([pscustomobject]@{ id = 'dc1'; displayName = 'Config'; omaSettings = @([pscustomobject]@{ secretReferenceValueId = 'sec' }) }) } }
                    default { [pscustomobject]@{ value = @() } }
                }
            }
        }

        It 'reads every section and the per-item details in three delegated rounds' {
            Mock Get-CIPPOmaSettingDecryptedValue { }
            $Result = Get-CIPPCloudBackupConfigData -TenantFilter $script:Tenant -Area Intune -IncludeSecrets

            $script:GraphCalls.Count | Should -Be 3
            $script:GraphCalls.AsApp | Should -Not -Contain $true
            $Lists = $script:GraphCalls[0].Requests.url
            $Lists | Should -Contain '/deviceManagement/deviceCompliancePolicies?$expand=assignments,scheduledActionsForRule($expand=scheduledActionConfigurations)&$top=1000'
            $Lists | Should -Contain '/deviceManagement/configurationPolicies?$expand=assignments,settings&$top=1000'
            $script:GraphCalls[1].Requests.url | Should -Contain "/deviceAppManagement/iosManagedAppProtections('ios1')?`$expand=apps,assignments"
            $script:GraphCalls[1].Requests.url | Should -Contain '/deviceManagement/deviceManagementScripts/s1'
            $script:GraphCalls[2].Requests.url | Should -Contain "/deviceManagement/groupPolicyConfigurations('gp1')/definitionValues('dv-gp1')/presentationValues?`$expand=presentation"

            $Result.Sections.Count | Should -Be 16
            $Result.Sections['groupPolicyConfigurations'][0].definitionValues[0].presentationValues[0].value | Should -Be 'x'
            $Result.Sections['intents'][0].settings[0].definitionId | Should -Be 'd1'
            $Result.Sections['deviceManagementScripts'][0].scriptContent | Should -Be 'abc'
            $Result.Sections['deviceManagementScripts'][0].assignments[0].id | Should -Be 'a1'
            $Ios = $Result.Sections['managedAppPolicies'].Where({ $_.id -eq 'ios1' })[0]
            $Ios.'@odata.type' | Should -Be '#microsoft.graph.iosManagedAppProtection'
            $Ios.PSObject.Properties['apps'] | Should -Not -BeNullOrEmpty
            $Result.Sections['managedAppPolicies'].id | Should -Contain 'def1'
            Should -Invoke Get-CIPPOmaSettingDecryptedValue -Times 1
            $Result.Warnings | Should -BeLike 'Intune configuration profiles: encrypted OMA-URI values could not be read for Config*'
        }

        It 'masks encrypted OMA-URI values without decrypting them unless secrets are included' {
            Mock Get-CIPPOmaSettingDecryptedValue { }
            $Result = Get-CIPPCloudBackupConfigData -TenantFilter $script:Tenant -Area Intune

            Should -Invoke Get-CIPPOmaSettingDecryptedValue -Times 0 -Exactly
            $Result.Sections['deviceConfigurations'][0].omaSettings[0].value | Should -Be '(encrypted)'
            $Result.Warnings | Should -Contain "Intune configuration profiles: encrypted OMA-URI values in Config were not backed up because this backup policy doesn't use encryption; turn on encryption to back them up"
        }

        It 'leaves out an item whose details failed and keeps the rest of the section' {
            $script:FailIds = @('presentationValues:gp2:dv-gp2')
            $Result = Get-CIPPCloudBackupConfigData -TenantFilter $script:Tenant -Area Intune

            $Result.Sections['groupPolicyConfigurations'].id | Should -Be @('gp1')
            $Result.Warnings | Should -Contain 'Intune administrative templates: 1 item(s) left out because their details could not be read (GP Two): denied presentationValues:gp2:dv-gp2'
        }

        It 'leaves out a failing list section' {
            $script:FailIds = @('roleScopeTags')
            $Result = Get-CIPPCloudBackupConfigData -TenantFilter $script:Tenant -Area Intune
            $Result.Sections.Contains('roleScopeTags') | Should -BeFalse
            $Result.Warnings | Should -Contain 'Intune scope tags: denied roleScopeTags'
        }
    }

    Context 'Exchange' {
        BeforeEach {
            $script:ExoCalls = [System.Collections.Generic.List[object]]::new()
            $script:ExoFail = @()
            Mock New-ExoRequest {
                [pscustomobject]@{ Value = @([pscustomobject]@{ UserPrincipalName = 'a@contoso.com'; DisplayName = 'A' }) }
                [pscustomobject]@{ Value = @([pscustomobject]@{ UserPrincipalName = 'b@contoso.com'; DisplayName = 'B' }) }
            }
            Mock New-ExoBulkRequest {
                $script:ExoCalls.Add([pscustomobject]@{ Cmdlets = @($cmdletArray); Select = $Select; TenantId = $tenantid })
                foreach ($Cmd in $cmdletArray) {
                    $Guid = $Cmd.OperationGuid
                    if ($Guid -in $script:ExoFail) { [pscustomobject]@{ error = "failed $Guid"; target = $null; OperationGuid = $Guid }; continue }
                    switch -Wildcard ($Guid) {
                        'DistributionGroups' { [pscustomobject]@{ Guid = 'g1'; DisplayName = 'Sales'; OperationGuid = $Guid } }
                        'DistributionGroupMembers:*' { [pscustomobject]@{ PrimarySmtpAddress = 'a@contoso.com'; OperationGuid = $Guid } }
                        'MailboxPermissions:*' {
                            [pscustomobject]@{ User = 'NT AUTHORITY\SELF'; AccessRights = @('FullAccess'); IsInherited = $false; OperationGuid = $Guid }
                            [pscustomobject]@{ User = 'admin@contoso.com'; AccessRights = @('FullAccess'); IsInherited = $true; OperationGuid = $Guid }
                            [pscustomobject]@{ User = 'delegate@contoso.com'; AccessRights = @('FullAccess'); IsInherited = $false; OperationGuid = $Guid }
                        }
                        'RecipientPermissions' {
                            [pscustomobject]@{ Trustee = 'NT AUTHORITY\SELF'; IsInherited = $false; OperationGuid = $Guid }
                            [pscustomobject]@{ Trustee = 'sender@contoso.com'; IsInherited = $false; OperationGuid = $Guid }
                        }
                        'TransportRules' { [pscustomobject]@{ Success = $true; OperationGuid = $Guid } }
                        default { [pscustomobject]@{ Name = $Guid; OperationGuid = $Guid } }
                    }
                }
            }
        }

        It 'reads configuration, mailboxes, permissions and group members' {
            Mock Test-CIPPStandardLicense { $false } -ParameterFilter { $Preset -eq 'DefenderForOffice365' }
            $Result = Get-CIPPCloudBackupConfigData -TenantFilter $script:Tenant -Area Exchange

            Should -Invoke New-ExoRequest -Times 1 -ParameterFilter { $cmdlet -eq 'Get-Mailbox' -and $cmdParams.ResultSize -eq 'Unlimited' -and $StreamPages -and $Select -match 'GrantSendOnBehalfTo' -and $tenantid -eq $script:Tenant }
            $script:ExoCalls.Count | Should -Be 3
            $Config = $script:ExoCalls[0].Cmdlets
            $Config.CmdletInput.CmdletName | Should -Contain 'Get-HostedContentFilterRule'
            $Config.CmdletInput.CmdletName | Should -Not -Contain 'Get-SafeLinksPolicy'
            $Config.Where({ $_.OperationGuid -eq 'TransportRules' })[0].CmdletInput.Parameters.ResultSize | Should -Be 'Unlimited'
            $Config.Where({ $_.OperationGuid -eq 'RecipientPermissions' })[0].CmdletInput.Parameters.AccessRights | Should -Be 'SendAs'
            $script:ExoCalls[1].Cmdlets[0].CmdletInput.CmdletName | Should -Be 'Get-DistributionGroupMember'
            $script:ExoCalls[2].Cmdlets.CmdletInput.Parameters.Identity | Should -Be @('a@contoso.com', 'b@contoso.com')
            $script:ExoCalls[2].Select | Should -Match 'IsInherited'

            $Result.Sections.Contains('SafeLinksPolicy') | Should -BeFalse
            $Result.Warnings | Should -Be @('Exchange Safe Links and Safe Attachments were skipped: the tenant is not licensed for Defender for Office 365')
            $Result.Sections['OrganizationConfig'][0].Name | Should -Be 'OrganizationConfig'
            $Result.Sections['OrganizationConfig'][0].PSObject.Properties['OperationGuid'] | Should -BeNullOrEmpty
            $Result.Sections['TransportRules'].Count | Should -Be 0
            $Result.Sections['Mailboxes'].Count | Should -Be 2
            $Result.Sections['MailboxPermissions'].User | Should -Be @('delegate@contoso.com', 'delegate@contoso.com')
            $Result.Sections['RecipientPermissions'].Trustee | Should -Be @('sender@contoso.com')
            $Result.Sections['DistributionGroups'][0].Members[0].PrimarySmtpAddress | Should -Be 'a@contoso.com'
        }

        It 'includes Safe Links and Safe Attachments when licensed' {
            $Result = Get-CIPPCloudBackupConfigData -TenantFilter $script:Tenant -Area Exchange
            $Result.Sections.Contains('SafeAttachmentRule') | Should -BeTrue
            $Result.Warnings.Count | Should -Be 0
        }

        It 'leaves out failing sections, groups and reports unread mailboxes' {
            $script:ExoFail = @('AntiPhishPolicy', 'DistributionGroupMembers:g1', 'MailboxPermissions:b@contoso.com')
            $Result = Get-CIPPCloudBackupConfigData -TenantFilter $script:Tenant -Area Exchange

            $Result.Sections.Contains('AntiPhishPolicy') | Should -BeFalse
            $Result.Sections['DistributionGroups'].Count | Should -Be 0
            $Result.Sections['MailboxPermissions'].Count | Should -Be 1
            $Result.Warnings | Should -Contain 'Exchange anti-phishing policies: failed AntiPhishPolicy'
            $Result.Warnings | Should -Contain 'Exchange mailbox permissions: permissions of 1 mailbox(es) could not be read (b@contoso.com): failed MailboxPermissions:b@contoso.com'
            $Result.Warnings | Should -Contain 'Exchange distribution lists: 1 group(s) left out because their members could not be read (Sales): failed DistributionGroupMembers:g1'
        }

        It 'throws when every section failed' {
            Mock New-ExoRequest { throw 'EXO is down' }
            Mock New-ExoBulkRequest { }
            { Get-CIPPCloudBackupConfigData -TenantFilter $script:Tenant -Area Exchange } | Should -Throw '*Every Exchange section failed*EXO is down*'
        }
    }

    Context 'SharePoint' {
        BeforeEach {
            Mock New-GraphGetRequest { [pscustomobject]@{ sharingCapability = 'externalUserSharingOnly' } }
            Mock Get-CIPPSPOTenant { [pscustomobject]@{ SharingCapability = 1 } }
            Mock Get-CIPPSPOSite { [pscustomobject]@{ Url = 'https://contoso.sharepoint.com/sites/a' }; [pscustomobject]@{ Url = 'https://contoso.sharepoint.com/sites/b' } }
        }

        It 'reads tenant settings app-only and every site with the certificate' {
            $Result = Get-CIPPCloudBackupConfigData -TenantFilter $script:Tenant -Area SharePoint

            Should -Invoke New-GraphGetRequest -Times 1 -ParameterFilter { $uri -eq 'https://graph.microsoft.com/beta/admin/sharepoint/settings' -and $AsApp -eq $true -and $tenantid -eq $script:Tenant }
            Should -Invoke Get-CIPPSPOTenant -Times 1 -ParameterFilter { $SkipCache -and $UseCertificate }
            Should -Invoke Get-CIPPSPOSite -Times 1 -ParameterFilter { $UseCertificate }
            @($Result.Sections.Keys) | Should -Be @('tenantSettings', 'spoTenantSettings', 'sites')
            $Result.Sections['sites'].Count | Should -Be 2
            $Result.Sections['tenantSettings'].Count | Should -Be 1
        }

        It 'leaves out a failing section with a warning' {
            Mock Get-CIPPSPOSite { throw 'SharePoint admin access denied' }
            $Result = Get-CIPPCloudBackupConfigData -TenantFilter $script:Tenant -Area SharePoint
            $Result.Sections.Contains('sites') | Should -BeFalse
            $Result.Warnings | Should -Be @('SharePoint sites: SharePoint admin access denied')
        }

        It 'throws when every section failed' {
            Mock New-GraphGetRequest { throw 'no' }
            Mock Get-CIPPSPOTenant { throw 'no' }
            Mock Get-CIPPSPOSite { throw 'no' }
            { Get-CIPPCloudBackupConfigData -TenantFilter $script:Tenant -Area SharePoint } | Should -Throw '*Every SharePoint section failed*'
        }
    }

    Context 'References' {
        BeforeEach {
            $script:LookupBodies = [System.Collections.Generic.List[object]]::new()
            Mock New-GraphPOSTRequest {
                $script:LookupBodies.Add(($body | ConvertFrom-Json))
                [pscustomobject]@{ value = @(
                        [pscustomobject]@{ '@odata.type' = '#microsoft.graph.group'; id = '11111111-0000-0000-0000-000000000001'; displayName = 'Sales' }
                        [pscustomobject]@{ '@odata.type' = '#microsoft.graph.user'; id = '22222222-0000-0000-0000-000000000001'; displayName = 'Jane'; userPrincipalName = 'jane@contoso.com' }
                    )
                }
            }
        }

        It 'resolves the groups and users Conditional Access policies use in one app-only lookup' {
            $script:GraphBody = {
                param($Request)
                if ($Request.id -ne 'policies') { return [pscustomobject]@{ value = @() } }
                [pscustomobject]@{ value = @(
                        [pscustomobject]@{ id = 'p1'; conditions = [pscustomobject]@{ users = [pscustomobject]@{ includeGroups = @('11111111-0000-0000-0000-000000000001'); excludeGroups = @('11111111-0000-0000-0000-000000000009'); includeUsers = @('All'); excludeUsers = @('22222222-0000-0000-0000-000000000001', 'GuestsOrExternalUsers') } } }
                        [pscustomobject]@{ id = 'p2'; conditions = [pscustomobject]@{ users = [pscustomobject]@{ includeGroups = @('11111111-0000-0000-0000-000000000001') } } }
                    )
                }
            }
            $Result = Get-CIPPCloudBackupConfigData -TenantFilter $script:Tenant -Area ConditionalAccess

            Should -Invoke New-GraphPOSTRequest -Times 1 -Exactly -ParameterFilter { $uri -like 'https://graph.microsoft.com/v1.0/directoryObjects/getByIds*' -and $tenantid -eq $script:Tenant -and $AsApp -eq $true }
            @($script:LookupBodies[0].ids | Sort-Object) | Should -Be @('11111111-0000-0000-0000-000000000001', '11111111-0000-0000-0000-000000000009', '22222222-0000-0000-0000-000000000001')
            $Result.References.Groups['11111111-0000-0000-0000-000000000001'] | Should -Be 'Sales'
            $Result.References.Groups.Count | Should -Be 1
            $Result.References.Users['22222222-0000-0000-0000-000000000001'] | Should -Be 'jane@contoso.com'
            $Result.Warnings.Count | Should -Be 0
        }

        It 'resolves the groups Intune assignments target' {
            $script:GraphBody = {
                param($Request)
                switch ($Request.id) {
                    'configurationPolicies' { [pscustomobject]@{ value = @([pscustomobject]@{ id = 'c1'; assignments = @([pscustomobject]@{ target = [pscustomobject]@{ groupId = '11111111-0000-0000-0000-000000000001' } }, [pscustomobject]@{ target = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.allDevicesAssignmentTarget' } }) }) } }
                    'deviceCompliancePolicies' { [pscustomobject]@{ value = @([pscustomobject]@{ id = 'd1'; assignments = @([pscustomobject]@{ target = [pscustomobject]@{ groupId = '11111111-0000-0000-0000-000000000001' } }) }) } }
                    default { [pscustomobject]@{ value = @() } }
                }
            }
            $Result = Get-CIPPCloudBackupConfigData -TenantFilter $script:Tenant -Area Intune

            Should -Invoke New-GraphPOSTRequest -Times 1 -Exactly -ParameterFilter { $AsApp -eq $false }
            @($script:LookupBodies[0].ids) | Should -Be @('11111111-0000-0000-0000-000000000001')
            @($script:LookupBodies[0].types) | Should -Be @('group', 'user')
            $Result.References.Groups['11111111-0000-0000-0000-000000000001'] | Should -Be 'Sales'
        }

        It 'skips the lookup when nothing is referenced' {
            $Result = Get-CIPPCloudBackupConfigData -TenantFilter $script:Tenant -Area ConditionalAccess
            Should -Invoke New-GraphPOSTRequest -Times 0 -Exactly
            $Result.References.Groups.Count | Should -Be 0
            $Result.References.Users.Count | Should -Be 0
        }

        It 'keeps the sections and warns when the names cannot be read' {
            Mock New-GraphPOSTRequest { throw 'Insufficient privileges' }
            $script:GraphBody = {
                param($Request)
                [pscustomobject]@{ value = @([pscustomobject]@{ id = "$($Request.id)-1"; conditions = [pscustomobject]@{ users = [pscustomobject]@{ includeGroups = @('11111111-0000-0000-0000-000000000001') } } }) }
            }
            $Result = Get-CIPPCloudBackupConfigData -TenantFilter $script:Tenant -Area ConditionalAccess
            $Result.Sections['policies'].Count | Should -Be 1
            $Result.References.Groups.Count | Should -Be 0
            $Result.Warnings | Should -Be @('Conditional Access: the names of the groups and users it uses could not be read, so a restore to another tenant will not map them: Insufficient privileges')
        }

        It 'returns empty references for <Area>' -TestCases @(@{ Area = 'SharePoint' }, @{ Area = 'Exchange' }) {
            Mock New-GraphGetRequest { [pscustomobject]@{ a = 1 } }
            Mock Get-CIPPSPOTenant { [pscustomobject]@{ a = 1 } }
            Mock Get-CIPPSPOSite { }
            Mock New-ExoRequest { }
            Mock New-ExoBulkRequest { }
            $Result = Get-CIPPCloudBackupConfigData -TenantFilter $script:Tenant -Area $Area
            $Result.References.Groups.Count | Should -Be 0
            $Result.References.Users.Count | Should -Be 0
            Should -Invoke New-GraphPOSTRequest -Times 0 -Exactly
        }

        It 'returns empty references when the tenant is not licensed' {
            Mock Test-CIPPStandardLicense { $false }
            (Get-CIPPCloudBackupConfigData -TenantFilter $script:Tenant -Area Intune).References.Groups.Count | Should -Be 0
        }
    }
}
