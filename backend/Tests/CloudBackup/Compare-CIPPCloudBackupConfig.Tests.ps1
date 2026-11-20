BeforeAll {
    $BackendRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    if (-not ('CIPP.CippJson' -as [type])) { Add-Type -Path (Join-Path $BackendRoot 'Shared/CIPPSharp/bin/CIPPSharp.dll') }
    $Folder = Join-Path $BackendRoot 'Modules/CIPPCore/Public/CloudBackup'
    . (Join-Path $Folder 'Get-CIPPCloudBackupSectionLabel.ps1')
    . (Join-Path $Folder 'Get-CIPPCloudBackupItemInfo.ps1')
    . (Join-Path $Folder 'Compare-CIPPCloudBackupConfig.ps1')

    function script:New-Side {
        param([System.Collections.IDictionary]$Sections, $Groups = @{}, $Users = @{})
        [pscustomobject]@{ Sections = $Sections; References = @{ Groups = $Groups; Users = $Users } }
    }
    function script:Compare-One {
        param($Section = 'policies', $Reference, $Difference, [switch]$MatchByName, $RefGroups = @{}, $DiffGroups = @{})
        $Result = @(Compare-CIPPCloudBackupConfig -Area 'Test' -Reference (New-Side ([ordered]@{ $Section = @($Reference) }) $RefGroups) -Difference (New-Side ([ordered]@{ $Section = @($Difference) }) $DiffGroups) -MatchByName:$MatchByName)
        $Result.Count | Should -Be 1
        $Result[0]
    }
}

