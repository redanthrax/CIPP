function Restore-CIPPCloudBackupConditionalAccess {
    <#
    .SYNOPSIS
        Restores Conditional Access items from a Cloud Backup snapshot
    .DESCRIPTION
        Restores named locations, custom authentication strengths, authentication contexts and policies, in that
        order, remapping the ids policies reference. Groups and users are mapped with Resolve-CIPPCloudBackupReference;
        unmapped ones are dropped and reported, and a policy left with nothing to include fails instead. Without
        -Apply nothing is written and each row is a plan. Returns one row per selected item.
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
        $Items,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Skip', 'Overwrite', 'Copy')]
        [string]$ConflictAction,
        [ValidateSet('AsBackedUp', 'ReportOnly', 'Disabled')]
        [string]$CAState = 'AsBackedUp',
        [switch]$Apply
    )

    $ErrorActionPreference = 'Stop'
    $Order = @('namedLocations', 'authenticationStrengthPolicies', 'authenticationContextClassReferences', 'policies')
    $Paths = @{
        namedLocations                       = '/identity/conditionalAccess/namedLocations'
        authenticationStrengthPolicies       = '/identity/conditionalAccess/authenticationStrength/policies'
        authenticationContextClassReferences = '/identity/conditionalAccess/authenticationContextClassReferences'
        policies                             = '/identity/conditionalAccess/policies'
    }
    $Today = [datetime]::UtcNow.ToString('yyyy-MM-dd')
    $PolicyState = @{ ReportOnly = 'enabledForReportingButNotEnforced'; Disabled = 'disabled' }[$CAState]
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

    $ById = @{}
    $ByName = @{}
    $TargetErrors = @{}
    foreach ($Section in $Order) { $ById[$Section] = @{}; $ByName[$Section] = @{} }
    try {
        $Responses = @{}
        $Requests = foreach ($Section in $Order) { @{ id = $Section; method = 'GET'; url = $Paths[$Section] } }
        foreach ($Response in @(New-GraphBulkRequest -tenantid $TargetTenantFilter -asapp $true -Requests @($Requests))) { $Responses[[string]$Response.id] = $Response }
        foreach ($Section in $Order) {
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
                if (-not $ByName[$Section].ContainsKey($ExistingName)) { $ByName[$Section][$ExistingName] = [System.Collections.Generic.List[object]]::new() }
                $ByName[$Section][$ExistingName].Add($Existing)
            }
        }
    } catch {
        $ReadError = Get-NormalizedError -Message $_.Exception.Message
        foreach ($Section in $Order) { $TargetErrors[$Section] = $ReadError }
    }
    $UsedContextIds = [System.Collections.Generic.HashSet[string]]::new([string[]]@($ById['authenticationContextClassReferences'].Keys))

    $SpecialUsers = @('All', 'None', 'GuestsOrExternalUsers')
    $SourceReferences = $Snapshot.References
    $ReferenceInput = @{ Groups = @{}; Users = @{} }
    $IdMap = @{ namedLocations = @{}; authenticationStrengthPolicies = @{}; authenticationContextClassReferences = @{} }
    $NameOf = @{ namedLocations = @{}; authenticationStrengthPolicies = @{}; authenticationContextClassReferences = @{} }
    foreach ($Entry in $Work) {
        if ($NameOf.ContainsKey($Entry.Section)) { $NameOf[$Entry.Section][[string]$Entry.Item.id] = $Entry.Name }
        if (-not $Entry.Selected -or $Entry.Section -ne 'policies') { continue }
        $PolicyUsers = $Entry.Item.conditions.users
        if ($null -eq $PolicyUsers) { continue }
        foreach ($Id in @($PolicyUsers.includeUsers) + @($PolicyUsers.excludeUsers)) {
            if ($Id -and $Id -notin $SpecialUsers) { $ReferenceInput.Users[[string]$Id] = [string]$SourceReferences.Users.$Id }
        }
        foreach ($Id in @($PolicyUsers.includeGroups) + @($PolicyUsers.excludeGroups)) {
            if ($Id) { $ReferenceInput.Groups[[string]$Id] = [string]$SourceReferences.Groups.$Id }
        }
    }
    $References = @{ Groups = @{}; Users = @{}; Missing = @{} }
    $ReferenceError = $null
    if ($ReferenceInput.Groups.Count + $ReferenceInput.Users.Count -gt 0) {
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
        $Match = $null
        $MatchCount = 0
        if ($Section -in $Order -and -not $TargetErrors[$Section]) {
            if ($SameTenant -and $SourceId -and $ById[$Section].ContainsKey($SourceId)) {
                $Match = $ById[$Section][$SourceId]
                $MatchCount = 1
            } elseif ($ByName[$Section].ContainsKey($Entry.Name)) {
                $MatchCount = $ByName[$Section][$Entry.Name].Count
                if ($MatchCount -eq 1) { $Match = $ByName[$Section][$Entry.Name][0] }
            }
        }
        $IsBuiltIn = $Section -eq 'authenticationStrengthPolicies' -and [string]$Item.policyType -eq 'builtIn'
        if ($IdMap.ContainsKey($Section)) {
            $IdMap[$Section][$SourceId] = if ($IsBuiltIn) { $SourceId } elseif ($Match) { [string]$Match.id } else { $null }
        }
        if (-not $Entry.Selected) { continue }

        $Row = [ordered]@{
            Area         = 'ConditionalAccess'
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
        try {
            if ($Section -notin $Order) {
                $Row.Message = 'This kind of item cannot be restored'
            } elseif ($IsBuiltIn) {
                $Row.Action = 'Skip'
                $Row.Message = 'Built-in authentication strengths exist in every tenant'
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
                    $NewName = if ($Row.Action -eq 'CreateCopy') { "$($Entry.Name) (restored $Today)" } else { $Entry.Name }
                    $Combinations = $null
                    $ContextId = $null

                    switch ($Section) {
                        'namedLocations' {
                            $Body = ConvertTo-CIPPCloudBackupRestoreBody -Item $Item -Remove 'id', 'createdDateTime', 'modifiedDateTime'
                            $Body['displayName'] = $NewName
                        }
                        'authenticationStrengthPolicies' {
                            $Body = @{ displayName = $NewName; description = [string]$Item.description }
                            $Wanted = @($Item.allowedCombinations)
                            if ($Row.Action -eq 'Update') {
                                if ((@($Wanted | Sort-Object) -join ',') -ne (@(@($Match.allowedCombinations) | Sort-Object) -join ',')) { $Combinations = $Wanted }
                            } else {
                                $Body['allowedCombinations'] = $Wanted
                            }
                        }
                        'authenticationContextClassReferences' {
                            $ContextId = if ($Row.Action -eq 'Update') {
                                [string]$Match.id
                            } elseif ($Row.Action -eq 'Create' -and $SourceId -and -not $UsedContextIds.Contains($SourceId)) {
                                $SourceId
                            } else {
                                foreach ($Number in 1..99) { if (-not $UsedContextIds.Contains("c$Number")) { "c$Number"; break } }
                            }
                            if (-not $ContextId) { throw 'All 99 authentication context ids are already used in the target' }
                            [void]$UsedContextIds.Add($ContextId)
                            $Body = @{ displayName = $NewName; description = [string]$Item.description; isAvailable = [bool]$Item.isAvailable }
                            if ($Row.Action -ne 'Update') { $Body['id'] = $ContextId }
                        }
                        'policies' {
                            $Body = ConvertTo-CIPPCloudBackupRestoreBody -Item $Item -Remove 'id', 'templateId', 'createdDateTime', 'modifiedDateTime', 'deletedDateTime'
                            $Body['displayName'] = $NewName
                            if ($Row.Action -eq 'CreateCopy') { $Body['state'] = 'disabled' } elseif ($PolicyState) { $Body['state'] = $PolicyState }
                            $Conditions = $Body['conditions']
                            $MissingExclusions = [System.Collections.Generic.List[string]]::new()

                            $PolicyUsers = if ($Conditions) { $Conditions['users'] }
                            if ($PolicyUsers) {
                                $IncludeLost = $false
                                foreach ($Field in 'includeUsers', 'excludeUsers', 'includeGroups', 'excludeGroups') {
                                    if ($null -eq $PolicyUsers[$Field]) { continue }
                                    $Kind = if ($Field -like '*Users') { 'Users' } else { 'Groups' }
                                    $Before = @($PolicyUsers[$Field])
                                    $PolicyUsers[$Field] = @(foreach ($Id in $Before) {
                                            if ($Kind -eq 'Users' -and $Id -in $SpecialUsers) { $Id; continue }
                                            if ($ReferenceError) { throw "Could not look up the users and groups this policy uses in the target: $ReferenceError" }
                                            $Mapped = $References[$Kind][[string]$Id]
                                            if ($Mapped) { $Mapped; continue }
                                            $Missing = $References.Missing[[string]$Id] ?? "$Kind id $Id not found in the target"
                                            $Unmapped.Add($Missing)
                                            if ($Field -like 'exclude*') { $MissingExclusions.Add($Missing) }
                                        })
                                    if ($Field -like 'include*' -and $PolicyUsers[$Field].Count -lt $Before.Count) { $IncludeLost = $true }
                                }
                                $IncludeCount = @($PolicyUsers['includeUsers']).Where({ $null -ne $_ }).Count + @($PolicyUsers['includeGroups']).Where({ $null -ne $_ }).Count + @($PolicyUsers['includeRoles']).Where({ $null -ne $_ }).Count
                                if ($IncludeLost -and $IncludeCount -eq 0 -and -not $PolicyUsers['includeGuestsOrExternalUsers']) {
                                    throw 'None of the users and groups this policy applies to exist in the target, so it was not restored'
                                }
                            }

                            $Locations = if ($Conditions) { $Conditions['locations'] }
                            if ($Locations) {
                                $IncludeLost = $false
                                foreach ($Field in 'includeLocations', 'excludeLocations') {
                                    if ($null -eq $Locations[$Field]) { continue }
                                    $Before = @($Locations[$Field])
                                    $Locations[$Field] = @(foreach ($Id in $Before) {
                                            if ($Id -in 'All', 'AllTrusted', '00000000-0000-0000-0000-000000000000') { $Id; continue }
                                            $Mapped = if ($IdMap.namedLocations.ContainsKey([string]$Id)) { $IdMap.namedLocations[[string]$Id] } elseif ($SameTenant -and $ById.namedLocations.ContainsKey([string]$Id)) { [string]$Id }
                                            if ($Mapped) { $Mapped; continue }
                                            $Missing = "Named location '$($NameOf.namedLocations[[string]$Id] ?? $Id)' not found in the target"
                                            $Unmapped.Add($Missing)
                                            if ($Field -eq 'excludeLocations') { $MissingExclusions.Add($Missing) }
                                        })
                                    if ($Field -eq 'includeLocations' -and $Locations[$Field].Count -lt $Before.Count) { $IncludeLost = $true }
                                }
                                if ($IncludeLost -and $Locations['includeLocations'].Count -eq 0) {
                                    throw 'None of the named locations this policy applies to exist in the target, so it was not restored'
                                }
                            }

                            $Applications = if ($Conditions) { $Conditions['applications'] }
                            if ($Applications -and $null -ne $Applications['includeAuthenticationContextClassReferences']) {
                                $Before = @($Applications['includeAuthenticationContextClassReferences'])
                                $Applications['includeAuthenticationContextClassReferences'] = @(foreach ($Id in $Before) {
                                        $Mapped = if ($IdMap.authenticationContextClassReferences.ContainsKey([string]$Id)) { $IdMap.authenticationContextClassReferences[[string]$Id] } elseif ($SameTenant -and $ById.authenticationContextClassReferences.ContainsKey([string]$Id)) { [string]$Id }
                                        if ($Mapped) { $Mapped } else { $Unmapped.Add("Authentication context '$($NameOf.authenticationContextClassReferences[[string]$Id] ?? $Id)' not found in the target") }
                                    })
                                $Remaining = $Applications['includeAuthenticationContextClassReferences'].Count + @($Applications['includeApplications']).Where({ $null -ne $_ }).Count + @($Applications['includeUserActions']).Where({ $null -ne $_ }).Count
                                if ($Applications['includeAuthenticationContextClassReferences'].Count -lt $Before.Count -and $Remaining -eq 0) {
                                    throw 'None of the authentication contexts this policy applies to exist in the target, so it was not restored'
                                }
                            }

                            $ClientApplications = if ($Conditions) { $Conditions['clientApplications'] }
                            if ($ClientApplications -and -not $SameTenant) {
                                $IncludeLost = $false
                                foreach ($Field in 'includeServicePrincipals', 'excludeServicePrincipals') {
                                    if ($null -eq $ClientApplications[$Field]) { continue }
                                    $Before = @($ClientApplications[$Field])
                                    $ClientApplications[$Field] = @(foreach ($Id in $Before) {
                                            if ($Id -in 'All', 'ServicePrincipalsInMyTenant', 'None') { $Id; continue }
                                            $Missing = "Service principal $Id belongs to the source tenant"
                                            $Unmapped.Add($Missing)
                                            if ($Field -eq 'excludeServicePrincipals') { $MissingExclusions.Add($Missing) }
                                        })
                                    if ($Field -eq 'includeServicePrincipals' -and $ClientApplications[$Field].Count -lt $Before.Count) { $IncludeLost = $true }
                                }
                                if ($IncludeLost -and $ClientApplications['includeServicePrincipals'].Count -eq 0) {
                                    throw 'None of the service principals this policy applies to exist in the target, so it was not restored'
                                }
                            }

                            if ($MissingExclusions.Count -gt 0) {
                                throw "Not restored because its exclusions are missing in the target, and without them it would apply to more people: $($MissingExclusions -join '; ')"
                            }

                            $Grant = $Body['grantControls']
                            if ($Grant) {
                                $Strength = $Grant['authenticationStrength']
                                if ($Strength) {
                                    $StrengthId = [string]$Strength['id']
                                    $Mapped = if ($IdMap.authenticationStrengthPolicies.ContainsKey($StrengthId)) {
                                        $IdMap.authenticationStrengthPolicies[$StrengthId]
                                    } elseif ([string]$Strength['policyType'] -eq 'builtIn' -or ($SameTenant -and $ById.authenticationStrengthPolicies.ContainsKey($StrengthId))) {
                                        $StrengthId
                                    }
                                    if (-not $Mapped) { throw "The authentication strength '$($Strength['displayName'] ?? $StrengthId)' this policy requires is not in the target, so it was not restored" }
                                    $Grant['authenticationStrength'] = @{ id = $Mapped }
                                }
                                if (-not $SameTenant -and @($Grant['termsOfUse']).Where({ $_ }).Count -gt 0) {
                                    throw 'This policy requires terms of use, which belong to the source tenant and cannot be restored to another tenant'
                                }
                                if (-not $SameTenant -and @($Grant['customAuthenticationFactors']).Where({ $_ }).Count -gt 0) {
                                    throw 'This policy requires custom authentication controls, which belong to the source tenant and cannot be restored to another tenant'
                                }
                            }
                            $Session = $Body['sessionControls']
                            if ($Session -and $Session['globalSecureAccessFilteringProfile']) {
                                if (-not $SameTenant) { throw 'This policy applies a Global Secure Access security profile, which belongs to the source tenant and cannot be restored to another tenant' }
                                $Session.Remove('networkAccessSecurity')
                            }
                        }
                    }

                    $Url = "https://graph.microsoft.com/beta$($Paths[$Section])"
                    if ($Apply) {
                        $Json = ConvertTo-Json -InputObject $Body -Depth 100 -Compress
                        if ($Row.Action -eq 'Update') {
                            $null = New-GraphPOSTRequest -uri "$Url/$($Match.id)" -tenantid $TargetTenantFilter -type PATCH -body $Json -AsApp $true
                            if ($Combinations) {
                                $CombinationJson = ConvertTo-Json -InputObject @{ allowedCombinations = @($Combinations) } -Depth 5 -Compress
                                $null = New-GraphPOSTRequest -uri "$Url/$($Match.id)/updateAllowedCombinations" -tenantid $TargetTenantFilter -type POST -body $CombinationJson -AsApp $true
                            }
                            $NewId = [string]$Match.id
                            $Row.Message = 'Updated'
                        } else {
                            $Created = New-GraphPOSTRequest -uri $Url -tenantid $TargetTenantFilter -type POST -body $Json -AsApp $true
                            $NewId = if ($ContextId) { $ContextId } else { [string]$Created.id }
                            if (-not $NewId) { throw 'Graph did not return the new item' }
                            $Row.Message = if ($Row.Action -ne 'CreateCopy') { 'Created' } elseif ($Section -eq 'policies') { "Created as a disabled copy '$NewName'" } else { "Created as '$NewName'" }
                        }
                        $Row.Status = 'Succeeded'
                    } else {
                        $NewId = if ($Row.Action -eq 'Update') { [string]$Match.id } elseif ($ContextId) { $ContextId } else { "planned:$SourceId" }
                        $Row.Status = 'Planned'
                        $Row.Message = switch ($Row.Action) {
                            'Update' { 'Will update the existing item' }
                            'CreateCopy' { if ($Section -eq 'policies') { "Will be created as a disabled copy '$NewName'" } else { "Will be created as '$NewName'" } }
                            default { 'Will be created' }
                        }
                    }
                    if ($IdMap.ContainsKey($Section)) { $IdMap[$Section][$SourceId] = $NewId }
                }
            }
        } catch {
            $Row.Status = 'Failed'
            $Row.Message = Get-NormalizedError -Message $_.Exception.Message
        }
        $Row.Unmapped = [string[]]@($Unmapped)
        $Results.Add([pscustomobject]$Row)
    }
    $Results.ToArray()
}
