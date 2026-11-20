BeforeAll {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    $CloudBackup = Join-Path $RepoRoot 'Modules/CIPPCore/Public/CloudBackup'
    . (Join-Path $CloudBackup 'ConvertTo-CIPPCloudBackupRestoreBody.ps1')
    . (Join-Path $CloudBackup 'Resolve-CIPPCloudBackupReference.ps1')
    . (Join-Path $CloudBackup 'Restore-CIPPCloudBackupConditionalAccess.ps1')

    function Get-Tenants { param($TenantFilter) }
    function Get-CIPPCloudBackupItemInfo { param($Section, $Item) }
    function Get-CIPPCloudBackupSectionLabel { param($Section) }
    function Get-NormalizedError { param($Message) }
    function New-GraphBulkRequest { param($tenantid, $asapp, $Requests, $MaxConcurrency) }
    function New-GraphPOSTRequest { param($uri, $tenantid, $body, $type, $AsApp) }
    function New-GraphGetRequest { param($uri, $tenantid, $AsApp) }

    $script:Source = 'aaaaaaaa-0000-0000-0000-000000000001'
    $script:Target = 'target.onmicrosoft.com'
    $script:G1 = '10000000-0000-0000-0000-000000000001'
    $script:G2 = '10000000-0000-0000-0000-000000000002'
    $script:U1 = '20000000-0000-0000-0000-000000000001'
    $script:NL = '30000000-0000-0000-0000-000000000001'
    $script:AS = '40000000-0000-0000-0000-000000000001'
    $script:P1 = '50000000-0000-0000-0000-000000000001'
    $script:BuiltIn = '00000000-0000-0000-0000-000000000002'
    $script:Today = [datetime]::UtcNow.ToString('yyyy-MM-dd')

    function script:New-Snapshot {
        param([string]$PolicyUsers)
        if (-not $PolicyUsers) {
            $PolicyUsers = "{ `"includeUsers`": [], `"excludeUsers`": [`"$script:U1`"], `"includeGroups`": [`"$script:G1`"], `"excludeGroups`": [`"$script:G2`"], `"includeRoles`": [], `"excludeRoles`": [] }"
        }
        $Json = @"
{
  "namedLocations": [
    { "@odata.type": "#microsoft.graph.ipNamedLocation", "id": "$script:NL", "displayName": "Office", "isTrusted": true,
      "createdDateTime": "2024-01-01T00:00:00Z", "modifiedDateTime": "2024-01-02T00:00:00Z",
      "ipRanges": [ { "@odata.type": "#microsoft.graph.iPv4CidrRange", "cidrAddress": "1.2.3.0/24" } ] }
  ],
  "authenticationStrengthPolicies": [
    { "id": "$script:BuiltIn", "displayName": "Multifactor authentication", "policyType": "builtIn", "allowedCombinations": [ "password,sms" ] },
    { "id": "$script:AS", "displayName": "Phish resistant", "description": "keys", "policyType": "custom", "requirementsSatisfied": "mfa",
      "allowedCombinations": [ "fido2", "windowsHelloForBusiness" ], "createdDateTime": "2024-01-01T00:00:00Z" }
  ],
  "authenticationContextClassReferences": [
    { "id": "c1", "displayName": "Sensitive", "description": "d", "isAvailable": true }
  ],
  "policies": [
    { "id": "$script:P1", "templateId": null, "displayName": "Require MFA", "state": "enabled",
      "createdDateTime": "2024-01-01T00:00:00Z", "modifiedDateTime": "2024-01-02T00:00:00Z",
      "conditions": {
        "users": $PolicyUsers,
        "locations": { "includeLocations": [ "All" ], "excludeLocations": [ "$script:NL" ] },
        "applications": { "includeApplications": [ "All" ], "excludeApplications": [], "includeUserActions": [], "includeAuthenticationContextClassReferences": [] }
      },
      "grantControls": { "operator": "OR", "builtInControls": [], "authenticationStrength@odata.context": "ctx",
        "authenticationStrength": { "id": "$script:AS", "displayName": "Phish resistant", "policyType": "custom" } },
      "sessionControls": null },
    { "id": "51000000-0000-0000-0000-000000000001", "displayName": "Sensitive apps", "state": "enabled",
      "conditions": {
        "users": { "includeUsers": [ "All" ], "excludeUsers": [] },
        "applications": { "includeApplications": [], "includeAuthenticationContextClassReferences": [ "c1" ] }
      },
      "grantControls": { "operator": "OR", "builtInControls": [ "mfa" ] } }
  ]
}
"@
        $Sections = [ordered]@{}
        $Parsed = $Json | ConvertFrom-Json
        foreach ($Name in 'namedLocations', 'authenticationStrengthPolicies', 'authenticationContextClassReferences', 'policies') { $Sections[$Name] = [object[]]@($Parsed.$Name) }
        [pscustomobject]@{
            Sections   = $Sections
            References = @{ Groups = @{ $script:G1 = 'Sales'; $script:G2 = 'BreakGlass' }; Users = @{ $script:U1 = 'admin@source.com' } }
        }
    }

    function script:Get-Write {
        param([string]$Uri, [string]$Type)
        @($script:Writes).Where({ $_.Uri -eq $Uri -and (-not $Type -or $_.Type -eq $Type) })
    }
}

