BeforeAll {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    . (Join-Path $RepoRoot 'Modules/CIPPCore/Public/CloudBackup/Restore-CIPPCloudBackupExchange.ps1')

    function Get-Tenants { param([switch]$IncludeErrors, [string]$TenantFilter) }
    function Get-NormalizedError { param($Message) $Message }
    function Get-CIPPCloudBackupSectionLabel { param($Section) "Label $Section" }
    function Get-CIPPCloudBackupItemInfo {
        param($Section, $Item)
        foreach ($Row in $Item) {
            $Key = switch ($Section) {
                'OrganizationConfig' { 'OrganizationConfig' }
                'MailboxPermissions' { "$($Row.Identity)|$($Row.User)|$(@($Row.AccessRights) -join ',')" }
                'RecipientPermissions' { "$($Row.Identity)|$($Row.Trustee)|$(@($Row.AccessRights) -join ',')" }
                default { $Row.Guid ?? $Row.ExchangeObjectId ?? $Row.Identity ?? $Row.Name }
            }
            [pscustomobject]@{ Key = $Key; Name = $Row.DisplayName ?? $Row.Name ?? $Row.Identity ?? $Key }
        }
    }
    function New-ExoRequest { param($tenantid, $cmdlet, $cmdParams, $Select, [switch]$StreamPages) }
    function New-ExoBulkRequest { param($tenantid, $cmdletArray, $Select, $MaxConcurrency, [switch]$AnchorPerMailbox) }

    $script:Source = '11111111-1111-1111-1111-111111111111'
    $script:Target = 'contoso.onmicrosoft.com'

    function script:Invoke-Restore {
        param($Sections, $ConflictAction = 'Overwrite', [switch]$Apply, $Items)
        $Splat = @{ Snapshot = [pscustomobject]@{ Sections = $Sections; References = @{} }; SourceTenantId = $script:Source; TargetTenantFilter = $script:Target; ConflictAction = $ConflictAction; Apply = $Apply }
        if ($null -ne $Items) { $Splat['Items'] = $Items }
        @(Restore-CIPPCloudBackupExchange @Splat)
    }
    function script:Get-WriteCall { @($script:BulkCalls.Where({ -not $_.Read })) }
    function script:Get-SentParameter { param($Cmdlet) @(foreach ($Call in $script:BulkCalls) { foreach ($Op in $Call.Ops) { if ($Op.CmdletInput.CmdletName -eq $Cmdlet) { $Op.CmdletInput.Parameters } } }) }
}

