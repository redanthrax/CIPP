BeforeAll {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    $CloudBackup = Join-Path $RepoRoot 'Modules/CIPPCore/Public/CloudBackup'
    . (Join-Path $CloudBackup 'ConvertTo-CIPPCloudBackupRestoreBody.ps1')
    . (Join-Path $CloudBackup 'Resolve-CIPPCloudBackupReference.ps1')
    . (Join-Path $CloudBackup 'Restore-CIPPCloudBackupIntune.ps1')

    function Get-Tenants { param($TenantFilter) }
    function Get-CIPPCloudBackupItemInfo { param($Section, $Item) }
    function Get-CIPPCloudBackupSectionLabel { param($Section) }
    function Get-NormalizedError { param($Message) }
    function New-GraphBulkRequest { param($tenantid, $asapp, $Requests, $MaxConcurrency) }
    function New-GraphPOSTRequest { param($uri, $tenantid, $body, $type, $AsApp) }
    function New-GraphGetRequest { param($uri, $tenantid, $AsApp) }
    function Resolve-CIPPIntuneAdminTemplateBinding { param($RawJSON, $TenantFilter, $DisplayName, $Headers, $APIName) }

    $script:Source = 'aaaaaaaa-0000-0000-0000-000000000001'
    $script:Target = 'target.onmicrosoft.com'
    $script:G1 = '10000000-0000-0000-0000-000000000001'
    $script:G2 = '10000000-0000-0000-0000-000000000002'
    $script:F1 = '60000000-0000-0000-0000-000000000001'
    $script:D1 = '70000000-0000-0000-0000-000000000001'
    $script:PR = '71000000-0000-0000-0000-000000000001'
    $script:T1 = '80000000-0000-0000-0000-000000000001'
    $script:TPL = '90000000-0000-0000-0000-000000000001'
    $script:Today = [datetime]::UtcNow.ToString('yyyy-MM-dd')
    $script:Graph = 'https://graph.microsoft.com/beta'

    function script:New-Snapshot {
        param([string]$OmaValue = 'plain')
        $Json = @"
{
  "roleScopeTags": [
    { "id": "0", "displayName": "Default", "isBuiltIn": true },
    { "id": "5", "displayName": "Branch", "description": "b", "isBuiltIn": false }
  ],
  "assignmentFilters": [
    { "id": "$script:F1", "displayName": "Corp devices", "platform": "windows10AndLater", "rule": "(device.deviceOwnership -eq \"Corporate\")",
      "roleScopeTags": [ "5" ], "payloads": [], "createdDateTime": "2024-01-01T00:00:00Z" }
  ],
  "deviceConfigurations": [
    { "@odata.type": "#microsoft.graph.windows10CustomConfiguration", "id": "dc1", "displayName": "Custom OMA", "version": 3,
      "createdDateTime": "2024-01-01T00:00:00Z", "lastModifiedDateTime": "2024-01-02T00:00:00Z", "supportsScopeTags": true,
      "roleScopeTagIds": [ "5" ], "assignments@odata.context": "ctx",
      "omaSettings": [ { "@odata.type": "#microsoft.graph.omaSettingString", "displayName": "s", "omaUri": "./x", "value": "$OmaValue" } ],
      "assignments": [ { "id": "a1", "target": { "@odata.type": "#microsoft.graph.groupAssignmentTarget", "groupId": "$script:G1",
        "deviceAndAppManagementAssignmentFilterId": "$script:F1", "deviceAndAppManagementAssignmentFilterType": "include" } } ] },
    { "@odata.type": "#microsoft.graph.windows10CustomConfiguration", "id": "dc2", "displayName": "Masked OMA",
      "omaSettings": [ { "@odata.type": "#microsoft.graph.omaSettingString", "displayName": "secret", "omaUri": "./y", "value": "(encrypted)", "secretReferenceValueId": "ref", "isEncrypted": true } ],
      "assignments": [] }
  ],
  "configurationPolicies": [
    { "id": "cp1", "name": "Catalog", "description": "", "platforms": "windows10", "technologies": "mdm", "roleScopeTagIds": [ "0" ],
      "settingCount": 1, "isAssigned": true, "creationSource": null, "priorityMetaData": null, "createdDateTime": "2024-01-01T00:00:00Z",
      "templateReference": { "templateId": "", "templateFamily": "none" }, "settings@odata.context": "ctx",
      "settings": [ { "id": "0", "settingInstance": { "@odata.type": "#microsoft.graph.deviceManagementConfigurationChoiceSettingInstance",
        "settingDefinitionId": "x", "choiceSettingValue": { "value": "x_1", "children": [] } } } ],
      "assignments": [ { "id": "a1", "source": "direct", "sourceId": "cp1", "target": { "@odata.type": "#microsoft.graph.exclusionGroupAssignmentTarget", "groupId": "$script:G2" } } ] }
  ],
  "groupPolicyConfigurations": [
    { "id": "gp1", "displayName": "Admin", "description": "", "roleScopeTagIds": [ "0" ], "assignments": [],
      "definitionValues": [ { "id": "dv1", "enabled": true,
        "definition": { "id": "$script:D1", "displayName": "Setting", "categoryPath": "\\Cat", "classType": "machine", "policyType": "admxBacked" },
        "presentationValues": [ { "id": "pv1", "@odata.type": "#microsoft.graph.groupPolicyPresentationValueText", "value": "hello",
          "presentation": { "id": "$script:PR", "label": "Text", "@odata.type": "#microsoft.graph.groupPolicyPresentationTextBox" } } ] } ] }
  ],
  "deviceCompliancePolicies": [
    { "@odata.type": "#microsoft.graph.windows10CompliancePolicy", "id": "cmp1", "displayName": "Compliance", "version": 2, "passwordRequired": true,
      "scheduledActionsForRule@odata.context": "ctx",
      "scheduledActionsForRule": [ { "id": "r1", "ruleName": "PasswordRequired", "scheduledActionConfigurations@odata.context": "ctx",
        "scheduledActionConfigurations": [
          { "id": "c1", "actionType": "block", "gracePeriodHours": 0, "notificationTemplateId": "", "notificationMessageCCList": [] },
          { "id": "c2", "actionType": "notification", "gracePeriodHours": 24, "notificationTemplateId": "$script:T1", "notificationMessageCCList": [ "$script:G1" ] } ] } ],
      "assignments": [ { "id": "a1", "target": { "@odata.type": "#microsoft.graph.allDevicesAssignmentTarget" } } ] }
  ],
  "managedAppPolicies": [
    { "@odata.type": "#microsoft.graph.iosManagedAppProtection", "id": "ios1", "displayName": "iOS MAM", "version": "1", "isAssigned": true,
      "deployedAppCount": 1, "appGroupType": "selectedPublicApps", "apps@odata.context": "ctx",
      "apps": [ { "id": "com.microsoft.outlook.ios", "version": "1", "mobileAppIdentifier": { "@odata.type": "#microsoft.graph.iosMobileAppIdentifier", "bundleId": "com.microsoft.outlook" } } ],
      "assignments": [ { "id": "a1", "source": "direct", "sourceId": "ios1", "target": { "@odata.type": "#microsoft.graph.groupAssignmentTarget", "groupId": "$script:G1" } } ] },
    { "@odata.type": "#microsoft.graph.defaultManagedAppProtection", "id": "def1", "displayName": "Default" }
  ],
  "intents": [
    { "id": "in1", "displayName": "Defender", "description": "", "templateId": "$script:TPL", "isAssigned": false, "roleScopeTagIds": [ "0" ],
      "settings": [ { "@odata.type": "#microsoft.graph.deviceManagementBooleanSettingInstance", "id": "s1", "definitionId": "deviceConfiguration--x", "valueJson": "true", "value": true } ],
      "assignments": [ { "id": "a1", "target": { "@odata.type": "#microsoft.graph.groupAssignmentTarget", "groupId": "$script:G1" } } ] }
  ],
  "deviceManagementScripts": [
    { "id": "sc1", "displayName": "Script", "scriptContent": "YWJj", "runAsAccount": "system", "fileName": "a.ps1",
      "assignments": [ { "id": "a1", "target": { "@odata.type": "#microsoft.graph.groupAssignmentTarget", "groupId": "$script:G1" } } ] }
  ],
  "deviceHealthScripts": [
    { "id": "hs1", "displayName": "Remediate", "detectionScriptContent": "ZGV0", "remediationScriptContent": "cmVt", "isGlobalScript": false,
      "highestAvailableVersion": "1", "version": "1",
      "assignments": [ { "id": "a1", "runRemediationScript": true,
        "runSchedule": { "@odata.type": "#microsoft.graph.deviceHealthScriptDailySchedule", "interval": 1, "time": "01:00:00", "useUtc": false },
        "target": { "@odata.type": "#microsoft.graph.groupAssignmentTarget", "groupId": "$script:G1" } } ] },
    { "id": "hs2", "displayName": "Published by Microsoft", "isGlobalScript": true, "detectionScriptContent": "eA==" }
  ]
}
"@
        $Parsed = $Json | ConvertFrom-Json
        $Sections = [ordered]@{}
        foreach ($Property in $Parsed.PSObject.Properties) { $Sections[$Property.Name] = [object[]]@($Property.Value) }
        [pscustomobject]@{ Sections = $Sections; References = @{ Groups = @{ $script:G1 = 'Sales'; $script:G2 = 'Contractors' }; Users = @{} } }
    }

    function script:Get-Write {
        param([string]$Uri, [string]$Type)
        @($script:Writes).Where({ $_.Uri -eq $Uri -and (-not $Type -or $_.Type -eq $Type) })
    }

    function script:Invoke-Restore {
        param([hashtable]$Splat)
        Restore-CIPPCloudBackupIntune -Snapshot (New-Snapshot) -SourceTenantId $script:Source -TargetTenantFilter $script:Target @Splat
    }
}