Describe 'Restore-CIPPCloudBackupConditionalAccess' {
    BeforeEach {
        $script:Writes = [System.Collections.Generic.List[object]]::new()
        $script:BulkCalls = [System.Collections.Generic.List[object]]::new()
        $script:NewId = 0
        $script:FailUri = $null
        $script:TargetCustomerId = 'bbbbbbbb-0000-0000-0000-000000000001'
        $script:Live = @{
            '/identity/conditionalAccess/namedLocations'                       = @()
            '/identity/conditionalAccess/authenticationStrength/policies'      = @([pscustomobject]@{ id = $script:BuiltIn; displayName = 'Multifactor authentication'; policyType = 'builtIn' })
            '/identity/conditionalAccess/authenticationContextClassReferences' = @([pscustomobject]@{ id = 'c1'; displayName = 'Other' })
            '/identity/conditionalAccess/policies'                             = @()
        }
        $script:TargetGroups = @(
            [pscustomobject]@{ id = 'g-tgt-1'; displayName = 'Sales' }
            [pscustomobject]@{ id = 'g-tgt-2'; displayName = 'BreakGlass' }
        )
        $script:TargetUsers = @([pscustomobject]@{ id = 'u-tgt'; userPrincipalName = 'admin@source.com' })

        Mock Get-Tenants { [pscustomobject]@{ customerId = $script:TargetCustomerId; defaultDomainName = $script:Target } }
        Mock Get-CIPPCloudBackupItemInfo { foreach ($One in @($Item)) { [pscustomobject]@{ Key = [string]$One.id; Name = [string]($One.displayName ?? $One.name ?? $One.id) } } }
        Mock Get-CIPPCloudBackupSectionLabel { "label $Section" }
        Mock Get-NormalizedError { $Message }
        Mock New-GraphGetRequest { }
        Mock New-GraphPOSTRequest {
            $script:Writes.Add([pscustomobject]@{ Uri = $uri; Type = $type; Body = ($body | ConvertFrom-Json -AsHashtable -Depth 100); Tenant = $tenantid; AsApp = $AsApp })
            if ($script:FailUri -and $uri -like $script:FailUri) { throw 'Graph refused the request' }
            $script:NewId++
            [pscustomobject]@{ id = "new-$script:NewId" }
        }
        Mock New-GraphBulkRequest {
            $script:BulkCalls.Add([pscustomobject]@{ Requests = @($Requests); AsApp = $asapp; Tenant = $tenantid })
            foreach ($Request in $Requests) {
                $Url = [string]$Request.url
                if ($script:Live.ContainsKey($Url)) {
                    [pscustomobject]@{ id = $Request.id; status = 200; body = [pscustomobject]@{ value = @($script:Live[$Url]) } }
                } elseif ($Url -match "^/groups\?\`$filter=displayName eq '(.+)'&") {
                    $Name = [uri]::UnescapeDataString($Matches[1]).Replace("''", "'")
                    [pscustomobject]@{ id = $Request.id; status = 200; body = [pscustomobject]@{ value = @($script:TargetGroups.Where({ $_.displayName -eq $Name })) } }
                } elseif ($Url -match "^/users\?\`$filter=userPrincipalName eq '(.+)'&") {
                    $Name = [uri]::UnescapeDataString($Matches[1]).Replace("''", "'")
                    [pscustomobject]@{ id = $Request.id; status = 200; body = [pscustomobject]@{ value = @($script:TargetUsers.Where({ $_.userPrincipalName -eq $Name })) } }
                } elseif ($Url -match '^/(groups|users)/([^?]+)\?') {
                    $Id = $Matches[2]
                    $Found = @($script:TargetGroups) + @($script:TargetUsers) | Where-Object { $_.id -eq $Id }
                    if ($Found) { [pscustomobject]@{ id = $Request.id; status = 200; body = [pscustomobject]@{ id = $Id } } } else { [pscustomobject]@{ id = $Request.id; status = 404; body = [pscustomobject]@{ error = [pscustomobject]@{ message = 'not found' } } } }
                } else {
                    [pscustomobject]@{ id = $Request.id; status = 500; body = [pscustomobject]@{ error = [pscustomobject]@{ message = "unexpected $Url" } } }
                }
            }
        }
    }

    It 'makes no writes in preview and only GET reads' {
        $Rows = Restore-CIPPCloudBackupConditionalAccess -Snapshot (New-Snapshot) -SourceTenantId $script:Source -TargetTenantFilter $script:Target -ConflictAction Overwrite

        Should -Invoke New-GraphPOSTRequest -Times 0 -Exactly
        Should -Invoke New-GraphGetRequest -Times 0 -Exactly
        @($script:BulkCalls.Requests).Where({ $_.method -ne 'GET' }).Count | Should -Be 0
        $script:BulkCalls[0].AsApp | Should -BeTrue
        $script:BulkCalls[0].Tenant | Should -Be $script:Target
        $Rows.Count | Should -Be 6
        @($Rows.Where({ $_.Status -eq 'Planned' })).Count | Should -Be 5
        $Rows.Where({ $_.Key -eq $script:BuiltIn })[0].Action | Should -Be 'Skip'
    }

    It 'restores to another tenant, remapping named locations, strengths, contexts, groups and users' {
        $Rows = Restore-CIPPCloudBackupConditionalAccess -Snapshot (New-Snapshot) -SourceTenantId $script:Source -TargetTenantFilter $script:Target -ConflictAction Skip -CAState ReportOnly -Apply

        $Base = 'https://graph.microsoft.com/beta/identity/conditionalAccess'
        @($script:Writes.Where({ $_.AsApp -ne $true -or $_.Tenant -ne $script:Target })).Count | Should -Be 0

        $Location = (Get-Write "$Base/namedLocations" POST)[0].Body
        $Location.Keys | Should -Not -Contain 'id'
        $Location.Keys | Should -Not -Contain 'createdDateTime'
        $Location['@odata.type'] | Should -Be '#microsoft.graph.ipNamedLocation'

        $Strength = (Get-Write "$Base/authenticationStrength/policies" POST)[0].Body
        $Strength.allowedCombinations | Should -Be @('fido2', 'windowsHelloForBusiness')
        $Strength.Keys | Should -Not -Contain 'requirementsSatisfied'

        $Context = (Get-Write "$Base/authenticationContextClassReferences" POST)[0].Body
        $Context.id | Should -Be 'c2'
        $Context.displayName | Should -Be 'Sensitive'

        $Policies = Get-Write "$Base/policies" POST
        $Policies.Count | Should -Be 2
        $Policy = $Policies[0].Body
        $Policy.state | Should -Be 'enabledForReportingButNotEnforced'
        $Policy.Keys | Should -Not -Contain 'id'
        $Policy.Keys | Should -Not -Contain 'modifiedDateTime'
        $Policy.conditions.locations.excludeLocations | Should -Be @('new-1')
        $Policy.conditions.locations.includeLocations | Should -Be @('All')
        $Policy.grantControls.authenticationStrength.id | Should -Be 'new-2'
        $Policy.grantControls.authenticationStrength.Keys.Count | Should -Be 1
        $Policy.grantControls.Keys | Should -Not -Contain 'authenticationStrength@odata.context'
        $Policy.conditions.users.includeGroups | Should -Be @('g-tgt-1')
        $Policy.conditions.users.excludeGroups | Should -Be @('g-tgt-2')
        $Policy.conditions.users.excludeUsers | Should -Be @('u-tgt')
        $Policies[1].Body.conditions.applications.includeAuthenticationContextClassReferences | Should -Be @('c2')

        $PolicyRow = $Rows.Where({ $_.Key -eq $script:P1 })[0]
        $PolicyRow.Status | Should -Be 'Succeeded'
        $PolicyRow.Action | Should -Be 'Create'
        $PolicyRow.Unmapped.Count | Should -Be 0
        $Rows.Where({ $_.Key -eq $script:BuiltIn })[0].Status | Should -Be 'Skipped'
    }

    It 'looks groups and users up by exact name and UPN in another tenant' {
        $script:TargetUsers = @([pscustomobject]@{ id = 'u-tgt'; userPrincipalName = 'admin@source.com' })
        $null = Restore-CIPPCloudBackupConditionalAccess -Snapshot (New-Snapshot) -SourceTenantId $script:Source -TargetTenantFilter $script:Target -ConflictAction Skip -Apply

        $Lookups = @($script:BulkCalls[1].Requests.url)
        $Lookups | Should -Contain "/groups?`$filter=displayName eq 'Sales'&`$select=id,displayName&`$top=999"
        $Lookups | Should -Contain "/users?`$filter=userPrincipalName eq 'admin%40source.com'&`$select=id,userPrincipalName"
        $Policy = (Get-Write 'https://graph.microsoft.com/beta/identity/conditionalAccess/policies' POST)[0].Body
        $Policy.conditions.users.excludeUsers | Should -Be @('u-tgt')
        $Policy.state | Should -Be 'enabled'
    }

    It 'fails a policy whose exclusions cannot be mapped, in preview and on apply, whatever the state' -ForEach @(
        @{ State = 'AsBackedUp'; Apply = $false }, @{ State = 'ReportOnly'; Apply = $false }, @{ State = 'Disabled'; Apply = $false }, @{ State = 'AsBackedUp'; Apply = $true }
    ) {
        $script:TargetGroups = @(
            [pscustomobject]@{ id = 'g-tgt-1'; displayName = 'Sales' }
            [pscustomobject]@{ id = 'g-tgt-2a'; displayName = 'BreakGlass' }
            [pscustomobject]@{ id = 'g-tgt-2b'; displayName = 'BreakGlass' }
        )
        $script:TargetUsers = @()
        $Rows = Restore-CIPPCloudBackupConditionalAccess -Snapshot (New-Snapshot) -SourceTenantId $script:Source -TargetTenantFilter $script:Target -ConflictAction Skip -CAState $State -Apply:$Apply

        $Row = $Rows.Where({ $_.Key -eq $script:P1 })[0]
        $Row.Status | Should -Be 'Failed'
        $Row.Message | Should -BeLike 'Not restored because its exclusions are missing in the target*'
        $Row.Message | Should -BeLike "*Group 'BreakGlass' matches 2 groups in the target*"
        $Row.Message | Should -BeLike "*User 'admin@source.com' not found in the target*"
        (Get-Write 'https://graph.microsoft.com/beta/identity/conditionalAccess/policies' POST).Where({ $_.Body.displayName -eq 'Require MFA' }).Count | Should -Be 0
        $Rows.Where({ $_.Name -eq 'Sensitive apps' })[0].Status | Should -Be ($Apply ? 'Succeeded' : 'Planned')
    }

    It 'fails a policy whose excluded named location is missing' {
        $Rows = Restore-CIPPCloudBackupConditionalAccess -Snapshot (New-Snapshot) -SourceTenantId $script:Source -TargetTenantFilter $script:Target -ConflictAction Skip `
            -Items @(@{ Section = 'policies'; Key = $script:P1 })
        $Rows[0].Status | Should -Be 'Failed'
        $Rows[0].Message | Should -BeLike "*Named location 'Office' not found in the target*"
    }

    It 'fails a policy whose include side would become empty and keeps going' {
        $Users = "{ `"includeUsers`": [], `"includeGroups`": [`"$script:G2`"], `"excludeGroups`": [], `"includeRoles`": [] }"
        $script:TargetGroups = @([pscustomobject]@{ id = 'g-tgt-1'; displayName = 'Sales' })
        $Rows = Restore-CIPPCloudBackupConditionalAccess -Snapshot (New-Snapshot -PolicyUsers $Users) -SourceTenantId $script:Source -TargetTenantFilter $script:Target -ConflictAction Skip -Apply

        $Row = $Rows.Where({ $_.Key -eq $script:P1 })[0]
        $Row.Status | Should -Be 'Failed'
        $Row.Message | Should -BeLike 'None of the users and groups*'
        (Get-Write 'https://graph.microsoft.com/beta/identity/conditionalAccess/policies' POST).Count | Should -Be 1
        $Rows.Where({ $_.Name -eq 'Sensitive apps' })[0].Status | Should -Be 'Succeeded'
    }

    It 'fails a policy whose authentication strength could not be restored' {
        $script:FailUri = '*/authenticationStrength/policies'
        $Rows = Restore-CIPPCloudBackupConditionalAccess -Snapshot (New-Snapshot) -SourceTenantId $script:Source -TargetTenantFilter $script:Target -ConflictAction Skip -Apply

        $Rows.Where({ $_.Key -eq $script:AS })[0].Status | Should -Be 'Failed'
        $Row = $Rows.Where({ $_.Key -eq $script:P1 })[0]
        $Row.Status | Should -Be 'Failed'
        $Row.Message | Should -BeLike "*authentication strength 'Phish resistant'*"
    }

    It 'updates matched items in the same tenant by id' {
        $script:TargetCustomerId = $script:Source
        $script:TargetGroups = @([pscustomobject]@{ id = $script:G1 }, [pscustomobject]@{ id = $script:G2 })
        $script:TargetUsers = @([pscustomobject]@{ id = $script:U1 })
        $script:Live['/identity/conditionalAccess/namedLocations'] = @([pscustomobject]@{ id = $script:NL; displayName = 'Office renamed' })
        $script:Live['/identity/conditionalAccess/authenticationStrength/policies'] = @([pscustomobject]@{ id = $script:AS; displayName = 'Phish resistant'; allowedCombinations = @('fido2') })
        $script:Live['/identity/conditionalAccess/authenticationContextClassReferences'] = @([pscustomobject]@{ id = 'c1'; displayName = 'Sensitive' })
        $script:Live['/identity/conditionalAccess/policies'] = @([pscustomobject]@{ id = $script:P1; displayName = 'Require MFA' })

        $Rows = Restore-CIPPCloudBackupConditionalAccess -Snapshot (New-Snapshot) -SourceTenantId $script:Source -TargetTenantFilter $script:Target -ConflictAction Overwrite -Apply

        $Base = 'https://graph.microsoft.com/beta/identity/conditionalAccess'
        (Get-Write "$Base/namedLocations/$script:NL" PATCH).Count | Should -Be 1
        (Get-Write "$Base/authenticationStrength/policies/$script:AS" PATCH)[0].Body.Keys | Should -Not -Contain 'allowedCombinations'
        (Get-Write "$Base/authenticationStrength/policies/$script:AS/updateAllowedCombinations" POST)[0].Body.allowedCombinations | Should -Be @('fido2', 'windowsHelloForBusiness')
        (Get-Write "$Base/authenticationContextClassReferences/c1" PATCH)[0].Body.Keys | Should -Not -Contain 'id'
        $Policy = (Get-Write "$Base/policies/$script:P1" PATCH)[0].Body
        $Policy.state | Should -Be 'enabled'
        $Policy.conditions.locations.excludeLocations | Should -Be @($script:NL)
        $Policy.grantControls.authenticationStrength.id | Should -Be $script:AS
        $Policy.conditions.users.includeGroups | Should -Be @($script:G1)
        $Policy.conditions.users.excludeGroups | Should -Be @($script:G2)
        $Policy.conditions.users.excludeUsers | Should -Be @($script:U1)
        $Rows.Where({ $_.Key -eq $script:P1 })[0].Action | Should -Be 'Update'
        @($script:BulkCalls[1].Requests.url) | Should -Contain "/groups/$script:G1`?`$select=id"
    }

    It 'skips existing items and writes nothing for them' {
        $script:TargetCustomerId = $script:Source
        $script:Live['/identity/conditionalAccess/namedLocations'] = @([pscustomobject]@{ id = $script:NL; displayName = 'Office' })
        $script:Live['/identity/conditionalAccess/policies'] = @([pscustomobject]@{ id = $script:P1; displayName = 'Require MFA' })
        $Rows = Restore-CIPPCloudBackupConditionalAccess -Snapshot (New-Snapshot) -SourceTenantId $script:Source -TargetTenantFilter $script:Target -ConflictAction Skip -Apply `
            -Items @(@{ Section = 'namedLocations'; Key = $script:NL }, @{ Section = 'policies'; Key = $script:P1 })

        $Rows.Count | Should -Be 2
        @($Rows.Action | Select-Object -Unique) | Should -Be @('Skip')
        @($Rows.Status | Select-Object -Unique) | Should -Be @('Skipped')
        Should -Invoke New-GraphPOSTRequest -Times 0 -Exactly
    }

    It 'copies under a new name, applies the chosen state and points the copy at copied dependencies' {
        $script:TargetCustomerId = $script:Source
        $script:TargetGroups = @([pscustomobject]@{ id = $script:G1 }, [pscustomobject]@{ id = $script:G2 })
        $script:TargetUsers = @([pscustomobject]@{ id = $script:U1 })
        $script:Live['/identity/conditionalAccess/namedLocations'] = @([pscustomobject]@{ id = $script:NL; displayName = 'Office' })
        $script:Live['/identity/conditionalAccess/policies'] = @([pscustomobject]@{ id = $script:P1; displayName = 'Require MFA' })
        $script:Live['/identity/conditionalAccess/authenticationStrength/policies'] = @([pscustomobject]@{ id = $script:AS; displayName = 'Phish resistant' })
        $Rows = Restore-CIPPCloudBackupConditionalAccess -Snapshot (New-Snapshot) -SourceTenantId $script:Source -TargetTenantFilter $script:Target -ConflictAction Copy -CAState AsBackedUp -Apply `
            -Items @(@{ Section = 'namedLocations'; Key = $script:NL }, @{ Section = 'policies'; Key = $script:P1 })

        $Base = 'https://graph.microsoft.com/beta/identity/conditionalAccess'
        (Get-Write "$Base/namedLocations" POST)[0].Body.displayName | Should -Be "Office (restored $script:Today)"
        $Policy = (Get-Write "$Base/policies" POST)[0].Body
        $Policy.displayName | Should -Be "Require MFA (restored $script:Today)"
        $Policy.state | Should -Be 'disabled'
        $Policy.conditions.locations.excludeLocations | Should -Be @('new-1')
        $Rows.Action | Should -Be @('CreateCopy', 'CreateCopy')
        $Rows[0].Message | Should -Be "Created as 'Office (restored $script:Today)'"
        $Rows[1].Message | Should -Be "Created as a disabled copy 'Require MFA (restored $script:Today)'"
    }

    It 'maps references of unselected items through their match in the target' {
        $script:Live['/identity/conditionalAccess/namedLocations'] = @([pscustomobject]@{ id = 'nl-tgt'; displayName = 'Office' })
        $script:Live['/identity/conditionalAccess/authenticationStrength/policies'] = @([pscustomobject]@{ id = 'as-tgt'; displayName = 'Phish resistant' })
        $Rows = Restore-CIPPCloudBackupConditionalAccess -Snapshot (New-Snapshot) -SourceTenantId $script:Source -TargetTenantFilter $script:Target -ConflictAction Skip -Apply `
            -Items @(@{ Section = 'policies'; Key = $script:P1 })

        $Rows.Count | Should -Be 1
        $script:Writes.Count | Should -Be 1
        $script:Writes[0].Body.conditions.locations.excludeLocations | Should -Be @('nl-tgt')
        $script:Writes[0].Body.grantControls.authenticationStrength.id | Should -Be 'as-tgt'
    }

    It 'refuses to overwrite when several target items share the name' {
        $script:Live['/identity/conditionalAccess/policies'] = @([pscustomobject]@{ id = 'x1'; displayName = 'Require MFA' }, [pscustomobject]@{ id = 'x2'; displayName = 'Require MFA' })
        $Rows = Restore-CIPPCloudBackupConditionalAccess -Snapshot (New-Snapshot) -SourceTenantId $script:Source -TargetTenantFilter $script:Target -ConflictAction Overwrite -Apply `
            -Items @(@{ Section = 'policies'; Key = $script:P1 })
        $Rows[0].Status | Should -Be 'Failed'
        $Rows[0].Message | Should -BeLike '2 items in the target are named*'
        Should -Invoke New-GraphPOSTRequest -Times 0 -Exactly
    }

    It 'fails every item when the target cannot be read' {
        Mock New-GraphBulkRequest { throw 'Graph is down' }
        $Rows = Restore-CIPPCloudBackupConditionalAccess -Snapshot (New-Snapshot) -SourceTenantId $script:Source -TargetTenantFilter $script:Target -ConflictAction Overwrite -Apply
        @($Rows.Where({ $_.Status -ne 'Failed' })).Count | Should -Be 1
        $Rows.Where({ $_.Key -eq $script:BuiltIn })[0].Status | Should -Be 'Skipped'
        Should -Invoke New-GraphPOSTRequest -Times 0 -Exactly
    }
}

