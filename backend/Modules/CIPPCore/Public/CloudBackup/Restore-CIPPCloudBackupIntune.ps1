function Restore-CIPPCloudBackupIntune {
    <#
    .SYNOPSIS
        Restores Intune items from a Cloud Backup snapshot
    .DESCRIPTION
        Restores scope tags and assignment filters first, then every policy, profile and script section the backup
        holds, remapping scope tag, filter and group ids and re-applying assignments. Unmapped groups and filters
        drop the assignment that used them and are reported. Without -Apply nothing is written and each row is a
        plan. Returns one row per selected item.
    .FUNCTIONALITY
        Internal
    #>
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'CAState', Justification = 'Same parameters as Restore-CIPPCloudBackupConditionalAccess')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Snapshot,
        [Parameter(Mandatory = $true)]
        [string]$SourceTenantId,
        [Parameter(Mandatory = $true)]
        [string]$TargetTenantFilter,
        $Items,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Skip', 'Overwrite', 'Copy')]
        [string]$ConflictAction,
        [ValidateSet('AsBackedUp', 'ReportOnly', 'Disabled')]
        [string]$CAState = 'AsBackedUp',
        [switch]$Apply
    )

    $ErrorActionPreference = 'Stop'
    $GraphBase = 'https://graph.microsoft.com/beta'
    $EmptyGuid = '00000000-0000-0000-0000-000000000000'
    $Order = @(
        'roleScopeTags', 'assignmentFilters', 'deviceConfigurations', 'configurationPolicies', 'groupPolicyConfigurations',
        'deviceCompliancePolicies', 'managedAppPolicies', 'mobileAppConfigurations', 'intents', 'windowsFeatureUpdateProfiles',
        'windowsQualityUpdatePolicies', 'windowsQualityUpdateProfiles', 'windowsDriverUpdateProfiles', 'deviceManagementScripts',
        'deviceShellScripts', 'deviceHealthScripts'
    )
    $Paths = @{}
    foreach ($Section in $Order) { $Paths[$Section] = "/deviceManagement/$Section" }
    $Paths['managedAppPolicies'] = '/deviceAppManagement/managedAppPolicies'
    $Paths['mobileAppConfigurations'] = '/deviceAppManagement/mobileAppConfigurations'
    $TypedSections = @('deviceConfigurations', 'deviceCompliancePolicies', 'managedAppPolicies', 'mobileAppConfigurations')
    $AppCollections = @{
        '#microsoft.graph.androidManagedAppProtection'           = 'androidManagedAppProtections'
        '#microsoft.graph.iosManagedAppProtection'               = 'iosManagedAppProtections'
        '#microsoft.graph.windowsManagedAppProtection'           = 'windowsManagedAppProtections'
        '#microsoft.graph.targetedManagedAppConfiguration'       = 'targetedManagedAppConfigurations'
        '#microsoft.graph.mdmWindowsInformationProtectionPolicy' = 'mdmWindowsInformationProtectionPolicies'
        '#microsoft.graph.windowsInformationProtectionPolicy'    = 'windowsInformationProtectionPolicies'
    }
    $ReadOnly = @('id', 'createdDateTime', 'lastModifiedDateTime', 'version', 'assignments', 'settingCount', 'isAssigned', 'supportsScopeTags', 'deployedAppCount')
    $ReadOnlyBySection = @{
        roleScopeTags                = @('isBuiltIn')
        assignmentFilters            = @('payloads')
        deviceConfigurations         = @('featureUpdatesWillBeRolledBack', 'qualityUpdatesWillBeRolledBack', 'qualityUpdatesPauseStartDate', 'featureUpdatesPauseStartDate')
        deviceCompliancePolicies     = @('scheduledActionsForRule')
        managedAppPolicies           = @('apps', 'protectedAppLockerFiles', 'exemptAppLockerFiles', 'deploymentSummary')
        windowsFeatureUpdateProfiles = @('deployableContentDisplayName', 'endOfSupportDate')
        windowsQualityUpdateProfiles = @('releaseDateDisplayName', 'deployableContentDisplayName')
        windowsDriverUpdateProfiles  = @('inventorySyncStatus', 'newUpdates', 'deviceReporting')
        deviceManagementScripts      = @('groupAssignments', 'runSummary', 'deviceRunStates', 'userRunStates')
        deviceShellScripts           = @('groupAssignments', 'runSummary', 'deviceRunStates', 'userRunStates')
        deviceHealthScripts          = @('runSummary', 'deviceRunStates', 'highestAvailableVersion', 'isGlobalScript')
    }
    $FixedOnUpdate = @{
        assignmentFilters            = @('platform', 'assignmentFilterManagementType')
        mobileAppConfigurations      = @('targetedMobileApps')
        windowsFeatureUpdateProfiles = @('installLatestWindows10OnWindows11IneligibleDevice')
        windowsDriverUpdateProfiles  = @('approvalType')
    }
    $CatalogProperties = @('name', 'description', 'platforms', 'technologies', 'roleScopeTagIds', 'settings', 'templateReference', 'creationSource')
    $Today = [datetime]::UtcNow.ToString('yyyy-MM-dd')
    $Results = [System.Collections.Generic.List[object]]::new()

    $TargetTenant = @(Get-Tenants -TenantFilter $TargetTenantFilter)[0]
    $SameTenant = $TargetTenantFilter -eq $SourceTenantId -or ($null -ne $TargetTenant -and [string]$TargetTenant.customerId -eq $SourceTenantId)

    $Selected = $null
    if ($null -ne $Items) {
        $Selected = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($Entry in @($Items)) { if ($null -ne $Entry) { [void]$Selected.Add("$($Entry.Section)|$($Entry.Key)") } }
    }

    $Sections = $Snapshot.Sections
    $SectionNames = if ($Sections -is [System.Collections.IDictionary]) { @($Sections.Keys) } elseif ($null -ne $Sections) { @($Sections.PSObject.Properties.Name) } else { @() }
    $Work = foreach ($Section in @($Order) + @($SectionNames.Where({ $_ -notin $Order }))) {
        if ($Section -notin $SectionNames) { continue }
        $Label = Get-CIPPCloudBackupSectionLabel -Section $Section
        $SectionItems = @(@($Sections.$Section).Where({ $null -ne $_ }))
        if ($SectionItems.Count -eq 0) { continue }
        $Infos = @(Get-CIPPCloudBackupItemInfo -Section $Section -Item $SectionItems)
        for ($Index = 0; $Index -lt $SectionItems.Count; $Index++) {
            $Item = $SectionItems[$Index]
            $Info = $Infos[$Index]
            @{
                Section  = $Section
                Label    = $Label
                Item     = $Item
                Key      = [string]$Info.Key
                Name     = [string]$Info.Name
                Selected = $null -eq $Selected -or $Selected.Contains("$Section|$($Info.Key)")
            }
        }
    }

    $ReadSections = @($Order).Where({ $_ -in 'roleScopeTags', 'assignmentFilters' -or $_ -in $SectionNames })
    $ById = @{}
    $ByName = @{}
    $TargetErrors = @{}
    foreach ($Section in $Order) { $ById[$Section] = @{}; $ByName[$Section] = @{} }
    try {
        $Responses = @{}
        $Requests = foreach ($Section in $ReadSections) { @{ id = $Section; method = 'GET'; url = $Paths[$Section] } }
        foreach ($Response in @(New-GraphBulkRequest -tenantid $TargetTenantFilter -Requests @($Requests) -MaxConcurrency 4)) { $Responses[[string]$Response.id] = $Response }
        foreach ($Section in $ReadSections) {
            $Response = $Responses[$Section]
            $Status = $Response.status -as [int]
            if ($Status -lt 200 -or $Status -ge 300 -or $Response.PagingIncomplete) {
                $TargetErrors[$Section] = if (-not $Response) { 'no response from Graph' } elseif ($Response.PagingIncomplete) { $Response.PagingError } else { Get-NormalizedError -Message ($Response.body.error.message ?? "HTTP $Status") }
                continue
            }
            foreach ($Existing in @($Response.body.value)) {
                if ($null -eq $Existing) { continue }
                $ById[$Section][[string]$Existing.id] = $Existing
                $ExistingName = [string]($Existing.displayName ?? $Existing.name)
                if ($Section -in $TypedSections) { $ExistingName = "$ExistingName|$($Existing.'@odata.type')" }
                if (-not $ByName[$Section].ContainsKey($ExistingName)) { $ByName[$Section][$ExistingName] = [System.Collections.Generic.List[object]]::new() }
                $ByName[$Section][$ExistingName].Add($Existing)
            }
        }
    } catch {
        $ReadError = Get-NormalizedError -Message $_.Exception.Message
        foreach ($Section in $ReadSections) { $TargetErrors[$Section] = $ReadError }
    }

    $SourceReferences = $Snapshot.References
    $ReferenceInput = @{ Groups = @{}; Users = @{} }
    $IdMap = @{ roleScopeTags = @{}; assignmentFilters = @{} }
    $NameOf = @{ roleScopeTags = @{}; assignmentFilters = @{} }
    foreach ($Entry in $Work) {
        if ($NameOf.ContainsKey($Entry.Section)) { $NameOf[$Entry.Section][[string]$Entry.Item.id] = $Entry.Name }
        if (-not $Entry.Selected) { continue }
        foreach ($Assignment in @($Entry.Item.assignments)) {
            $GroupId = [string]$Assignment.target.groupId
            if ($GroupId) { $ReferenceInput.Groups[$GroupId] = [string]$SourceReferences.Groups.$GroupId }
        }
        if ($Entry.Section -eq 'deviceCompliancePolicies') {
            foreach ($Rule in @($Entry.Item.scheduledActionsForRule)) {
                foreach ($Config in @($Rule.scheduledActionConfigurations)) {
                    foreach ($GroupId in @($Config.notificationMessageCCList)) {
                        if ($GroupId) { $ReferenceInput.Groups[[string]$GroupId] = [string]$SourceReferences.Groups.$GroupId }
                    }
                }
            }
        }
    }
    $References = @{ Groups = @{}; Users = @{}; Missing = @{} }
    $ReferenceError = $null
    if ($ReferenceInput.Groups.Count -gt 0) {
        try {
            $References = Resolve-CIPPCloudBackupReference -TargetTenantFilter $TargetTenantFilter -References $ReferenceInput -SameTenant:$SameTenant
        } catch {
            $ReferenceError = Get-NormalizedError -Message $_.Exception.Message
        }
    }

    foreach ($Entry in $Work) {
        $Section = $Entry.Section
        $Item = $Entry.Item
        $SourceId = [string]$Item.id
        $Type = [string]$Item.'@odata.type'
        $MatchName = if ($Section -in $TypedSections) { "$($Entry.Name)|$Type" } else { $Entry.Name }
        $Match = $null
        $MatchCount = 0
        if ($Section -in $Order -and -not $TargetErrors[$Section]) {
            if ($SameTenant -and $SourceId -and $ById[$Section].ContainsKey($SourceId)) {
                $Match = $ById[$Section][$SourceId]
                $MatchCount = 1
            } elseif ($ByName[$Section].ContainsKey($MatchName)) {
                $MatchCount = $ByName[$Section][$MatchName].Count
                if ($MatchCount -eq 1) { $Match = $ByName[$Section][$MatchName][0] }
            }
        }
        $IsBuiltIn = $Section -eq 'roleScopeTags' -and ($Item.isBuiltIn -eq $true -or $SourceId -eq '0')
        if ($IdMap.ContainsKey($Section)) {
            $IdMap[$Section][$SourceId] = if ($IsBuiltIn) { $SourceId } elseif ($Match) { [string]$Match.id } else { $null }
        }
        if (-not $Entry.Selected) { continue }

        $Row = [ordered]@{
            Area         = 'Intune'
            Section      = $Section
            SectionLabel = $Entry.Label
            Key          = $Entry.Key
            Name         = $Entry.Name
            Action       = 'NotRestorable'
            Status       = 'Skipped'
            Message      = $null
            Unmapped     = @()
        }
        $Unmapped = [System.Collections.Generic.List[string]]::new()
        $Written = $null
        try {
            $Collection = if ($Section -eq 'managedAppPolicies') { $AppCollections[$Type] }
            $IsWip = $Collection -in 'mdmWindowsInformationProtectionPolicies', 'windowsInformationProtectionPolicies'
            $NotRestorable = switch ($Section) {
                { $_ -notin $Order } { 'This kind of item cannot be restored' }
                'deviceConfigurations' {
                    $Masked = @($Item.omaSettings).Where({ $null -ne $_ -and "$($_.value)" -eq '(encrypted)' })
                    $Placeholder = @($Item.omaSettings).Where({ $null -ne $_ -and ($_.secretReferenceValueId -or $_.isEncrypted -eq $true -or "$($_.value)" -eq 'PGEvPg==') })
                    if ($Masked.Count -gt 0) {
                        "Its encrypted OMA-URI values ($(@($Masked.displayName) -join ', ')) are not in this backup because the backup policy does not use encryption"
                    } elseif ($Placeholder.Count -gt 0) {
                        "Its encrypted OMA-URI values ($(@($Placeholder.displayName) -join ', ')) could not be read when the backup was made"
                    }
                }
                'configurationPolicies' {
                    if (-not $SameTenant -and "$($Item.creationSource)" -like 'DepTokenId_*') { "It is bound to the source tenant's Apple enrollment token" }
                }
                'managedAppPolicies' {
                    if (-not $Collection) { 'Built-in app protection policies exist in every tenant and cannot be created' }
                    elseif ($IsWip -and (@($Item.protectedAppLockerFiles).Where({ $_ }).Count + @($Item.exemptAppLockerFiles).Where({ $_ }).Count) -gt 0) { 'Windows Information Protection policies with AppLocker files cannot be restored' }
                }
                'mobileAppConfigurations' {
                    if (-not $SameTenant -and @($Item.targetedMobileApps).Where({ $_ }).Count -gt 0) { 'It targets apps by their id in the source tenant' }
                }
                'intents' {
                    if (-not $Item.templateId) { 'The backup does not record the security baseline template it was made from' }
                }
                { $_ -in 'deviceManagementScripts', 'deviceShellScripts' } {
                    if (-not $Item.scriptContent) { 'The backup does not hold the script content' }
                }
                'deviceHealthScripts' {
                    if ($Item.isGlobalScript -eq $true) { 'Remediations published by Microsoft exist in every tenant and cannot be created' }
                    elseif (-not $Item.detectionScriptContent) { 'The backup does not hold the detection script' }
                }
            }

            if ($NotRestorable) {
                $Row.Message = [string]$NotRestorable
            } elseif ($IsBuiltIn) {
                $Row.Action = 'Skip'
                $Row.Message = 'Built-in scope tags exist in every tenant'
            } else {
                if ($TargetErrors[$Section]) {
                    $Row.Action = 'Skip'
                    throw "Could not read the target's $($Entry.Label): $($TargetErrors[$Section])"
                }
                $Row.Action = if ($MatchCount -eq 0) { 'Create' } elseif ($ConflictAction -eq 'Skip') { 'Skip' } elseif ($ConflictAction -eq 'Copy') { 'CreateCopy' } else { 'Update' }
                if ($Row.Action -eq 'Skip') {
                    $Row.Message = if ($MatchCount -gt 1) { "$MatchCount items with this name already exist in the target" } else { 'Already exists in the target' }
                } else {
                    if ($Row.Action -eq 'Update' -and $MatchCount -gt 1) {
                        throw "$MatchCount items in the target are named '$($Entry.Name)', so CIPP cannot tell which one to update"
                    }
                    $IsUpdate = $Row.Action -eq 'Update'
                    $NewName = if ($Row.Action -eq 'CreateCopy') { "$($Entry.Name) (restored $Today)" } else { $Entry.Name }
                    $CopyKind = if ($Section -in 'roleScopeTags', 'assignmentFilters') { 'a copy' } else { 'an unassigned copy' }
                    $CreatedText = if ($Row.Action -eq 'CreateCopy') { "Created as $CopyKind '$NewName'" } else { 'Created' }
                    $NameProperty = if ($Section -eq 'configurationPolicies') { 'name' } else { 'displayName' }

                    $Remove = @($ReadOnly) + @($ReadOnlyBySection[$Section]) + @(if ($IsUpdate) { $FixedOnUpdate[$Section] })
                    $Body = switch ($Section) {
                        'groupPolicyConfigurations' { @{ description = [string]$Item.description; roleScopeTagIds = @($Item.roleScopeTagIds) } }
                        'intents' { @{ description = [string]$Item.description; roleScopeTagIds = @($Item.roleScopeTagIds) } }
                        default { ConvertTo-CIPPCloudBackupRestoreBody -Item $Item -Remove $Remove }
                    }
                    $Body[$NameProperty] = $NewName
                    if ($Section -eq 'configurationPolicies') {
                        foreach ($Property in @($Body.Keys)) { if ($Property -notin $CatalogProperties) { $Body.Remove($Property) } }
                        if (-not ("$($Body['creationSource'])" -like 'DepTokenId_*')) { $Body.Remove('creationSource') }
                    }

                    foreach ($TagField in 'roleScopeTagIds', 'roleScopeTags') {
                        if ($Section -eq 'roleScopeTags' -or $null -eq $Body[$TagField]) { continue }
                        $Tags = @(foreach ($TagId in @($Body[$TagField])) {
                                $TagId = [string]$TagId
                                $Mapped = if ($TagId -eq '0') { '0' } elseif ($IdMap.roleScopeTags.ContainsKey($TagId)) { $IdMap.roleScopeTags[$TagId] } elseif ($SameTenant -and $ById.roleScopeTags.ContainsKey($TagId)) { $TagId }
                                if ($Mapped) { $Mapped } else { $Unmapped.Add("Scope tag '$($NameOf.roleScopeTags[$TagId] ?? $TagId)' not found in the target") }
                            })
                        $Body[$TagField] = @(if ($Tags.Count -gt 0) { $Tags } else { '0' })
                    }

                    $Settings = $null
                    if ($Section -eq 'intents') {
                        $Settings = @(foreach ($Setting in @($Item.settings)) {
                                if ($null -eq $Setting) { continue }
                                @{ '@odata.type' = [string]$Setting.'@odata.type'; definitionId = [string]$Setting.definitionId; valueJson = [string]$Setting.valueJson }
                            })
                    }

                    $Definitions = $null
                    if ($Section -eq 'groupPolicyConfigurations') {
                        $DefinitionUri = "$GraphBase/deviceManagement/groupPolicyDefinitions"
                        $Added = @(foreach ($Value in @($Item.definitionValues)) {
                                if ($null -eq $Value -or -not $Value.definition.id) { continue }
                                $DefinitionId = [string]$Value.definition.id
                                $PresentationValues = @(foreach ($Presentation in @($Value.presentationValues)) {
                                        if ($null -eq $Presentation -or -not $Presentation.presentation.id) { continue }
                                        $PresentationEntry = @{
                                            'presentation@odata.bind' = "$DefinitionUri('$DefinitionId')/presentations('$($Presentation.presentation.id)')"
                                            presentation              = @{ id = [string]$Presentation.presentation.id; label = [string]$Presentation.presentation.label; '@odata.type' = [string]$Presentation.presentation.'@odata.type'; index = $null }
                                        }
                                        if ($Presentation.'@odata.type') { $PresentationEntry['@odata.type'] = [string]$Presentation.'@odata.type' }
                                        if ($null -ne $Presentation.values) { $PresentationEntry['values'] = $Presentation.values }
                                        if ($null -ne $Presentation.value) { $PresentationEntry['value'] = $Presentation.value }
                                        $PresentationEntry
                                    })
                                @{
                                    'definition@odata.bind' = "$DefinitionUri('$DefinitionId')"
                                    enabled                 = [bool]$Value.enabled
                                    presentationValues      = $PresentationValues
                                    definition              = @{ id = $DefinitionId; displayName = [string]$Value.definition.displayName; categoryPath = [string]$Value.definition.categoryPath; classType = [string]$Value.definition.classType; policyType = [string]$Value.definition.policyType }
                                }
                            })
                        $Definitions = ConvertTo-Json -InputObject @{ added = $Added; updated = @(); deletedIds = @() } -Depth 100 -Compress
                    }

                    $Actions = $null
                    if ($Section -eq 'deviceCompliancePolicies') {
                        $Actions = @(foreach ($Rule in @($Item.scheduledActionsForRule)) {
                                if ($null -eq $Rule) { continue }
                                $Configurations = @(foreach ($Config in @($Rule.scheduledActionConfigurations)) {
                                        if ($null -eq $Config) { continue }
                                        $TemplateId = [string]$Config.notificationTemplateId
                                        if (-not $SameTenant -and $TemplateId -and $TemplateId -ne $EmptyGuid) {
                                            $Unmapped.Add("Notification message template $TemplateId belongs to the source tenant; the notification action that uses it was left out")
                                            continue
                                        }
                                        $CCList = @(foreach ($GroupId in @($Config.notificationMessageCCList)) {
                                                if (-not $GroupId) { continue }
                                                if ($ReferenceError) { throw "Could not look up the groups this item uses in the target: $ReferenceError" }
                                                $Mapped = $References.Groups[[string]$GroupId]
                                                if ($Mapped) { $Mapped } else { $Unmapped.Add($References.Missing[[string]$GroupId] ?? "Group $GroupId not found in the target") }
                                            })
                                        @{ actionType = $Config.actionType; gracePeriodHours = $Config.gracePeriodHours; notificationTemplateId = $Config.notificationTemplateId; notificationMessageCCList = $CCList }
                                    })
                                @{ ruleName = $Rule.ruleName; scheduledActionConfigurations = $Configurations }
                            })
                        if (-not $IsUpdate) { $Body['scheduledActionsForRule'] = $Actions }
                    }

                    $TargetApps = $null
                    if ($Section -eq 'managedAppPolicies' -and -not $IsWip) {
                        $TargetApps = @{
                            apps = @(foreach ($App in @($Item.apps)) {
                                    if ($null -eq $App -or $null -eq $App.mobileAppIdentifier) { continue }
                                    @{ '@odata.type' = '#microsoft.graph.managedMobileApp'; mobileAppIdentifier = (ConvertTo-CIPPCloudBackupRestoreBody -Item $App.mobileAppIdentifier) }
                                })
                        }
                        if ($Item.appGroupType) { $TargetApps['appGroupType'] = [string]$Item.appGroupType }
                    }

                    $Assignable = $Section -notin 'roleScopeTags', 'assignmentFilters' -and $Row.Action -ne 'CreateCopy'
                    $SourceAssignments = @(@($Item.assignments).Where({ $null -ne $_ }))
                    $MissingExclusions = [System.Collections.Generic.List[string]]::new()
                    $NewAssignments = @(foreach ($Assignment in $SourceAssignments) {
                            if (-not $Assignable) { break }
                            $Copy = ConvertTo-CIPPCloudBackupRestoreBody -Item $Assignment -Remove 'id', 'source', 'sourceId'
                            $AssignTarget = $Copy['target']
                            if ($null -eq $AssignTarget) { continue }
                            $IsExclusion = [string]$AssignTarget['@odata.type'] -eq '#microsoft.graph.exclusionGroupAssignmentTarget'
                            if ($IsExclusion -or [string]$AssignTarget['@odata.type'] -eq '#microsoft.graph.groupAssignmentTarget') {
                                if ($ReferenceError) { throw "Could not look up the groups this item uses in the target: $ReferenceError" }
                                $GroupId = [string]$AssignTarget['groupId']
                                $Mapped = $References.Groups[$GroupId]
                                if (-not $Mapped) {
                                    $Missing = $References.Missing[$GroupId] ?? "Group $GroupId not found in the target"
                                    $Unmapped.Add($Missing)
                                    if ($IsExclusion) { $MissingExclusions.Add($Missing) }
                                    continue
                                }
                                $AssignTarget['groupId'] = $Mapped
                            }
                            $FilterId = [string]$AssignTarget['deviceAndAppManagementAssignmentFilterId']
                            if ($FilterId -and $FilterId -ne $EmptyGuid) {
                                $Mapped = if ($IdMap.assignmentFilters.ContainsKey($FilterId)) { $IdMap.assignmentFilters[$FilterId] } elseif ($SameTenant -and $ById.assignmentFilters.ContainsKey($FilterId)) { $FilterId }
                                if (-not $Mapped) {
                                    $Missing = "Assignment filter '$($NameOf.assignmentFilters[$FilterId] ?? $FilterId)' not found in the target"
                                    $Unmapped.Add("$Missing; the assignment that uses it was left out")
                                    if ($IsExclusion) { $MissingExclusions.Add($Missing) }
                                    continue
                                }
                                $AssignTarget['deviceAndAppManagementAssignmentFilterId'] = $Mapped
                            }
                            $Copy
                        })
                    if ($MissingExclusions.Count -gt 0) {
                        throw "Not restored because its exclusions are missing in the target, and without them it would apply to more devices or users: $($MissingExclusions -join '; ')"
                    }
                    $AllAssignmentsLost = $SourceAssignments.Count -gt 0 -and $NewAssignments.Count -eq 0
                    $Assign = $Assignable -and ($NewAssignments.Count -gt 0 -or ($IsUpdate -and $SourceAssignments.Count -eq 0))
                    $AssignmentNote = if ($Assignable -and $AllAssignmentsLost) {
                        if ($IsUpdate) { '; none of its assignments could be mapped, so its current assignments were left as they are' } else { '; none of its assignments could be mapped, so it is not assigned' }
                    }

                    if ($Apply) {
                        $Url = if ($Collection) { "$GraphBase/deviceAppManagement/$Collection" } else { "$GraphBase$($Paths[$Section])" }
                        $TargetId = if ($IsUpdate) { [string]$Match.id }
                        $Json = ConvertTo-Json -InputObject $Body -Depth 100 -Compress
                        switch ($Section) {
                            'intents' {
                                if ($IsUpdate) {
                                    $null = New-GraphPOSTRequest -uri "$Url/$TargetId" -tenantid $TargetTenantFilter -type PATCH -body $Json
                                    $Written = 'Updated'
                                    $SettingsJson = ConvertTo-Json -InputObject @{ settings = $Settings } -Depth 20 -Compress
                                    $null = New-GraphPOSTRequest -uri "$Url/$TargetId/updateSettings" -tenantid $TargetTenantFilter -type POST -body $SettingsJson
                                } else {
                                    $Body['settingsDelta'] = $Settings
                                    $Json = ConvertTo-Json -InputObject $Body -Depth 100 -Compress
                                    $TargetId = [string](New-GraphPOSTRequest -uri "$GraphBase/deviceManagement/templates/$($Item.templateId)/createInstance" -tenantid $TargetTenantFilter -type POST -body $Json).id
                                }
                            }
                            'groupPolicyConfigurations' {
                                $Definitions = Resolve-CIPPIntuneAdminTemplateBinding -RawJSON $Definitions -TenantFilter $TargetTenantFilter -DisplayName $NewName
                                if ($IsUpdate) {
                                    $ExistingByDefinition = @{}
                                    foreach ($Existing in @(New-GraphGetRequest -uri "$Url('$TargetId')/definitionValues?`$expand=definition(`$select=id)" -tenantid $TargetTenantFilter)) {
                                        if ($Existing.id -and $Existing.definition.id) { $ExistingByDefinition[[string]$Existing.definition.id] = $Existing }
                                    }
                                    $Payload = $Definitions | ConvertFrom-Json -AsHashtable -Depth 100
                                    $PresentationRequests = foreach ($Value in @($Payload['added'])) {
                                        $DefinitionId = ([regex]::Match([string]$Value['definition@odata.bind'], "groupPolicyDefinitions\('([^']+)'\)")).Groups[1].Value
                                        $Existing = $ExistingByDefinition[$DefinitionId]
                                        if ($Existing) {
                                            @{ id = [string]$Existing.id; method = 'GET'; url = "/deviceManagement/groupPolicyConfigurations('$TargetId')/definitionValues('$($Existing.id)')/presentationValues?`$expand=presentation" }
                                        }
                                    }
                                    $ExistingPresentations = @{}
                                    if (@($PresentationRequests).Count -gt 0) {
                                        foreach ($Response in @(New-GraphBulkRequest -tenantid $TargetTenantFilter -Requests @($PresentationRequests))) {
                                            $Status = $Response.status -as [int]
                                            if ($Status -lt 200 -or $Status -ge 300) { throw "Could not read the target policy's current settings: $($Response.body.error.message ?? "HTTP $Status")" }
                                            $PresentationIds = @{}
                                            foreach ($PresentationValue in @($Response.body.value)) { if ($PresentationValue.presentation.id) { $PresentationIds[[string]$PresentationValue.presentation.id] = [string]$PresentationValue.id } }
                                            $ExistingPresentations[[string]$Response.id] = $PresentationIds
                                        }
                                    }
                                    $Kept = [System.Collections.Generic.HashSet[string]]::new()
                                    $AddedValues = [System.Collections.Generic.List[object]]::new()
                                    $UpdatedValues = [System.Collections.Generic.List[object]]::new()
                                    foreach ($Value in @($Payload['added'])) {
                                        $DefinitionId = ([regex]::Match([string]$Value['definition@odata.bind'], "groupPolicyDefinitions\('([^']+)'\)")).Groups[1].Value
                                        $Existing = $ExistingByDefinition[$DefinitionId]
                                        if (-not $Existing) { $AddedValues.Add($Value); continue }
                                        $ExistingId = [string]$Existing.id
                                        if (-not $ExistingPresentations.ContainsKey($ExistingId)) { throw "Could not read the target policy's current settings for definition $DefinitionId" }
                                        [void]$Kept.Add($ExistingId)
                                        $Value['id'] = $ExistingId
                                        $Value.Remove('definition@odata.bind')
                                        foreach ($PresentationValue in @($Value['presentationValues'])) {
                                            $PresentationId = ([regex]::Match([string]$PresentationValue['presentation@odata.bind'], "presentations\('([^']+)'\)")).Groups[1].Value
                                            $ExistingPresentationId = $ExistingPresentations[$ExistingId][$PresentationId]
                                            if ($ExistingPresentationId) {
                                                $PresentationValue['id'] = $ExistingPresentationId
                                                $PresentationValue.Remove('presentation@odata.bind')
                                            }
                                        }
                                        $UpdatedValues.Add($Value)
                                    }
                                    $DeletedIds = @(foreach ($Existing in $ExistingByDefinition.Values) { if (-not $Kept.Contains([string]$Existing.id)) { [string]$Existing.id } })
                                    $Definitions = ConvertTo-Json -InputObject @{ added = @($AddedValues); updated = @($UpdatedValues); deletedIds = $DeletedIds } -Depth 100 -Compress
                                    $null = New-GraphPOSTRequest -uri "$Url('$TargetId')" -tenantid $TargetTenantFilter -type PATCH -body $Json
                                    $Written = 'Updated'
                                } else {
                                    $TargetId = [string](New-GraphPOSTRequest -uri $Url -tenantid $TargetTenantFilter -type POST -body $Json).id
                                    if ($TargetId) { $Written = $CreatedText }
                                }
                                if ($TargetId) { $null = New-GraphPOSTRequest -uri "$Url('$TargetId')/updateDefinitionValues" -tenantid $TargetTenantFilter -type POST -body $Definitions }
                            }
                            default {
                                if ($IsUpdate) {
                                    $UpdateType = if ($Section -eq 'configurationPolicies') { 'PUT' } else { 'PATCH' }
                                    $null = New-GraphPOSTRequest -uri "$Url/$TargetId" -tenantid $TargetTenantFilter -type $UpdateType -body $Json
                                    $Written = 'Updated'
                                    if ($Section -eq 'deviceCompliancePolicies') {
                                        $ActionsJson = ConvertTo-Json -InputObject @{ deviceComplianceScheduledActionForRules = $Actions } -Depth 20 -Compress
                                        $null = New-GraphPOSTRequest -uri "$Url/$TargetId/scheduleActionsForRules" -tenantid $TargetTenantFilter -type POST -body $ActionsJson
                                    }
                                } else {
                                    $TargetId = [string](New-GraphPOSTRequest -uri $Url -tenantid $TargetTenantFilter -type POST -body $Json).id
                                }
                            }
                        }
                        if (-not $TargetId) { throw 'Graph did not return the new item' }
                        if (-not $Written) { $Written = $CreatedText }

                        if ($TargetApps) {
                            $AppsJson = ConvertTo-Json -InputObject $TargetApps -Depth 20 -Compress
                            $null = New-GraphPOSTRequest -uri "$Url/$TargetId/targetApps" -tenantid $TargetTenantFilter -type POST -body $AppsJson
                        }
                        if ($Assign) {
                            $AssignProperty = switch ($Section) {
                                'deviceHealthScripts' { 'deviceHealthScriptAssignments' }
                                { $_ -in 'deviceManagementScripts', 'deviceShellScripts' } { 'deviceManagementScriptAssignments' }
                                default { 'assignments' }
                            }
                            $AssignJson = ConvertTo-Json -InputObject @{ $AssignProperty = $NewAssignments } -Depth 20 -Compress
                            $null = New-GraphPOSTRequest -uri "$Url/$TargetId/assign" -tenantid $TargetTenantFilter -type POST -body $AssignJson
                        }
                        if ($IdMap.ContainsKey($Section)) { $IdMap[$Section][$SourceId] = $TargetId }
                        $Row.Status = 'Succeeded'
                        $Row.Message = "$Written$AssignmentNote"
                    } else {
                        if ($IdMap.ContainsKey($Section)) { $IdMap[$Section][$SourceId] = if ($IsUpdate) { [string]$Match.id } else { "planned:$SourceId" } }
                        $Row.Status = 'Planned'
                        $Planned = switch ($Row.Action) {
                            'Update' { 'Will update the existing item' }
                            'CreateCopy' { "Will be created as $CopyKind '$NewName'" }
                            default { 'Will be created' }
                        }
                        $Row.Message = "$Planned$AssignmentNote"
                    }
                }
            }
        } catch {
            $Row.Status = 'Failed'
            $ErrorText = Get-NormalizedError -Message $_.Exception.Message
            $Row.Message = if ($Written) { "$Written, but the rest of the restore failed: $ErrorText" } else { $ErrorText }
        }
        $Row.Unmapped = [string[]]@($Unmapped)
        $Results.Add([pscustomobject]$Row)
    }
    $Results.ToArray()
}