Describe 'Restore-CIPPCloudBackupIntune' {
    BeforeEach {
        $script:Writes = [System.Collections.Generic.List[object]]::new()
        $script:BulkCalls = [System.Collections.Generic.List[object]]::new()
        $script:NewId = 0
        $script:FailUri = $null
        $script:TargetCustomerId = 'bbbbbbbb-0000-0000-0000-000000000001'
        $script:Live = @{}
        $script:TargetGroups = @([pscustomobject]@{ id = 'g-tgt-1'; displayName = 'Sales' }, [pscustomobject]@{ id = 'g-tgt-2'; displayName = 'Contractors' })

        Mock Get-Tenants { [pscustomobject]@{ customerId = $script:TargetCustomerId; defaultDomainName = $script:Target } }
        Mock Get-CIPPCloudBackupItemInfo { foreach ($One in @($Item)) { [pscustomobject]@{ Key = [string]$One.id; Name = [string]($One.displayName ?? $One.name ?? $One.id) } } }
        Mock Get-CIPPCloudBackupSectionLabel { "label $Section" }
        Mock Get-NormalizedError { $Message }
        Mock Resolve-CIPPIntuneAdminTemplateBinding { $RawJSON }
        Mock New-GraphGetRequest {
            [pscustomobject]@{ id = 'old-dv'; definition = [pscustomobject]@{ id = $script:D1 } }
            [pscustomobject]@{ id = 'old-dv2'; definition = [pscustomobject]@{ id = 'other-definition' } }
        }
        Mock New-GraphPOSTRequest {
            $script:Writes.Add([pscustomobject]@{ Uri = $uri; Type = $type; Body = ($body | ConvertFrom-Json -AsHashtable -Depth 100); Raw = $body; Tenant = $tenantid })
            if ($script:FailUri -and $uri -like $script:FailUri) { throw 'Graph refused the request' }
            $script:NewId++
            [pscustomobject]@{ id = "new-$script:NewId" }
        }
        Mock New-GraphBulkRequest {
            $script:BulkCalls.Add([pscustomobject]@{ Requests = @($Requests); Tenant = $tenantid })
            foreach ($Request in $Requests) {
                $Url = [string]$Request.url
                if ($Url -match "^/groups\?\`$filter=displayName eq '(.+)'&") {
                    $Name = [uri]::UnescapeDataString($Matches[1])
                    [pscustomobject]@{ id = $Request.id; status = 200; body = [pscustomobject]@{ value = @($script:TargetGroups.Where({ $_.displayName -eq $Name })) } }
                } elseif ($Url -like '*/presentationValues*') {
                    [pscustomobject]@{ id = $Request.id; status = 200; body = [pscustomobject]@{ value = @([pscustomobject]@{ id = 'old-pv'; presentation = [pscustomobject]@{ id = $script:PR } }) } }
                } elseif ($Url -match '^/groups/([^?]+)\?') {
                    $Id = $Matches[1]
                    if ($script:TargetGroups.Where({ $_.id -eq $Id }).Count) { [pscustomobject]@{ id = $Request.id; status = 200; body = [pscustomobject]@{ id = $Id } } }
                    else { [pscustomobject]@{ id = $Request.id; status = 404; body = [pscustomobject]@{ error = [pscustomobject]@{ message = 'not found' } } } }
                } else {
                    [pscustomobject]@{ id = $Request.id; status = 200; body = [pscustomobject]@{ value = @($script:Live[$Url]) } }
                }
            }
        }
    }

    It 'makes no writes in preview and refuses what cannot be restored' {
        $script:TargetGroups = @([pscustomobject]@{ id = 'g-tgt-1'; displayName = 'Sales' })
        $Rows = Invoke-Restore @{ ConflictAction = 'Overwrite' }

        Should -Invoke New-GraphPOSTRequest -Times 0 -Exactly
        Should -Invoke New-GraphGetRequest -Times 0 -Exactly
        Should -Invoke Resolve-CIPPIntuneAdminTemplateBinding -Times 0 -Exactly
        @($script:BulkCalls.Requests).Where({ $_.method -ne 'GET' }).Count | Should -Be 0
        $Rows.Count | Should -Be 14
        $Rows.Where({ $_.Key -eq '0' })[0].Action | Should -Be 'Skip'
        foreach ($Key in 'dc2', 'def1', 'hs2') {
            $Row = $Rows.Where({ $_.Key -eq $Key })[0]
            $Row.Action | Should -Be 'NotRestorable'
            $Row.Status | Should -Be 'Skipped'
        }
        $Rows.Where({ $_.Key -eq 'dc2' })[0].Message | Should -BeLike '*not in this backup because the backup policy does not use encryption'
        @($Rows.Where({ $_.Status -eq 'Planned' })).Count | Should -Be 9
        $Catalog = $Rows.Where({ $_.Key -eq 'cp1' })[0]
        $Catalog.Status | Should -Be 'Failed'
        $Catalog.Message | Should -Be "Not restored because its exclusions are missing in the target, and without them it would apply to more devices or users: Group 'Contractors' not found in the target"
    }

    It 'restores every type to another tenant with the documented request shapes' {
        $Rows = Invoke-Restore @{ ConflictAction = 'Skip'; Apply = $true }

        @($Rows.Where({ $_.Status -eq 'Failed' })).Count | Should -Be 0
        @($script:Writes.Where({ $_.Tenant -ne $script:Target })).Count | Should -Be 0

        $Tag = Get-Write "$script:Graph/deviceManagement/roleScopeTags" POST
        $Tag[0].Body.Keys | Should -Not -Contain 'isBuiltIn'
        $TagId = 'new-1'
        $Filter = (Get-Write "$script:Graph/deviceManagement/assignmentFilters" POST)[0].Body
        $Filter.roleScopeTags | Should -Be @($TagId)
        $Filter.Keys | Should -Not -Contain 'payloads'
        $FilterId = 'new-2'

        $Config = (Get-Write "$script:Graph/deviceManagement/deviceConfigurations" POST)[0].Body
        $Config['@odata.type'] | Should -Be '#microsoft.graph.windows10CustomConfiguration'
        foreach ($Property in 'id', 'version', 'assignments', 'createdDateTime', 'supportsScopeTags', 'assignments@odata.context') { $Config.Keys | Should -Not -Contain $Property }
        $Config.roleScopeTagIds | Should -Be @($TagId)
        $ConfigAssign = (Get-Write "$script:Graph/deviceManagement/deviceConfigurations/new-3/assign" POST)[0].Body
        $ConfigAssign.assignments.Count | Should -Be 1
        $ConfigAssign.assignments[0].target.groupId | Should -Be 'g-tgt-1'
        $ConfigAssign.assignments[0].target.deviceAndAppManagementAssignmentFilterId | Should -Be $FilterId
        $ConfigAssign.assignments[0].Keys | Should -Not -Contain 'id'

        $Catalog = (Get-Write "$script:Graph/deviceManagement/configurationPolicies" POST)[0].Body
        @($Catalog.Keys | Sort-Object) | Should -Be @('description', 'name', 'platforms', 'roleScopeTagIds', 'settings', 'technologies', 'templateReference')
        $Catalog.settings[0].settingInstance.choiceSettingValue.value | Should -Be 'x_1'
        @($script:Writes.Where({ $_.Uri -like '*configurationPolicies/*/assign' }))[0].Body.assignments[0].target.groupId | Should -Be 'g-tgt-2'

        $Admin = Get-Write "$script:Graph/deviceManagement/groupPolicyConfigurations" POST
        $Admin[0].Body.displayName | Should -Be 'Admin'
        $Admin[0].Body.Keys | Should -Not -Contain 'definitionValues'
        $AdminId = [string]$script:Writes[$script:Writes.IndexOf($Admin[0]) + 1].Uri
        $AdminId | Should -BeLike "*groupPolicyConfigurations('new-*')/updateDefinitionValues"
        $Values = $script:Writes[$script:Writes.IndexOf($Admin[0]) + 1].Body
        $Values.added[0].'definition@odata.bind' | Should -Be "$script:Graph/deviceManagement/groupPolicyDefinitions('$script:D1')"
        $Values.added[0].presentationValues[0].'presentation@odata.bind' | Should -Be "$script:Graph/deviceManagement/groupPolicyDefinitions('$script:D1')/presentations('$script:PR')"
        $Values.added[0].presentationValues[0].value | Should -Be 'hello'
        $Values.added[0].definition.displayName | Should -Be 'Setting'
        Should -Invoke Resolve-CIPPIntuneAdminTemplateBinding -Times 1 -Exactly -ParameterFilter { $TenantFilter -eq $script:Target }

        $Compliance = (Get-Write "$script:Graph/deviceManagement/deviceCompliancePolicies" POST)[0].Body
        $Compliance.scheduledActionsForRule.Count | Should -Be 1
        $Compliance.scheduledActionsForRule[0].Keys | Should -Not -Contain 'id'
        $Compliance.scheduledActionsForRule[0].scheduledActionConfigurations.Count | Should -Be 1
        $Compliance.scheduledActionsForRule[0].scheduledActionConfigurations[0].actionType | Should -Be 'block'
        $Compliance.Keys | Should -Not -Contain 'scheduledActionsForRule@odata.context'
        $Rows.Where({ $_.Key -eq 'cmp1' })[0].Unmapped[0] | Should -BeLike "Notification message template $script:T1 belongs to the source tenant*"

        $App = Get-Write "$script:Graph/deviceAppManagement/iosManagedAppProtections" POST
        $App[0].Body.Keys | Should -Not -Contain 'apps'
        $App[0].Body.Keys | Should -Not -Contain 'deployedAppCount'
        $AppId = ([string]$script:Writes[$script:Writes.IndexOf($App[0]) + 1].Uri) -replace '.*/iosManagedAppProtections/([^/]+)/targetApps$', '$1'
        $Targets = (Get-Write "$script:Graph/deviceAppManagement/iosManagedAppProtections/$AppId/targetApps" POST)[0].Body
        $Targets.appGroupType | Should -Be 'selectedPublicApps'
        $Targets.apps[0].mobileAppIdentifier.bundleId | Should -Be 'com.microsoft.outlook'
        $Targets.apps[0]['@odata.type'] | Should -Be '#microsoft.graph.managedMobileApp'
        (Get-Write "$script:Graph/deviceAppManagement/iosManagedAppProtections/$AppId/assign" POST)[0].Body.assignments[0].target.groupId | Should -Be 'g-tgt-1'

        $Intent = (Get-Write "$script:Graph/deviceManagement/templates/$script:TPL/createInstance" POST)[0].Body
        $Intent.displayName | Should -Be 'Defender'
        $Intent.settingsDelta.Count | Should -Be 1
        @($Intent.settingsDelta[0].Keys | Sort-Object) | Should -Be @('@odata.type', 'definitionId', 'valueJson')
        @($script:Writes.Where({ $_.Uri -like "$script:Graph/deviceManagement/intents/new-*/assign" })).Count | Should -Be 1

        $Script = @($script:Writes.Where({ $_.Uri -like "$script:Graph/deviceManagement/deviceManagementScripts/*/assign" }))[0].Body
        $Script.deviceManagementScriptAssignments[0].target.groupId | Should -Be 'g-tgt-1'
        $HealthBody = (Get-Write "$script:Graph/deviceManagement/deviceHealthScripts" POST)[0].Body
        $HealthBody.Keys | Should -Not -Contain 'isGlobalScript'
        $HealthBody.Keys | Should -Not -Contain 'highestAvailableVersion'
        $Health = @($script:Writes.Where({ $_.Uri -like "$script:Graph/deviceManagement/deviceHealthScripts/*/assign" }))[0].Body
        $Health.deviceHealthScriptAssignments[0].runRemediationScript | Should -BeTrue
        $Health.deviceHealthScriptAssignments[0].runSchedule.interval | Should -Be 1

        @($script:Writes.Where({ $_.Uri -like '*deviceConfigurations*' -and $_.Body.displayName -eq 'Masked OMA' })).Count | Should -Be 0
    }

    It 'updates matched items in the same tenant with each type''s update call' {
        $script:TargetCustomerId = $script:Source
        $script:TargetGroups = @([pscustomobject]@{ id = $script:G1 }, [pscustomobject]@{ id = $script:G2 })
        $script:Live['/deviceManagement/configurationPolicies'] = @([pscustomobject]@{ id = 'cp1'; name = 'Catalog' })
        $script:Live['/deviceManagement/groupPolicyConfigurations'] = @([pscustomobject]@{ id = 'gp1'; displayName = 'Admin' })
        $script:Live['/deviceManagement/deviceCompliancePolicies'] = @([pscustomobject]@{ id = 'cmp1'; displayName = 'Compliance'; '@odata.type' = '#microsoft.graph.windows10CompliancePolicy' })
        $script:Live['/deviceManagement/intents'] = @([pscustomobject]@{ id = 'in1'; displayName = 'Defender' })
        $Items = @(
            @{ Section = 'configurationPolicies'; Key = 'cp1' }, @{ Section = 'groupPolicyConfigurations'; Key = 'gp1' }
            @{ Section = 'deviceCompliancePolicies'; Key = 'cmp1' }, @{ Section = 'intents'; Key = 'in1' }
        )
        $Rows = Invoke-Restore @{ ConflictAction = 'Overwrite'; Apply = $true; Items = $Items }

        $Rows.Count | Should -Be 4
        @($Rows.Action | Select-Object -Unique) | Should -Be @('Update')
        @($Rows.Status | Select-Object -Unique) | Should -Be @('Succeeded')

        (Get-Write "$script:Graph/deviceManagement/configurationPolicies/cp1" PUT).Count | Should -Be 1
        (Get-Write "$script:Graph/deviceManagement/configurationPolicies/cp1" PUT)[0].Raw | Should -BeLike '*"roleScopeTagIds":`["0"`]*'
        (Get-Write "$script:Graph/deviceManagement/configurationPolicies/cp1/assign" POST)[0].Body.assignments[0].target.groupId | Should -Be $script:G2

        (Get-Write "$script:Graph/deviceManagement/groupPolicyConfigurations('gp1')" PATCH).Count | Should -Be 1
        $Definitions = Get-Write "$script:Graph/deviceManagement/groupPolicyConfigurations('gp1')/updateDefinitionValues" POST
        $Definitions.Count | Should -Be 1
        $Values = $Definitions[0].Body
        $Values.added.Count | Should -Be 0
        $Values.deletedIds | Should -Be @('old-dv2')
        $Values.updated.Count | Should -Be 1
        $Values.updated[0].id | Should -Be 'old-dv'
        $Values.updated[0].enabled | Should -BeTrue
        $Values.updated[0].Keys | Should -Not -Contain 'definition@odata.bind'
        $Values.updated[0].presentationValues[0].id | Should -Be 'old-pv'
        $Values.updated[0].presentationValues[0].value | Should -Be 'hello'
        $Values.updated[0].presentationValues[0].Keys | Should -Not -Contain 'presentation@odata.bind'
        Should -Invoke New-GraphBulkRequest -Times 1 -Exactly -ParameterFilter { @($Requests).Count -eq 1 -and $Requests[0].url -eq "/deviceManagement/groupPolicyConfigurations('gp1')/definitionValues('old-dv')/presentationValues?`$expand=presentation" }
        Should -Invoke New-GraphGetRequest -Times 1 -Exactly -ParameterFilter { $uri -like "*groupPolicyConfigurations('gp1')/definitionValues*" -and $tenantid -eq $script:Target }
        (Get-Write "$script:Graph/deviceManagement/groupPolicyConfigurations/gp1/assign" POST)[0].Body.assignments.Count | Should -Be 0

        $Compliance = (Get-Write "$script:Graph/deviceManagement/deviceCompliancePolicies/cmp1" PATCH)[0].Body
        $Compliance.Keys | Should -Not -Contain 'scheduledActionsForRule'
        $Compliance['@odata.type'] | Should -Be '#microsoft.graph.windows10CompliancePolicy'
        $Actions = (Get-Write "$script:Graph/deviceManagement/deviceCompliancePolicies/cmp1/scheduleActionsForRules" POST)[0].Body
        $Actions.deviceComplianceScheduledActionForRules[0].scheduledActionConfigurations.Count | Should -Be 2
        $Actions.deviceComplianceScheduledActionForRules[0].scheduledActionConfigurations[1].notificationMessageCCList | Should -Be @($script:G1)

        (Get-Write "$script:Graph/deviceManagement/intents/in1" PATCH)[0].Body.displayName | Should -Be 'Defender'
        (Get-Write "$script:Graph/deviceManagement/intents/in1/updateSettings" POST)[0].Body.settings[0].definitionId | Should -Be 'deviceConfiguration--x'
    }

    It 'skips or copies matched items as chosen' {
        $script:TargetCustomerId = $script:Source
        $script:Live['/deviceManagement/configurationPolicies'] = @([pscustomobject]@{ id = 'cp1'; name = 'Catalog' })
        $Items = @(@{ Section = 'configurationPolicies'; Key = 'cp1' })

        $Skip = Invoke-Restore @{ ConflictAction = 'Skip'; Apply = $true; Items = $Items }
        $Skip[0].Action | Should -Be 'Skip'
        $Skip[0].Status | Should -Be 'Skipped'
        $script:Writes.Count | Should -Be 0

        $Copy = Invoke-Restore @{ ConflictAction = 'Copy'; Apply = $true; Items = $Items }
        $Copy[0].Action | Should -Be 'CreateCopy'
        $Copy[0].Message | Should -Be "Created as an unassigned copy 'Catalog (restored $script:Today)'"
        (Get-Write "$script:Graph/deviceManagement/configurationPolicies" POST)[0].Body.name | Should -Be "Catalog (restored $script:Today)"
        @($script:Writes.Where({ $_.Uri -like '*/assign' })).Count | Should -Be 0

        $Preview = Invoke-Restore @{ ConflictAction = 'Copy'; Items = $Items }
        $Preview[0].Message | Should -Be "Will be created as an unassigned copy 'Catalog (restored $script:Today)'"
    }

    It 'matches typed items on name and type' {
        $script:Live['/deviceManagement/deviceConfigurations'] = @([pscustomobject]@{ id = 'other'; displayName = 'Custom OMA'; '@odata.type' = '#microsoft.graph.windows10GeneralConfiguration' })
        $Rows = Invoke-Restore @{ ConflictAction = 'Skip'; Items = @(@{ Section = 'deviceConfigurations'; Key = 'dc1' }) }
        $Rows[0].Action | Should -Be 'Create'
    }

    It 'fails an item whose exclusion filter is not in the target, in preview and on apply' -ForEach @(@{ Apply = $false }, @{ Apply = $true }) {
        $Snapshot = New-Snapshot
        $Snapshot.Sections['deviceConfigurations'][0].assignments[0].target.'@odata.type' = '#microsoft.graph.exclusionGroupAssignmentTarget'
        $Rows = Restore-CIPPCloudBackupIntune -Snapshot $Snapshot -SourceTenantId $script:Source -TargetTenantFilter $script:Target -ConflictAction Skip -Apply:$Apply -Items @(@{ Section = 'deviceConfigurations'; Key = 'dc1' })
        $Rows[0].Status | Should -Be 'Failed'
        $Rows[0].Message | Should -BeLike "Not restored because its exclusions are missing*Assignment filter 'Corp devices' not found in the target"
        Should -Invoke New-GraphPOSTRequest -Times 0 -Exactly
    }

    It 'drops an assignment whose filter is not in the target' {
        $Rows = Invoke-Restore @{ ConflictAction = 'Skip'; Apply = $true; Items = @(@{ Section = 'deviceConfigurations'; Key = 'dc1' }) }

        $Rows[0].Status | Should -Be 'Succeeded'
        $Rows[0].Unmapped | Should -Contain "Assignment filter 'Corp devices' not found in the target; the assignment that uses it was left out"
        $Rows[0].Unmapped | Should -Contain "Scope tag 'Branch' not found in the target"
        (Get-Write "$script:Graph/deviceManagement/deviceConfigurations" POST)[0].Body.roleScopeTagIds | Should -Be @('0')
        @($script:Writes.Where({ $_.Uri -like '*/assign' })).Count | Should -Be 0
    }

    It 'keeps going after one item fails and reports a partly applied item' {
        $script:FailUri = "$script:Graph/deviceManagement/deviceManagementScripts/*/assign"
        Mock New-GraphPOSTRequest {
            $script:Writes.Add([pscustomobject]@{ Uri = $uri; Type = $type })
            if ($uri -eq "$script:Graph/deviceManagement/deviceConfigurations" -or $uri -like $script:FailUri) { throw 'Graph refused the request' }
            $script:NewId++
            [pscustomobject]@{ id = "new-$script:NewId" }
        }
        $Rows = Invoke-Restore @{ ConflictAction = 'Skip'; Apply = $true }

        $Rows.Where({ $_.Key -eq 'dc1' })[0].Status | Should -Be 'Failed'
        $Rows.Where({ $_.Key -eq 'dc1' })[0].Message | Should -Be 'Graph refused the request'
        $Rows.Where({ $_.Key -eq 'sc1' })[0].Status | Should -Be 'Failed'
        $Rows.Where({ $_.Key -eq 'sc1' })[0].Message | Should -Be 'Created, but the rest of the restore failed: Graph refused the request'
        $Rows.Where({ $_.Key -eq 'hs1' })[0].Status | Should -Be 'Succeeded'
    }

    It 'refuses Intune''s encrypted placeholder as well as a masked value' {
        $Snapshot = New-Snapshot -OmaValue 'PGEvPg=='
        $Rows = Restore-CIPPCloudBackupIntune -Snapshot $Snapshot -SourceTenantId $script:Source -TargetTenantFilter $script:Target -ConflictAction Skip -Apply -Items @(@{ Section = 'deviceConfigurations'; Key = 'dc1' })
        $Rows[0].Action | Should -Be 'NotRestorable'
        $Rows[0].Message | Should -BeLike '*could not be read when the backup was made'
        Should -Invoke New-GraphPOSTRequest -Times 0 -Exactly
    }

    It 'refuses app configurations that target source-tenant apps in another tenant' {
        $Snapshot = New-Snapshot
        $Snapshot.Sections['mobileAppConfigurations'] = [object[]]@([pscustomobject]@{ id = 'mac1'; displayName = 'Outlook config'; '@odata.type' = '#microsoft.graph.iosMobileAppConfiguration'; targetedMobileApps = @('app-1') })
        $Rows = Restore-CIPPCloudBackupIntune -Snapshot $Snapshot -SourceTenantId $script:Source -TargetTenantFilter $script:Target -ConflictAction Skip -Apply -Items @(@{ Section = 'mobileAppConfigurations'; Key = 'mac1' })
        $Rows[0].Action | Should -Be 'NotRestorable'
        Should -Invoke New-GraphPOSTRequest -Times 0 -Exactly
    }
}