Describe 'Resolve-CIPPCloudBackupReference' {
    BeforeEach {
        Mock Get-NormalizedError { $Message }
    }

    It 'maps ids to themselves in the same tenant while they exist' {
        Mock New-GraphBulkRequest {
            foreach ($Request in $Requests) {
                if ($Request.url -like "*$script:G1*") { [pscustomobject]@{ id = $Request.id; status = 200; body = [pscustomobject]@{ id = $script:G1 } } }
                else { [pscustomobject]@{ id = $Request.id; status = 404; body = [pscustomobject]@{ error = [pscustomobject]@{ message = 'gone' } } } }
            }
        }
        $Result = Resolve-CIPPCloudBackupReference -TargetTenantFilter $script:Target -SameTenant -References @{ Groups = @{ $script:G1 = 'Sales'; $script:G2 = 'Old' }; Users = @{ 'not-a-guid' = 'x@y.com' } }
        $Result.Groups[$script:G1] | Should -Be $script:G1
        $Result.Groups[$script:G2] | Should -BeNullOrEmpty
        $Result.Missing[$script:G2] | Should -Be "Group 'Old' not found in the target"
        $Result.Users['not-a-guid'] | Should -BeNullOrEmpty
        Should -Invoke New-GraphBulkRequest -Times 1 -Exactly -ParameterFilter { @($Requests).Count -eq 2 -and $tenantid -eq $script:Target }
    }

    It 'maps by exact display name in another tenant and treats several matches as ambiguous' {
        Mock New-GraphBulkRequest {
            foreach ($Request in $Requests) {
                $Url = [uri]::UnescapeDataString($Request.url)
                $Value = if ($Url -like "*'Sales'*") {
                    @([pscustomobject]@{ id = 't1'; displayName = 'Sales' }, [pscustomobject]@{ id = 't2'; displayName = 'SALES' })
                } elseif ($Url -like "*'It''s'*") {
                    @([pscustomobject]@{ id = 't3'; displayName = "It's" }, [pscustomobject]@{ id = 't4'; displayName = "It's" })
                } else { @() }
                [pscustomobject]@{ id = $Request.id; status = 200; body = [pscustomobject]@{ value = $Value } }
            }
        }
        $Result = Resolve-CIPPCloudBackupReference -TargetTenantFilter $script:Target -References @{ Groups = @{ g1 = 'Sales'; g2 = "It's"; g3 = 'Nope' }; Users = @{} }
        $Result.Groups['g1'] | Should -Be 't1'
        $Result.Groups['g2'] | Should -BeNullOrEmpty
        $Result.Missing['g2'] | Should -BeLike "*matches 2 groups*"
        $Result.Missing['g3'] | Should -Be "Group 'Nope' not found in the target"
    }

    It 'reports every reference unmapped across tenants when the backup holds no names' {
        Mock New-GraphBulkRequest { }
        $Result = Resolve-CIPPCloudBackupReference -TargetTenantFilter $script:Target -References @{ Groups = @{ g1 = $null }; Users = @{ u1 = '' } }
        $Result.Groups['g1'] | Should -BeNullOrEmpty
        $Result.Missing['u1'] | Should -BeLike 'User u1 not found in the target*'
        Should -Invoke New-GraphBulkRequest -Times 0 -Exactly
    }

    It 'throws when a lookup fails for a reason other than not found' {
        Mock New-GraphBulkRequest { foreach ($Request in $Requests) { [pscustomobject]@{ id = $Request.id; status = 403; body = [pscustomobject]@{ error = [pscustomobject]@{ message = 'denied' } } } } }
        { Resolve-CIPPCloudBackupReference -TargetTenantFilter $script:Target -References @{ Groups = @{ g1 = 'Sales' } } } | Should -Throw "*Group 'Sales'*denied*"
    }
}