Describe 'Restore-CIPPCloudBackupExchange' {
    BeforeEach {
        $script:TargetCustomerId = $script:Source
        $script:Live = @{}
        $script:LivePerms = @{}
        $script:LiveMembers = @{}
        $script:LiveMailboxes = @()
        $script:FailCmdlets = @()
        $script:BulkCalls = [System.Collections.Generic.List[object]]::new()
        $script:ExoCalls = [System.Collections.Generic.List[object]]::new()

        Mock Get-Tenants { [pscustomobject]@{ customerId = $script:TargetCustomerId; defaultDomainName = $script:Target } }
        Mock New-ExoRequest {
            $script:ExoCalls.Add([pscustomobject]@{ Cmdlet = $cmdlet; TenantId = $tenantid })
            @{ Value = $script:LiveMailboxes }
        }
        Mock New-ExoBulkRequest {
            $Ops = @($cmdletArray)
            $IsRead = @($Ops.Where({ -not $_.CmdletInput.CmdletName.StartsWith('Get-') })).Count -eq 0
            $script:BulkCalls.Add([pscustomobject]@{ Ops = $Ops; Read = $IsRead; Anchor = [bool]$AnchorPerMailbox; TenantId = $tenantid })
            foreach ($Op in $Ops) {
                $Name = $Op.CmdletInput.CmdletName
                $Guid = $Op.OperationGuid
                if ($Name.StartsWith('Get-')) {
                    $Rows = if ($Guid.StartsWith('MailboxPermissions:')) { $script:LivePerms[$Guid.Substring(19)] } elseif ($Guid.StartsWith('Members:')) { $script:LiveMembers[$Guid.Substring(8)] } else { $script:Live[$Guid] }
                    if (@($Rows).Count -eq 0) { [pscustomobject]@{ Success = $true; OperationGuid = $Guid } }
                    foreach ($Row in $Rows) { $Copy = $Row.PSObject.Copy(); $Copy | Add-Member -NotePropertyName OperationGuid -NotePropertyValue $Guid -Force; $Copy }
                } elseif ($Name -in $script:FailCmdlets) {
                    [pscustomobject]@{ error = "$Name refused"; target = $null; OperationGuid = $Guid }
                } else {
                    [pscustomobject]@{ Success = $true; OperationGuid = $Guid }
                }
            }
        }
    }

    Context 'preview' {
        It 'makes no writes and reports every item as planned or skipped' {
            $script:Live['HostedContentFilterPolicy'] = @([pscustomobject]@{ Name = 'Strict'; Guid = 'p-live'; Identity = 'Strict'; SpamAction = 'Quarantine' })
            $script:Live['HostedContentFilterRule'] = @()
            $script:Live['OrganizationConfig'] = @([pscustomobject]@{ Name = 'contoso'; Identity = 'contoso'; FocusedInboxOn = $false })
            $script:Live['RecipientPermissions'] = @()
            $script:LiveMailboxes = @([pscustomobject]@{ ExchangeGuid = 'eg1'; Guid = 'mb1'; UserPrincipalName = 'a@contoso.com'; Identity = 'a'; MailTip = $null })
            $script:LivePerms['a'] = @()
            $Sections = [ordered]@{
                OrganizationConfig        = @([pscustomobject]@{ Name = 'contoso'; FocusedInboxOn = $true })
                HostedContentFilterPolicy = @([pscustomobject]@{ Name = 'Strict'; Guid = 'p-live'; SpamAction = 'MoveToJmf' }, [pscustomobject]@{ Name = 'New one'; Guid = 'p2'; SpamAction = 'Quarantine' })
                HostedContentFilterRule   = @([pscustomobject]@{ Name = 'New rule'; Guid = 'r2'; HostedContentFilterPolicy = 'New one'; State = 'Enabled'; Priority = 0 })
                Mailboxes                 = @([pscustomobject]@{ ExchangeGuid = 'eg1'; Guid = 'mb1'; UserPrincipalName = 'a@contoso.com'; Name = 'a'; MailTip = 'Hi' })
                MailboxPermissions        = @([pscustomobject]@{ Identity = 'a'; User = 'b@contoso.com'; AccessRights = @('FullAccess'); Deny = $false })
                RecipientPermissions      = @([pscustomobject]@{ Identity = 'a'; Trustee = 'b@contoso.com'; AccessRights = @('SendAs') })
            }

            $Result = Invoke-Restore -Sections $Sections

            @(Get-WriteCall).Count | Should -Be 0
            foreach ($Call in $script:BulkCalls) { foreach ($Op in $Call.Ops) { $Op.CmdletInput.CmdletName | Should -Match '^Get-' } }
            foreach ($Call in $script:ExoCalls) { $Call.Cmdlet | Should -Be 'Get-Mailbox' }
            foreach ($Call in $script:BulkCalls) { $Call.TenantId | Should -Be $script:Target }
            $Result.Count | Should -Be 7
            @($Result.Where({ $_.Action -in 'Create', 'Update' }).Status | Select-Object -Unique) | Should -Be @('Planned')
            $Result.Where({ $_.Section -eq 'HostedContentFilterRule' })[0].Action | Should -Be 'Create'
            $Result.Where({ $_.Section -eq 'OrganizationConfig' })[0].Message | Should -Match 'FocusedInboxOn'
        }

        It 'restricts the plan to the selected items' {
            $script:Live['InboundConnectors'] = @()
            $Sections = [ordered]@{ InboundConnectors = @([pscustomobject]@{ Name = 'A'; Guid = 'c1' }, [pscustomobject]@{ Name = 'B'; Guid = 'c2' }) }
            $Result = Invoke-Restore -Sections $Sections -Items @(@{ Area = 'Exchange'; Section = 'InboundConnectors'; Key = 'c2' })
            $Result.Count | Should -Be 1
            $Result[0].Name | Should -Be 'B'
        }
    }

    Context 'allow-lists' {
        It 'sends only settable parameters when creating a policy' {
            $script:Live['HostedContentFilterPolicy'] = @()
            $Policy = [pscustomobject]@{
                Name = 'Custom'; Guid = 'p1'; Identity = 'Custom'; DistinguishedName = 'CN=Custom'; WhenChanged = [datetime]'2026-01-01'; IsValid = $true
                ExchangeVersion = '0.1'; SpamAction = 'Quarantine'; EndUserSpamNotificationFrequency = 3; DownloadLink = $false; RecommendedPolicyType = 'Custom'
                AllowedSenders = @('x@fabrikam.com'); BlockedSenders = @(); IntraOrgFilterState = 'Default'; AddXHeaderValue = $null
            }
            Invoke-Restore -Sections ([ordered]@{ HostedContentFilterPolicy = @($Policy) }) -Apply | Out-Null

            $Params = @(Get-SentParameter 'New-HostedContentFilterPolicy')
            $Params.Count | Should -Be 1
            @($Params[0].Keys | Sort-Object) | Should -Be @('AllowedSenders', 'IntraOrgFilterState', 'Name', 'SpamAction')
            $Params[0].IntraOrgFilterState | Should -Be 'HighConfidencePhish'
            @($Params[0].AllowedSenders) | Should -Be @('x@fabrikam.com')
        }

        It 'updates organization settings one changed setting at a time and leaves out unsupported ones' {
            $script:Live['OrganizationConfig'] = @([pscustomobject]@{ Name = 'contoso'; Identity = 'contoso'; FocusedInboxOn = $false; AuditDisabled = $false; OAuth2ClientProfileEnabled = $true })
            $Backup = [pscustomobject]@{ Name = 'contoso'; FocusedInboxOn = $true; AuditDisabled = $false; OAuth2ClientProfileEnabled = $false; AutoExpandingArchive = $true; CustomerLockboxEnabled = $true; IsDehydrated = $false; Guid = 'org' }

            $Result = Invoke-Restore -Sections ([ordered]@{ OrganizationConfig = @($Backup) }) -Apply

            $Params = @(Get-SentParameter 'Set-OrganizationConfig')
            $Params.Count | Should -Be 2
            @($Params.ForEach({ @($_.Keys) })) | Sort-Object | Should -Be @('FocusedInboxOn', 'OAuth2ClientProfileEnabled')
            $Result[0].Action | Should -Be 'Update'
            $Result[0].Status | Should -Be 'Succeeded'
        }

        It 'never sends mailbox identity, address or archive properties' {
            $script:LiveMailboxes = @([pscustomobject]@{ ExchangeGuid = 'eg1'; Guid = 'mb1'; UserPrincipalName = 'a@contoso.com'; RetainDeletedItemsFor = '14.00:00:00'; ProhibitSendQuota = '49 GB (52,613,349,376 bytes)' })
            $Backup = [pscustomobject]@{
                ExchangeGuid = 'eg1'; Guid = 'mb1'; UserPrincipalName = 'a@contoso.com'; DisplayName = 'Changed'; Alias = 'changed'; EmailAddresses = @('SMTP:x@contoso.com')
                PrimarySmtpAddress = 'x@contoso.com'; ArchiveStatus = 'Active'; AutoExpandingArchiveEnabled = $true; MailboxPlan = 'plan'; EmailAddressPolicyEnabled = $false
                RetainDeletedItemsFor = '30.00:00:00'; ProhibitSendQuota = '49 GB (52,613,349,376 bytes)'; IssueWarningQuota = '40 GB (42,949,672,960 bytes)'
            }
            Invoke-Restore -Sections ([ordered]@{ Mailboxes = @($Backup) }) -Apply | Out-Null

            $Params = @(Get-SentParameter 'Set-Mailbox')
            $Params.Count | Should -Be 1
            @($Params[0].Keys | Sort-Object) | Should -Be @('Identity', 'IssueWarningQuota', 'RetainDeletedItemsFor')
            $Params[0].Identity | Should -Be 'a@contoso.com'
            $Params[0].IssueWarningQuota | Should -Be '42949672960'
            $script:BulkCalls.Where({ -not $_.Read })[0].Anchor | Should -BeTrue
        }

        It 'never switches litigation hold off and adds send-on-behalf delegates without replacing them' {
            $script:LiveMailboxes = @([pscustomobject]@{ ExchangeGuid = 'eg1'; Guid = 'mb1'; UserPrincipalName = 'a@contoso.com'; LitigationHoldEnabled = $true; GrantSendOnBehalfTo = @('carol') })
            $Backup = [pscustomobject]@{ ExchangeGuid = 'eg1'; Guid = 'mb1'; UserPrincipalName = 'a@contoso.com'; LitigationHoldEnabled = $false; GrantSendOnBehalfTo = @('bob') }

            $Result = Invoke-Restore -Sections ([ordered]@{ Mailboxes = @($Backup) }) -Apply

            $Params = @(Get-SentParameter 'Set-Mailbox')
            $Params[0].ContainsKey('LitigationHoldEnabled') | Should -BeFalse
            $Params[0].GrantSendOnBehalfTo.Add | Should -Be @('bob')
            $Params[0].GrantSendOnBehalfTo.'@odata.type' | Should -Be '#Exchange.GenericHashTable'
            $Result[0].Message | Should -Match 'Litigation hold'
        }
    }

    Context 'conflicts' {
        BeforeEach {
            $script:Live['OutboundConnectors'] = @([pscustomobject]@{ Name = 'Smarthost'; Guid = 'c1'; Identity = 'Smarthost'; Enabled = $true; SmartHosts = @('a.example.com') })
            $script:Sections = [ordered]@{ OutboundConnectors = @(
                    [pscustomobject]@{ Name = 'Smarthost'; Guid = 'c1'; Enabled = $false; SmartHosts = @('a.example.com'); IsValidated = $true; LastValidationTimestamp = [datetime]'2026-01-01' }
                    [pscustomobject]@{ Name = 'Gone'; Guid = 'c2'; Enabled = $true }
                )
            }
        }

        It 'updates the matched item and creates the missing one on Overwrite' {
            $Result = Invoke-Restore -Sections $script:Sections -ConflictAction Overwrite -Apply
            $Set = @(Get-SentParameter 'Set-OutboundConnector')
            $Set.Count | Should -Be 1
            @($Set[0].Keys | Sort-Object) | Should -Be @('Enabled', 'Identity')
            $Set[0].Identity | Should -Be 'Smarthost'
            @(Get-SentParameter 'New-OutboundConnector')[0].Name | Should -Be 'Gone'
            $Result.Action | Should -Be @('Update', 'Create')
            $Result.Status | Should -Be @('Succeeded', 'Succeeded')
        }

        It 'skips the existing item on Skip' {
            $Result = Invoke-Restore -Sections $script:Sections -ConflictAction Skip -Apply
            @(Get-SentParameter 'Set-OutboundConnector').Count | Should -Be 0
            $Result[0].Action | Should -Be 'Skip'
            $Result[0].Status | Should -Be 'Skipped'
            $Result[1].Action | Should -Be 'Create'
        }

        It 'creates a renamed copy on Copy' {
            $Result = Invoke-Restore -Sections $script:Sections -ConflictAction Copy -Apply
            $New = @(Get-SentParameter 'New-OutboundConnector')
            $New[0].Name | Should -BeLike 'Smarthost (restored ????-??-??)'
            $New[0].Enabled | Should -BeFalse
            $Result[0].Action | Should -Be 'CreateCopy'
        }

        It 'creates a copied connector disabled even when the backup was enabled' {
            $script:Sections.OutboundConnectors[0].Enabled = $true
            $script:Live['InboundConnectors'] = @([pscustomobject]@{ Name = 'Partner'; Guid = 'ic'; Identity = 'Partner'; Enabled = $true })
            $script:Sections['InboundConnectors'] = @([pscustomobject]@{ Name = 'Partner'; Guid = 'ic'; Enabled = $true; SenderDomains = @('partner.com') })
            $Result = Invoke-Restore -Sections $script:Sections -ConflictAction Copy -Apply
            @(Get-SentParameter 'New-OutboundConnector')[0].Enabled | Should -BeFalse
            @(Get-SentParameter 'New-InboundConnector')[0].Enabled | Should -BeFalse
            $Result.Where({ $_.Key -eq 'c1' })[0].Message | Should -Match '^Created as a disabled copy'
            $Result.Where({ $_.Key -eq 'ic' })[0].Message | Should -Match '^Created as a disabled copy'
            @(Get-SentParameter 'New-OutboundConnector').Where({ $_.Name -eq 'Gone' })[0].Enabled | Should -BeTrue
        }

        It 'skips an item that already matches the backup' {
            $script:Live['OutboundConnectors'][0].Enabled = $false
            $Result = Invoke-Restore -Sections $script:Sections -ConflictAction Overwrite
            $Result[0].Action | Should -Be 'Skip'
            $Result[0].Message | Should -Match 'Already matches'
        }
    }

    Context 'policies and rules' {
        BeforeEach {
            $script:Live['AntiPhishPolicy'] = @([pscustomobject]@{ Name = 'Office365 AntiPhish Default'; Guid = 'def'; Identity = 'Office365 AntiPhish Default'; IsDefault = $true; EnableSpoofIntelligence = $true })
            $script:Live['AntiPhishRule'] = @()
            $script:Sections = [ordered]@{
                AntiPhishRule   = @([pscustomobject]@{ Name = 'Exec rule'; Guid = 'r1'; AntiPhishPolicy = 'Exec'; State = 'Disabled'; Priority = 3; SentToMemberOf = @('Execs') })
                AntiPhishPolicy = @(
                    [pscustomobject]@{ Name = 'Office365 AntiPhish Default'; Guid = 'srcdef'; IsDefault = $true; EnableSpoofIntelligence = $false }
                    [pscustomobject]@{ Name = 'Exec'; Guid = 'p1'; EnableSpoofIntelligence = $true; Enabled = $true; PolicyTag = 'x' }
                )
            }
        }

        It 'creates the policy before the rule that references it' {
            $Result = Invoke-Restore -Sections $script:Sections -Apply
            $Writes = @(Get-WriteCall)
            $PolicyCall = $Writes.IndexOf(@($Writes.Where({ $_.Ops.CmdletInput.CmdletName -contains 'New-AntiPhishPolicy' }))[0])
            $RuleCall = $Writes.IndexOf(@($Writes.Where({ $_.Ops.CmdletInput.CmdletName -contains 'New-AntiPhishRule' }))[0])
            $PolicyCall | Should -BeLessThan $RuleCall
            $Rule = @(Get-SentParameter 'New-AntiPhishRule')[0]
            $Rule.AntiPhishPolicy | Should -Be 'Exec'
            $Rule.Enabled | Should -BeFalse
            $Rule.ContainsKey('Priority') | Should -BeFalse
            @(Get-SentParameter 'New-AntiPhishPolicy')[0].ContainsKey('PolicyTag') | Should -BeFalse
            @(Get-SentParameter 'New-AntiPhishPolicy')[0].ContainsKey('Enabled') | Should -BeFalse
            $Result.Where({ $_.Section -eq 'AntiPhishRule' })[0].Status | Should -Be 'Succeeded'
        }

        It 'updates a default policy in place and never creates one' {
            $Result = Invoke-Restore -Sections $script:Sections -Apply
            @(Get-SentParameter 'New-AntiPhishPolicy').Name | Should -Not -Contain 'Office365 AntiPhish Default'
            $Set = @(Get-SentParameter 'Set-AntiPhishPolicy')[0]
            $Set.Identity | Should -Be 'Office365 AntiPhish Default'
            $Set.EnableSpoofIntelligence | Should -BeFalse
            $Result.Where({ $_.Key -eq 'srcdef' })[0].Action | Should -Be 'Update'
        }

        It 'refuses to create a default policy the target lacks and to copy a default policy' {
            $script:Live['AntiPhishPolicy'] = @()
            $Result = Invoke-Restore -Sections $script:Sections -Apply
            $Result.Where({ $_.Key -eq 'srcdef' })[0].Action | Should -Be 'NotRestorable'

            $script:Live['AntiPhishPolicy'] = @([pscustomobject]@{ Name = 'Office365 AntiPhish Default'; Guid = 'def'; Identity = 'Office365 AntiPhish Default'; IsDefault = $true })
            $Result = Invoke-Restore -Sections $script:Sections -ConflictAction Copy
            $Result.Where({ $_.Key -eq 'srcdef' })[0].Action | Should -Be 'Skip'
        }

        It 'points a copied rule at the copied policy' {
            $script:Live['AntiPhishPolicy'] += [pscustomobject]@{ Name = 'Exec'; Guid = 'p1'; Identity = 'Exec' }
            $script:Live['AntiPhishRule'] = @([pscustomobject]@{ Name = 'Exec rule'; Guid = 'r1'; Identity = 'Exec rule'; AntiPhishPolicy = 'Exec'; State = 'Enabled'; Priority = 0 })
            Invoke-Restore -Sections $script:Sections -ConflictAction Copy -Apply | Out-Null
            $Rule = @(Get-SentParameter 'New-AntiPhishRule')[0]
            $Rule.Name | Should -BeLike 'Exec rule (restored *)'
            $Rule.AntiPhishPolicy | Should -BeLike 'Exec (restored *)'
        }

        It 'creates copied policy rules disabled' {
            $Sections = [ordered]@{}
            foreach ($Family in @(
                    @('HostedContentFilterPolicy', 'HostedContentFilterRule'), @('HostedOutboundSpamFilterPolicy', 'HostedOutboundSpamFilterRule'), @('AntiPhishPolicy', 'AntiPhishRule'),
                    @('MalwareFilterPolicy', 'MalwareFilterRule'), @('SafeLinksPolicy', 'SafeLinksRule'), @('SafeAttachmentPolicy', 'SafeAttachmentRule'))) {
                $script:Live[$Family[0]] = @([pscustomobject]@{ Name = 'P'; Guid = "$($Family[0])-p"; Identity = 'P' })
                $script:Live[$Family[1]] = @([pscustomobject]@{ Name = 'R'; Guid = "$($Family[1])-r"; Identity = 'R'; $Family[0] = 'P'; State = 'Enabled' })
                $Sections[$Family[0]] = @([pscustomobject]@{ Name = 'P'; Guid = "$($Family[0])-p" })
                $Sections[$Family[1]] = @([pscustomobject]@{ Name = 'R'; Guid = "$($Family[1])-r"; $Family[0] = 'P'; State = 'Enabled' })
            }
            $Result = Invoke-Restore -Sections $Sections -ConflictAction Copy -Apply
            foreach ($Rule in 'HostedContentFilterRule', 'HostedOutboundSpamFilterRule', 'AntiPhishRule', 'MalwareFilterRule', 'SafeLinksRule', 'SafeAttachmentRule') {
                $Sent = @(Get-SentParameter "New-$Rule")
                $Sent.Count | Should -Be 1
                $Sent[0].Enabled | Should -BeFalse
                $Result.Where({ $_.Section -eq $Rule })[0].Message | Should -Match '^Created as a disabled copy'
            }
        }

        It 'updates a rule and switches its state with the dedicated cmdlet' {
            $script:Live['AntiPhishPolicy'] += [pscustomobject]@{ Name = 'Exec'; Guid = 'p1'; Identity = 'Exec'; EnableSpoofIntelligence = $true }
            $script:Live['AntiPhishRule'] = @([pscustomobject]@{ Name = 'Exec rule'; Guid = 'r1'; Identity = 'Exec rule'; AntiPhishPolicy = 'Exec'; State = 'Enabled'; Priority = 0; SentToMemberOf = @('Execs') })
            Invoke-Restore -Sections $script:Sections -Apply | Out-Null
            @(Get-SentParameter 'Set-AntiPhishRule').Count | Should -Be 0
            @(Get-SentParameter 'Disable-AntiPhishRule')[0].Identity | Should -Be 'Exec rule'
        }

        It 'fails a rule without sending it when its new policy could not be created' {
            $script:FailCmdlets = @('New-AntiPhishPolicy')
            $Result = Invoke-Restore -Sections $script:Sections -Apply
            @(Get-SentParameter 'New-AntiPhishRule').Count | Should -Be 0
            $Rule = $Result.Where({ $_.Section -eq 'AntiPhishRule' })[0]
            $Rule.Status | Should -Be 'Failed'
            $Rule.Message | Should -Match "policy 'Exec' could not be restored"
            $Result.Where({ $_.Key -eq 'p1' })[0].Message | Should -Match 'New-AntiPhishPolicy refused'
            $Result.Where({ $_.Key -eq 'srcdef' })[0].Status | Should -Be 'Succeeded'
        }

        It 'leaves preset security policies and their rules alone' {
            $Sections = [ordered]@{
                SafeLinksPolicy = @([pscustomobject]@{ Name = 'Strict Preset Security Policy1'; Guid = 'sp'; RecommendedPolicyType = 'Strict' }, [pscustomobject]@{ Name = 'Built-In Protection Policy'; Guid = 'bi'; IsBuiltInProtection = $true })
                SafeLinksRule   = @([pscustomobject]@{ Name = 'Strict rule'; Guid = 'sr'; SafeLinksPolicy = 'Strict Preset Security Policy1'; State = 'Enabled' })
            }
            $script:Live['SafeLinksPolicy'] = @()
            $script:Live['SafeLinksRule'] = @()
            $Result = Invoke-Restore -Sections $Sections -Apply
            $Result.Action | Should -Be @('NotRestorable', 'NotRestorable', 'NotRestorable')
            @(Get-WriteCall).Count | Should -Be 0
        }
    }

    Context 'transport rules' {
        It 'creates with Enabled and updates priority within range' {
            $script:Live['TransportRules'] = @([pscustomobject]@{ Name = 'Disclaimer'; Guid = 't1'; Identity = 'Disclaimer'; State = 'Enabled'; Priority = 0; PrependSubject = 'old' })
            $Sections = [ordered]@{ TransportRules = @(
                    [pscustomobject]@{ Name = 'Disclaimer'; Guid = 't1'; State = 'Enabled'; Priority = 5; PrependSubject = 'new'; Description = 'If...'; RuleVersion = '15.0'; ExceptIfRecipientInSenderList = @('x') }
                    [pscustomobject]@{ Name = 'Block'; Guid = 't2'; State = 'Disabled'; Priority = 1; DeleteMessage = $true; UseLegacyRegex = $false }
                )
            }
            Invoke-Restore -Sections $Sections -Apply | Out-Null
            $Set = @(Get-SentParameter 'Set-TransportRule')[0]
            @($Set.Keys | Sort-Object) | Should -Be @('Identity', 'PrependSubject')
            $New = @(Get-SentParameter 'New-TransportRule')[0]
            @($New.Keys | Sort-Object) | Should -Be @('DeleteMessage', 'Enabled', 'Name')
            $New.Enabled | Should -BeFalse
        }

        It 'creates a copied mail flow rule disabled' {
            $script:Live['TransportRules'] = @([pscustomobject]@{ Name = 'Disclaimer'; Guid = 't1'; Identity = 'Disclaimer'; State = 'Enabled'; Priority = 0 })
            $Result = Invoke-Restore -Sections ([ordered]@{ TransportRules = @([pscustomobject]@{ Name = 'Disclaimer'; Guid = 't1'; State = 'Enabled'; PrependSubject = '[Ext]' }) }) -ConflictAction Copy -Apply
            $New = @(Get-SentParameter 'New-TransportRule')[0]
            $New.Name | Should -BeLike 'Disclaimer (restored *)'
            $New.Enabled | Should -BeFalse
            $Result[0].Message | Should -Match '^Created as a disabled copy'
        }

        It 'describes a planned copy and a planned create in the future tense' {
            $script:Live['TransportRules'] = @([pscustomobject]@{ Name = 'Disclaimer'; Guid = 't1'; Identity = 'Disclaimer'; State = 'Enabled'; Priority = 0 })
            $Copy = Invoke-Restore -Sections ([ordered]@{ TransportRules = @([pscustomobject]@{ Name = 'Disclaimer'; Guid = 't1'; State = 'Enabled'; PrependSubject = '[Ext]' }) }) -ConflictAction Copy
            $Copy[0].Message | Should -Match '^Will be created as a disabled copy'
            $Create = Invoke-Restore -Sections ([ordered]@{ TransportRules = @([pscustomobject]@{ Name = 'New rule'; Guid = 't9'; State = 'Enabled'; PrependSubject = '[Ext]' }) }) -ConflictAction Skip
            $Create.Where({ $_.Key -eq 't9' })[0].Message | Should -Match '^Will be created'
        }

        It 'keeps recipient conditions and exceptions when restoring to another tenant' {
            $script:TargetCustomerId = '22222222-2222-2222-2222-222222222222'
            $script:Live['TransportRules'] = @()
            $Rule = [pscustomobject]@{ Name = 'External'; Guid = 't3'; State = 'Enabled'; SentTo = @('ceo@contoso.com'); ExceptIfFrom = @('bob@contoso.com'); ExceptIfSentToMemberOf = @('Execs'); ExceptIfFromMemberOf = @('Finance'); PrependSubject = '[Ext]' }
            $Result = Invoke-Restore -Sections ([ordered]@{ TransportRules = @($Rule) }) -Apply
            $New = @(Get-SentParameter 'New-TransportRule')[0]
            @($New.SentTo) | Should -Be @('ceo@contoso.com')
            @($New.ExceptIfFrom) | Should -Be @('bob@contoso.com')
            @($New.ExceptIfSentToMemberOf) | Should -Be @('Execs')
            @($New.ExceptIfFromMemberOf) | Should -Be @('Finance')
            $Result[0].Unmapped.Count | Should -Be 0
        }

        It 'fails cleanly when Exchange rejects a rule whose exception cannot be resolved' {
            $script:TargetCustomerId = '22222222-2222-2222-2222-222222222222'
            $script:Live['TransportRules'] = @()
            $script:FailCmdlets = @('New-TransportRule')
            $Result = Invoke-Restore -Sections ([ordered]@{ TransportRules = @([pscustomobject]@{ Name = 'External'; Guid = 't3'; State = 'Enabled'; ExceptIfSentTo = @('ceo@contoso.com') }) }) -Apply
            $Result[0].Status | Should -Be 'Failed'
            $Result[0].Message | Should -Match 'New-TransportRule refused'
        }
    }

    Context 'dynamic distribution lists' {
        It 'creates with the custom filter and keeps the filter kind on update' {
            $script:Live['DynamicDistributionGroups'] = @([pscustomobject]@{ Name = 'All staff'; Guid = 'dd1'; Identity = 'All staff'; IncludedRecipients = 'MailboxUsers'; ConditionalDepartment = @('Sales') })
            $Sections = [ordered]@{ DynamicDistributionGroups = @(
                    [pscustomobject]@{ Name = 'All staff'; Guid = 'dd1'; RecipientFilter = "Department -eq 'Sales'"; IncludedRecipients = $null; MailTip = 'Everyone' }
                    [pscustomobject]@{ Name = 'Managers'; Guid = 'dd2'; RecipientFilter = "Title -like '*Manager*'"; IncludedRecipients = $null; Alias = 'managers' }
                )
            }
            $Result = Invoke-Restore -Sections $Sections -Apply
            $Set = @(Get-SentParameter 'Set-DynamicDistributionGroup')[0]
            @($Set.Keys | Sort-Object) | Should -Be @('Identity', 'MailTip')
            $Result[0].Message | Should -Match 'different kind of filter'
            $New = @(Get-SentParameter 'New-DynamicDistributionGroup')[0]
            $New.RecipientFilter | Should -Be "Title -like '*Manager*'"
            $New.Alias | Should -Be 'managers'
            $New.ContainsKey('IncludedRecipients') | Should -BeFalse
        }
    }

    Context 'tenant boundaries' {
        BeforeEach { $script:TargetCustomerId = '22222222-2222-2222-2222-222222222222' }

        It 'refuses mailbox settings and permissions in another tenant without reading them' {
            $Sections = [ordered]@{
                Mailboxes            = @([pscustomobject]@{ ExchangeGuid = 'eg1'; UserPrincipalName = 'a@contoso.com'; MailTip = 'x' })
                MailboxPermissions   = @([pscustomobject]@{ Identity = 'a'; User = 'b@contoso.com'; AccessRights = @('FullAccess') })
                RecipientPermissions = @([pscustomobject]@{ Identity = 'a'; Trustee = 'b@contoso.com'; AccessRights = @('SendAs') })
            }
            $Result = Invoke-Restore -Sections $Sections -Apply
            $Result.Action | Should -Be @('NotRestorable', 'NotRestorable', 'NotRestorable')
            $Result[0].Message | Should -Match 'only be restored to the tenant'
            $script:BulkCalls.Count | Should -Be 0
            $script:ExoCalls.Count | Should -Be 0
        }

        It 'only updates accepted domains that are already verified in the target' {
            $script:Live['AcceptedDomains'] = @([pscustomobject]@{ Name = 'fabrikam.com'; DomainName = 'fabrikam.com'; Identity = 'fabrikam.com'; DomainType = 'Authoritative' })
            $Sections = [ordered]@{ AcceptedDomains = @(
                    [pscustomobject]@{ Name = 'fabrikam.com'; DomainName = 'fabrikam.com'; Guid = 'd1'; DomainType = 'InternalRelay' }
                    [pscustomobject]@{ Name = 'contoso.com'; DomainName = 'contoso.com'; Guid = 'd2'; DomainType = 'Authoritative' }
                )
            }
            $Result = Invoke-Restore -Sections $Sections -Apply
            $Result.Action | Should -Be @('Update', 'NotRestorable')
            $Result[1].Message | Should -Match 'verify contoso.com'
            @(Get-SentParameter 'Set-AcceptedDomain')[0].DomainType | Should -Be 'InternalRelay'
            @(Get-SentParameter 'New-AcceptedDomain').Count | Should -Be 0
        }

        It 'creates a distribution list without members or source references in another tenant' {
            $script:Live['DistributionGroups'] = @()
            $script:Live['AcceptedDomains'] = @([pscustomobject]@{ Name = 'fabrikam.com'; DomainName = 'fabrikam.com' })
            $Group = [pscustomobject]@{
                Name = 'Sales'; DisplayName = 'Sales'; Guid = 'g1'; Alias = 'sales'; PrimarySmtpAddress = 'sales@contoso.com'; RecipientTypeDetails = 'MailUniversalDistributionGroup'
                ManagedBy = @('alice'); MemberJoinRestriction = 'Closed'; HiddenFromAddressListsEnabled = $true
                Members = @([pscustomobject]@{ Guid = 'm1'; PrimarySmtpAddress = 'a@contoso.com' }, [pscustomobject]@{ Guid = 'm2'; PrimarySmtpAddress = 'b@contoso.com' })
            }
            $Result = Invoke-Restore -Sections ([ordered]@{ DistributionGroups = @($Group) }) -Apply

            $New = @(Get-SentParameter 'New-DistributionGroup')[0]
            $New.ContainsKey('ManagedBy') | Should -BeFalse
            $New.ContainsKey('PrimarySmtpAddress') | Should -BeFalse
            $New.Type | Should -Be 'Distribution'
            $New.MemberJoinRestriction | Should -Be 'Closed'
            @(Get-SentParameter 'Set-DistributionGroup')[0].HiddenFromAddressListsEnabled | Should -BeTrue
            @(Get-SentParameter 'Add-DistributionGroupMember').Count | Should -Be 0
            $Result[0].Unmapped | Should -Contain '2 member(s) are only restored to the tenant the backup came from'
            @($Result[0].Unmapped -match 'ManagedBy').Count | Should -Be 1
            @($Result[0].Unmapped -match 'sales@contoso.com').Count | Should -Be 1
        }
    }

    Context 'additive changes in the same tenant' {
        It 'adds only missing mailbox and Send As grants' {
            $script:LivePerms['a'] = @([pscustomobject]@{ Identity = 'a'; User = 'b@contoso.com'; AccessRights = @('FullAccess'); Deny = $false })
            $script:LivePerms['c'] = @()
            $script:Live['RecipientPermissions'] = @([pscustomobject]@{ Identity = 'a'; Trustee = 'b@contoso.com'; AccessRights = @('SendAs') })
            $Sections = [ordered]@{
                MailboxPermissions   = @(
                    [pscustomobject]@{ Identity = 'a'; User = 'b@contoso.com'; AccessRights = @('FullAccess'); Deny = $false }
                    [pscustomobject]@{ Identity = 'c'; User = 'd@contoso.com'; AccessRights = @('FullAccess'); Deny = $false }
                    [pscustomobject]@{ Identity = 'c'; User = 'S-1-5-21-1-2-3-4'; AccessRights = @('FullAccess'); Deny = $false }
                    [pscustomobject]@{ Identity = 'c'; User = 'e@contoso.com'; AccessRights = @('FullAccess'); Deny = $true }
                )
                RecipientPermissions = @(
                    [pscustomobject]@{ Identity = 'a'; Trustee = 'b@contoso.com'; AccessRights = @('SendAs') }
                    [pscustomobject]@{ Identity = 'c'; Trustee = 'd@contoso.com'; AccessRights = @('SendAs') }
                )
            }
            $Result = Invoke-Restore -Sections $Sections -ConflictAction Overwrite -Apply

            $Result.Action | Should -Be @('Skip', 'Create', 'NotRestorable', 'NotRestorable', 'Skip', 'Create')
            $Full = @(Get-SentParameter 'Add-MailboxPermission')
            $Full.Count | Should -Be 1
            $Full[0].Identity | Should -Be 'c'
            $Full[0].User | Should -Be 'd@contoso.com'
            @($Full[0].AccessRights) | Should -Be @('FullAccess')
            @(Get-SentParameter 'Add-RecipientPermission')[0].Trustee | Should -Be 'd@contoso.com'
            foreach ($Call in $script:BulkCalls) { foreach ($Op in $Call.Ops) { $Op.CmdletInput.CmdletName | Should -Not -Match '^Remove-' } }
        }

        It 'adds missing distribution list members and never removes any' {
            $script:Live['DistributionGroups'] = @([pscustomobject]@{ Name = 'Sales'; Guid = 'g1'; Identity = 'Sales'; DisplayName = 'Sales' })
            $script:LiveMembers['g1'] = @([pscustomobject]@{ Guid = 'm1'; PrimarySmtpAddress = 'a@contoso.com' }, [pscustomobject]@{ Guid = 'm9'; PrimarySmtpAddress = 'z@contoso.com' })
            $Group = [pscustomobject]@{ Name = 'Sales'; DisplayName = 'Sales'; Guid = 'g1'; Members = @([pscustomobject]@{ Guid = 'm1' }, [pscustomobject]@{ Guid = 'm2'; PrimarySmtpAddress = 'b@contoso.com' }) }

            $Result = Invoke-Restore -Sections ([ordered]@{ DistributionGroups = @($Group) }) -Apply

            $Adds = @(Get-SentParameter 'Add-DistributionGroupMember')
            $Adds.Count | Should -Be 1
            $Adds[0].Member | Should -Be 'm2'
            $Adds[0].Identity | Should -Be 'Sales'
            $Result[0].Action | Should -Be 'Update'
            $Result[0].Message | Should -Match 'Adds 1 missing member'
        }

        It 'refuses a mailbox that no longer exists' {
            $Result = Invoke-Restore -Sections ([ordered]@{ Mailboxes = @([pscustomobject]@{ ExchangeGuid = 'gone'; UserPrincipalName = 'gone@contoso.com'; MailTip = 'x' }) }) -Apply
            $Result[0].Action | Should -Be 'NotRestorable'
            @(Get-WriteCall).Count | Should -Be 0
        }
    }

    Context 'failures' {
        It 'keeps going when one item fails and reports it' {
            $script:Live['InboundConnectors'] = @()
            $script:Live['OutboundConnectors'] = @()
            $script:FailCmdlets = @('New-InboundConnector')
            $Sections = [ordered]@{ InboundConnectors = @([pscustomobject]@{ Name = 'In'; Guid = 'i1' }); OutboundConnectors = @([pscustomobject]@{ Name = 'Out'; Guid = 'o1' }) }
            $Result = Invoke-Restore -Sections $Sections -Apply
            $Result.Status | Should -Be @('Failed', 'Succeeded')
            $Result[0].Message | Should -Match 'New-InboundConnector refused'
        }

        It 'fails the items of a section whose current state cannot be read' {
            Mock New-ExoBulkRequest { throw 'EXO down' }
            $Result = Invoke-Restore -Sections ([ordered]@{ RemoteDomains = @([pscustomobject]@{ Name = 'Partner'; DomainName = 'partner.com'; Guid = 'rd' }) }) -Apply
            $Result[0].Status | Should -Be 'Failed'
            $Result[0].Message | Should -Match 'EXO down'
        }

        It 'creates a remote domain and then applies its settings' {
            $script:Live['RemoteDomains'] = @()
            Invoke-Restore -Sections ([ordered]@{ RemoteDomains = @([pscustomobject]@{ Name = 'Partner'; DomainName = 'partner.com'; Guid = 'rd'; AutoForwardEnabled = $false; IsValid = $true }) }) -Apply | Out-Null
            $New = @(Get-SentParameter 'New-RemoteDomain')[0]
            @($New.Keys | Sort-Object) | Should -Be @('DomainName', 'Name')
            $Set = @(Get-SentParameter 'Set-RemoteDomain')[0]
            $Set.Identity | Should -Be 'Partner'
            $Set.AutoForwardEnabled | Should -BeFalse
            $Set.ContainsKey('IsValid') | Should -BeFalse
        }
    }
}