Describe 'Compare-CIPPCloudBackupConfig' {
    It 'reports added, removed, changed and unchanged items with their labels' {
        $Reference = New-Side ([ordered]@{ policies = @(
                    [pscustomobject]@{ id = 'p1'; displayName = 'Same'; state = 'enabled' }
                    [pscustomobject]@{ id = 'p2'; displayName = 'Edited'; state = 'enabled' }
                    [pscustomobject]@{ id = 'p3'; displayName = 'Deleted'; state = 'enabled' }
                ) })
        $Difference = New-Side ([ordered]@{ policies = @(
                    [pscustomobject]@{ id = 'p4'; displayName = 'Created'; state = 'enabled' }
                    [pscustomobject]@{ id = 'p2'; displayName = 'Edited'; state = 'disabled' }
                    [pscustomobject]@{ id = 'p1'; displayName = 'Same'; state = 'enabled' }
                ) })

        $Result = @(Compare-CIPPCloudBackupConfig -Area 'ConditionalAccess' -Reference $Reference -Difference $Difference)

        $Result.Key | Should -Be @('p1', 'p2', 'p3', 'p4')
        $Result.Change | Should -Be @('Unchanged', 'Changed', 'Removed', 'Added')
        $Result.Name | Should -Be @('Same', 'Edited', 'Deleted', 'Created')
        $Result[0].Area | Should -Be 'ConditionalAccess'
        $Result[0].Section | Should -Be 'policies'
        $Result[0].SectionLabel | Should -Be 'Conditional Access policies'
        $Result[0].Differences.Count | Should -Be 0
        $Result[1].Differences.Count | Should -Be 1
        $Result[1].Differences[0].Path | Should -Be 'state'
        $Result[1].Differences[0].Reference | Should -Be 'enabled'
        $Result[1].Differences[0].Difference | Should -Be 'disabled'
    }

    It 'compares only sections present on both sides' {
        $Result = @(Compare-CIPPCloudBackupConfig -Area 'Intune' -Reference (New-Side ([ordered]@{ roleScopeTags = @([pscustomobject]@{ id = '1' }); intents = @([pscustomobject]@{ id = 'i' }) })) -Difference (New-Side ([ordered]@{ roleScopeTags = @([pscustomobject]@{ id = '1' }); assignmentFilters = @([pscustomobject]@{ id = 'f' }) })))
        $Result.Section | Should -Be @('roleScopeTags')
    }

    It 'accepts sections read back from JSON' {
        $Json = [CIPP.CippJson]::ConvertFromJson('{"Sections":{"policies":[{"id":"p1","state":"on"}]},"References":{"Groups":{},"Users":{}}}')
        $Result = @(Compare-CIPPCloudBackupConfig -Area 'ConditionalAccess' -Reference $Json -Difference (New-Side ([ordered]@{ policies = @([pscustomobject]@{ id = 'p1'; state = 'off' }) })))
        $Result[0].Change | Should -Be 'Changed'
    }

    It 'reports nested differences with dotted paths' {
        $Result = Compare-One -Reference ([pscustomobject]@{ id = 'p'; conditions = [pscustomobject]@{ users = [pscustomobject]@{ includeGroups = @('g1'); excludeUsers = @() } } }) `
            -Difference ([pscustomobject]@{ id = 'p'; conditions = [pscustomobject]@{ users = [pscustomobject]@{ includeGroups = @('g1', 'g2'); excludeUsers = @() } } })
        $Result.Differences.Path | Should -Be @('conditions.users.includeGroups')
        $Result.Differences[0].Reference | Should -Be @('g1')
        $Result.Differences[0].Difference | Should -Be @('g1', 'g2')
    }

    It 'compares arrays of values as sets' {
        $Result = Compare-One -Reference ([pscustomobject]@{ id = 'p'; includeApplications = @('b', 'a', 'c') }) -Difference ([pscustomobject]@{ id = 'p'; includeApplications = @('c', 'a', 'b') })
        $Result.Change | Should -Be 'Unchanged'
    }

    It 'reports a property that only one side has' {
        $Result = Compare-One -Reference ([pscustomobject]@{ id = 'p'; a = 1 }) -Difference ([pscustomobject]@{ id = 'p'; b = 2 })
        $Result.Differences.Path | Should -Be @('a', 'b')
        $Result.Differences[0].Difference | Should -BeNullOrEmpty
        $Result.Differences[1].Reference | Should -BeNullOrEmpty
    }

    It 'treats null, missing, empty strings and empty arrays as the same' {
        $Result = Compare-One -Reference ([pscustomobject]@{ id = 'p'; a = $null; b = @(); c = '' }) -Difference ([pscustomobject]@{ id = 'p'; b = $null; c = @(); d = '' })
        $Result.Change | Should -Be 'Unchanged'
    }

    It 'compares numbers, booleans and dates by value' {
        $Result = Compare-One -Reference ([pscustomobject]@{ id = 'p'; count = [int64]5; enabled = $true; at = [datetime]::new(2024, 1, 2, 3, 4, 5, [System.DateTimeKind]::Utc) }) `
            -Difference ([pscustomobject]@{ id = 'p'; count = 5; enabled = 'True'; at = '2024-01-02T03:04:05Z' })
        $Result.Change | Should -Be 'Unchanged'
    }

    It 'ignores <Name>' -TestCases @(
        @{ Name = 'ids, odata annotations and timestamps'; Ref = @{ id = 'p'; '@odata.etag' = 'W/1'; 'assignments@odata.context' = 'x'; createdDateTime = '1'; lastModifiedDateTime = '1'; modifiedDateTime = '1'; version = 1; settingCount = 1 }; Diff = @{ id = 'p'; '@odata.etag' = 'W/2'; 'assignments@odata.context' = 'y'; createdDateTime = '2'; lastModifiedDateTime = '2'; modifiedDateTime = '2'; version = 2; settingCount = 3 } }
        @{ Name = 'Exchange system properties'; Ref = @{ Guid = 'g'; ExchangeObjectId = '1'; Identity = '1'; DistinguishedName = '1'; OrganizationId = '1'; ObjectState = '1'; WhenChanged = '1'; WhenCreated = '1'; WhenChangedUTC = '1'; WhenCreatedUTC = '1'; IsValid = $true; ExchangeVersion = '1'; OriginatingServer = '1'; RunspaceId = '1'; PSComputerName = '1' }; Diff = @{ Guid = 'g'; ExchangeObjectId = '2'; Identity = '2'; DistinguishedName = '2'; OrganizationId = '2'; ObjectState = '2'; WhenChanged = '2'; WhenCreated = '2'; WhenChangedUTC = '2'; WhenCreatedUTC = '2'; IsValid = $false; ExchangeVersion = '2'; OriginatingServer = '2'; RunspaceId = '2'; PSComputerName = '2' } }
        @{ Name = 'nested ids'; Ref = @{ id = 'p'; grantControls = [pscustomobject]@{ id = 'a'; operator = 'OR' } }; Diff = @{ id = 'p'; grantControls = [pscustomobject]@{ id = 'b'; operator = 'OR' } } }
        @{ Name = 'the default scope tag'; Ref = @{ id = 'p'; roleScopeTagIds = @('0') }; Diff = @{ id = 'p' } }
    ) {
        $Section = if ($Ref.ContainsKey('Guid')) { 'TransportRules' } else { 'policies' }
        $Result = Compare-One -Section $Section -Reference ([pscustomobject]$Ref) -Difference ([pscustomobject]$Diff)
        $Result.Change | Should -Be 'Unchanged'
    }

    It 'reports scope tags other than the default' {
        $Result = Compare-One -Reference ([pscustomobject]@{ id = 'p'; roleScopeTagIds = @('0', '3') }) -Difference ([pscustomobject]@{ id = 'p'; roleScopeTagIds = @('0') })
        $Result.Differences.Path | Should -Be @('roleScopeTagIds')
    }

    It 'matches a masked secret to any value' {
        $Result = Compare-One -Section 'deviceConfigurations' -Reference ([pscustomobject]@{ id = 'c'; omaSettings = @([pscustomobject]@{ omaUri = './x'; value = '(encrypted)' }) }) `
            -Difference ([pscustomobject]@{ id = 'c'; omaSettings = @([pscustomobject]@{ omaUri = './x'; value = 'real secret' }) })
        $Result.Change | Should -Be 'Unchanged'
    }

    It 'matches arrays of objects by identity regardless of order and reports indexed paths' {
        $Reference = [pscustomobject]@{ id = 'c'; assignments = @(
                [pscustomobject]@{ id = 'a1'; target = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = 'g1'; filterType = 'none' } }
                [pscustomobject]@{ id = 'a2'; target = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = 'g2'; filterType = 'none' } }
                [pscustomobject]@{ id = 'a3'; target = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.exclusionGroupAssignmentTarget'; groupId = 'g3' } }
            )
        }
        $Difference = [pscustomobject]@{ id = 'c'; assignments = @(
                [pscustomobject]@{ id = 'a2'; target = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = 'g2'; filterType = 'include' } }
                [pscustomobject]@{ id = 'a1'; target = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = 'g1'; filterType = 'none' } }
                [pscustomobject]@{ id = 'a4'; target = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.allDevicesAssignmentTarget' } }
            )
        }
        $Result = Compare-One -Section 'deviceConfigurations' -Reference $Reference -Difference $Difference

        $Result.Change | Should -Be 'Changed'
        $Result.Differences.Path | Should -Be @('assignments[1].target.filterType', 'assignments[2].target.@odata.type', 'assignments[2].target.groupId') -Because 'unmatched leftovers pair by position'
    }

    It 'reports elements without a counterpart as added or removed' {
        $Result = Compare-One -Section 'configurationPolicies' -Reference ([pscustomobject]@{ id = 'c'; settings = @(
                    [pscustomobject]@{ id = '0'; settingInstance = [pscustomobject]@{ settingDefinitionId = 'a'; value = 1 } }
                ) }) -Difference ([pscustomobject]@{ id = 'c'; settings = @(
                    [pscustomobject]@{ id = '0'; settingInstance = [pscustomobject]@{ settingDefinitionId = 'a'; value = 1 } }
                    [pscustomobject]@{ id = '1'; settingInstance = [pscustomobject]@{ settingDefinitionId = 'b'; value = 2 } }
                ) })
        $Result.Differences.Count | Should -Be 1
        $Result.Differences[0].Path | Should -Be 'settings[1]'
        $Result.Differences[0].Reference | Should -BeNullOrEmpty
        $Result.Differences[0].Difference.settingInstance.settingDefinitionId | Should -Be 'b'
    }

    It 'matches settings catalog settings by definition id' {
        $Result = Compare-One -Section 'configurationPolicies' -Reference ([pscustomobject]@{ id = 'c'; settings = @(
                    [pscustomobject]@{ id = '0'; settingInstance = [pscustomobject]@{ settingDefinitionId = 'a'; value = 1 } }
                    [pscustomobject]@{ id = '1'; settingInstance = [pscustomobject]@{ settingDefinitionId = 'b'; value = 2 } }
                ) }) -Difference ([pscustomobject]@{ id = 'c'; settings = @(
                    [pscustomobject]@{ id = '0'; settingInstance = [pscustomobject]@{ settingDefinitionId = 'b'; value = 3 } }
                    [pscustomobject]@{ id = '1'; settingInstance = [pscustomobject]@{ settingDefinitionId = 'a'; value = 1 } }
                ) })
        $Result.Differences.Path | Should -Be @('settings[1].settingInstance.value')
        $Result.Differences[0].Reference | Should -Be 2
        $Result.Differences[0].Difference | Should -Be 3
    }

    It 'matches Exchange items by key' {
        $Reference = New-Side ([ordered]@{
                Mailboxes          = @([pscustomobject]@{ Guid = 'm1'; DisplayName = 'Jane'; HiddenFromAddressListsEnabled = $false; WhenChanged = '2024-01-01T00:00:00' })
                MailboxPermissions = @([pscustomobject]@{ Identity = 'jane'; User = 'bob'; AccessRights = @('FullAccess') })
            })
        $Difference = New-Side ([ordered]@{
                Mailboxes          = @([pscustomobject]@{ Guid = 'm1'; DisplayName = 'Jane'; HiddenFromAddressListsEnabled = $true; WhenChanged = '2025-01-01T00:00:00' })
                MailboxPermissions = @([pscustomobject]@{ Identity = 'jane'; User = 'carol'; AccessRights = @('FullAccess') })
            })
        $Result = @(Compare-CIPPCloudBackupConfig -Area 'Exchange' -Reference $Reference -Difference $Difference)
        $Result.Change | Should -Be @('Changed', 'Removed', 'Added')
        $Result[0].Differences.Path | Should -Be @('HiddenFromAddressListsEnabled')
        $Result[2].Key | Should -Be 'jane|carol|FullAccess'
    }

    Context 'MatchByName' {
        It 'matches items by name and ignores their ids' {
            $Result = @(Compare-CIPPCloudBackupConfig -Area 'ConditionalAccess' -MatchByName `
                    -Reference (New-Side ([ordered]@{ policies = @([pscustomobject]@{ id = 'p1'; displayName = 'MFA'; state = 'enabled' }) })) `
                    -Difference (New-Side ([ordered]@{ policies = @([pscustomobject]@{ id = 'other'; displayName = 'MFA'; state = 'enabled' }) })))
            $Result.Count | Should -Be 1
            $Result[0].Change | Should -Be 'Unchanged'
            $Result[0].Key | Should -Be 'p1'
        }

        It 'does not match items by id' {
            $Result = @(Compare-CIPPCloudBackupConfig -Area 'ConditionalAccess' -MatchByName `
                    -Reference (New-Side ([ordered]@{ policies = @([pscustomobject]@{ id = 'p1'; displayName = 'MFA' }) })) `
                    -Difference (New-Side ([ordered]@{ policies = @([pscustomobject]@{ id = 'p1'; displayName = 'MFA for admins' }) })))
            $Result.Change | Should -Be @('Removed', 'Added')
        }

        It 'compares referenced groups and users by name' {
            $Policy = { param($Groups, $Users) [pscustomobject]@{ id = [guid]::NewGuid().ToString(); displayName = 'MFA'; conditions = [pscustomobject]@{ users = [pscustomobject]@{ includeGroups = $Groups; excludeUsers = $Users; includeUsers = @('All') } } } }
            $Reference = New-Side ([ordered]@{ policies = @(& $Policy @('aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000002') @('aaaaaaaa-0000-0000-0000-000000000003')) }) `
                -Groups @{ 'aaaaaaaa-0000-0000-0000-000000000001' = 'Sales'; 'aaaaaaaa-0000-0000-0000-000000000002' = 'HR' } -Users @{ 'aaaaaaaa-0000-0000-0000-000000000003' = 'breakglass@a.com' }
            $Difference = New-Side ([ordered]@{ policies = @(& $Policy @('bbbbbbbb-0000-0000-0000-000000000002', 'bbbbbbbb-0000-0000-0000-000000000001') @('bbbbbbbb-0000-0000-0000-000000000003')) }) `
                -Groups @{ 'bbbbbbbb-0000-0000-0000-000000000001' = 'Sales'; 'bbbbbbbb-0000-0000-0000-000000000002' = 'HR' } -Users @{ 'bbbbbbbb-0000-0000-0000-000000000003' = 'breakglass@a.com' }

            (Compare-CIPPCloudBackupConfig -Area 'ConditionalAccess' -Reference $Reference -Difference $Difference -MatchByName).Change | Should -Be 'Unchanged'

            $Difference.References.Groups['bbbbbbbb-0000-0000-0000-000000000002'] = 'Finance'
            $Result = Compare-CIPPCloudBackupConfig -Area 'ConditionalAccess' -Reference $Reference -Difference $Difference -MatchByName
            $Result.Differences.Path | Should -Be @('conditions.users.includeGroups')

            (Compare-CIPPCloudBackupConfig -Area 'ConditionalAccess' -Reference $Reference -Difference $Difference).Change | Should -Be @('Removed', 'Added') -Because 'without -MatchByName items match by id'
        }

        It 'compares named locations by name' {
            $Reference = New-Side ([ordered]@{
                    namedLocations = @([pscustomobject]@{ id = 'aaaaaaaa-0000-0000-0000-00000000000a'; displayName = 'Office' })
                    policies       = @([pscustomobject]@{ id = 'p'; displayName = 'Block'; conditions = [pscustomobject]@{ locations = [pscustomobject]@{ includeLocations = @('All'); excludeLocations = @('aaaaaaaa-0000-0000-0000-00000000000a') } } })
                })
            $Difference = New-Side ([ordered]@{
                    namedLocations = @([pscustomobject]@{ id = 'bbbbbbbb-0000-0000-0000-00000000000a'; displayName = 'Office' })
                    policies       = @([pscustomobject]@{ id = 'q'; displayName = 'Block'; conditions = [pscustomobject]@{ locations = [pscustomobject]@{ includeLocations = @('All'); excludeLocations = @('bbbbbbbb-0000-0000-0000-00000000000a') } } })
                })
            $Result = @(Compare-CIPPCloudBackupConfig -Area 'ConditionalAccess' -Reference $Reference -Difference $Difference -MatchByName)
            $Result.Change | Should -Be @('Unchanged', 'Unchanged')
        }

        It 'matches Intune assignments by group name, assignment filter and scope tag names' {
            $Side = {
                param($Prefix, $TagId)
                New-Side ([ordered]@{
                        roleScopeTags        = @([pscustomobject]@{ id = $TagId; displayName = 'Region' })
                        assignmentFilters    = @([pscustomobject]@{ id = "$Prefix-0000-0000-0000-0000000000f1"; displayName = 'Corporate' })
                        deviceConfigurations = @([pscustomobject]@{ id = "$Prefix-c"; displayName = 'Wi-Fi'; roleScopeTagIds = @($TagId); assignments = @(
                                    [pscustomobject]@{ id = "$Prefix-a1"; target = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = "$Prefix-0000-0000-0000-000000000001"; deviceAndAppManagementAssignmentFilterId = "$Prefix-0000-0000-0000-0000000000f1" } }
                                    [pscustomobject]@{ id = "$Prefix-a2"; target = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = "$Prefix-0000-0000-0000-000000000002" } }
                                ) 
                            })
                    }) -Groups @{ "$Prefix-0000-0000-0000-000000000001" = 'Laptops'; "$Prefix-0000-0000-0000-000000000002" = 'Kiosks' }
            }
            $Reference = & $Side 'aaaaaaaa' '5'
            $Difference = & $Side 'bbbbbbbb' '9'
            [array]::Reverse($Difference.Sections['deviceConfigurations'][0].assignments)

            $Result = @(Compare-CIPPCloudBackupConfig -Area 'Intune' -Reference $Reference -Difference $Difference -MatchByName)
            $Result.Change | Should -Be @('Unchanged', 'Unchanged', 'Unchanged')
        }
    }
}
