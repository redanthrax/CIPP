function Compare-CIPPCloudBackupConfig {
    <#
    .SYNOPSIS
        Compares two versions of one Cloud Backup area item by item, with the property differences of each item
    .DESCRIPTION
        Reference is the backup, Difference is the live configuration or another backup; each is { Sections; References }.
        Items are matched by key, or by name with -MatchByName (another tenant), where referenced groups, users, named
        locations, authentication strengths, assignment filters and scope tags are compared by name. Only sections
        present on both sides are compared. Returns one row per item: Added, Removed, Changed or Unchanged.
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Area,
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        $Reference,
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        $Difference,
        [switch]$MatchByName
    )

    $Comparer = [System.StringComparer]::OrdinalIgnoreCase
    $Invariant = [cultureinfo]::InvariantCulture
    $Ignored = [System.Collections.Generic.HashSet[string]]::new([string[]]@(
            'id', 'createdDateTime', 'lastModifiedDateTime', 'modifiedDateTime', 'version', 'settingCount', 'Guid',
            'ExchangeObjectId', 'Identity', 'DistinguishedName', 'OrganizationId', 'ObjectState', 'WhenChanged', 'WhenCreated',
            'WhenChangedUTC', 'WhenCreatedUTC', 'IsValid', 'ExchangeVersion', 'OriginatingServer', 'RunspaceId', 'PSComputerName'
        ), $Comparer)
    $ReferencedSections = @{ namedLocations = 'namedLocation'; authenticationStrengthPolicies = 'authenticationStrength'; assignmentFilters = 'assignmentFilter' }

    $SideSections = [object[]]::new(2)
    $Maps = [object[]]::new(2)
    $TagMaps = [object[]]::new(2)
    $Sides = @($Reference, $Difference)
    for ($s = 0; $s -lt 2; $s++) {
        $Sections = [ordered]@{}
        $Source = $Sides[$s].Sections
        if ($Source -is [System.Collections.IDictionary]) {
            foreach ($Name in $Source.Keys) { $Sections[[string]$Name] = $Source[$Name] }
        } elseif ($null -ne $Source) {
            foreach ($Property in $Source.PSObject.Properties) { $Sections[$Property.Name] = $Property.Value }
        }
        $SideSections[$s] = $Sections

        $Map = [System.Collections.Generic.Dictionary[string, string]]::new($Comparer)
        $TagMap = [System.Collections.Generic.Dictionary[string, string]]::new($Comparer)
        if ($MatchByName) {
            foreach ($Kind in 'Groups', 'Users') {
                $Prefix = if ($Kind -eq 'Groups') { 'group:' } else { 'user:' }
                $Names = $Sides[$s].References.$Kind
                if ($Names -is [System.Collections.IDictionary]) {
                    foreach ($Id in $Names.Keys) { $Map[[string]$Id] = "$Prefix$($Names[$Id])" }
                } elseif ($null -ne $Names) {
                    foreach ($Property in $Names.PSObject.Properties) { $Map[$Property.Name] = "$Prefix$($Property.Value)" }
                }
            }
            foreach ($Section in $ReferencedSections.Keys) {
                if (-not $Sections.Contains($Section)) { continue }
                foreach ($Item in $Sections[$Section]) {
                    if ($Item.id) { $Map[[string]$Item.id] = "$($ReferencedSections[$Section]):$($Item.displayName)" }
                }
            }
            if ($Sections.Contains('roleScopeTags')) {
                foreach ($Item in $Sections['roleScopeTags']) {
                    if ($null -ne $Item.id) { $TagMap[[string]$Item.id] = "scopeTag:$($Item.displayName)" }
                }
            }
        }
        $Maps[$s] = $Map
        $TagMaps[$s] = $TagMap
    }

    $Stack = [System.Collections.Generic.Stack[object]]::new()
    $Kinds = [int[]]::new(2)
    $Values = [object[]]::new(2)
    $Normalized = [object[]]::new(2)

    foreach ($Section in @($SideSections[0].Keys)) {
        if (-not $SideSections[1].Contains($Section)) { continue }
        $SectionLabel = Get-CIPPCloudBackupSectionLabel -Section $Section
        $RefItems = [object[]]@(foreach ($Item in $SideSections[0][$Section]) { if ($null -ne $Item) { $Item } })
        $DiffItems = [object[]]@(foreach ($Item in $SideSections[1][$Section]) { if ($null -ne $Item) { $Item } })
        $RefInfo = [object[]]@(Get-CIPPCloudBackupItemInfo -Section $Section -Item $RefItems)
        $DiffInfo = [object[]]@(Get-CIPPCloudBackupItemInfo -Section $Section -Item $DiffItems)

        $DiffIndex = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.Queue[int]]]::new($Comparer)
        for ($j = 0; $j -lt $DiffItems.Count; $j++) {
            $MatchKey = if ($MatchByName) { [string]$DiffInfo[$j].Name } else { [string]$DiffInfo[$j].Key }
            if (-not $DiffIndex.ContainsKey($MatchKey)) { $DiffIndex[$MatchKey] = [System.Collections.Generic.Queue[int]]::new() }
            $DiffIndex[$MatchKey].Enqueue($j)
        }
        $DiffUsed = [bool[]]::new($DiffItems.Count)

        for ($i = 0; $i -lt $RefItems.Count; $i++) {
            $MatchKey = if ($MatchByName) { [string]$RefInfo[$i].Name } else { [string]$RefInfo[$i].Key }
            $Queue = $null
            if (-not $DiffIndex.TryGetValue($MatchKey, [ref]$Queue) -or $Queue.Count -eq 0) {
                [pscustomobject]@{ Area = $Area; Section = $Section; SectionLabel = $SectionLabel; Key = $RefInfo[$i].Key; Name = $RefInfo[$i].Name; Change = 'Removed'; Differences = @() }
                continue
            }
            $j = $Queue.Dequeue()
            $DiffUsed[$j] = $true

            $Differences = [System.Collections.Generic.List[object]]::new()
            $RefJson = [CIPP.CippJson]::ToJson($RefItems[$i], 100)
            if ($null -eq $RefJson -or $RefJson -cne [CIPP.CippJson]::ToJson($DiffItems[$j], 100)) {
                $Stack.Clear()
                $Stack.Push([object[]]@('', $RefItems[$i], $DiffItems[$j], ''))
                while ($Stack.Count -gt 0) {
                    $Frame = $Stack.Pop()
                    $Path = $Frame[0]
                    $Property = $Frame[3]
                    $Values[0] = $Frame[1]
                    $Values[1] = $Frame[2]
                    $IsTagList = $Property -eq 'roleScopeTagIds'

                    $Wildcard = $false
                    for ($s = 0; $s -lt 2; $s++) {
                        $Value = $Values[$s]
                        $Kinds[$s] = if ($null -eq $Value) {
                            0
                        } elseif ($Value -is [string]) {
                            if ($Value.Length -eq 0) { 0 } elseif ($Value -ceq '(encrypted)') { $Wildcard = $true; 1 } else { 1 }
                        } elseif ($Value -is [System.Collections.IDictionary]) {
                            if ($Value.Count -eq 0) { 0 } else { 3 }
                        } elseif ($Value -is [System.Management.Automation.PSCustomObject]) {
                            3
                        } elseif ($Value -is [System.Collections.ICollection]) {
                            if ($Value.Count -eq 0) { 0 } else { 2 }
                        } else {
                            1
                        }
                        if ($IsTagList -and $Kinds[$s] -eq 2 -and $Value.Count -eq 1 -and "$(@($Value)[0])" -eq '0') { $Kinds[$s] = 0 }
                    }
                    if ($Wildcard -or ($Kinds[0] -eq 0 -and $Kinds[1] -eq 0)) { continue }

                    $ObjectList = $false
                    if ($Kinds[0] -eq 2 -or $Kinds[1] -eq 2) {
                        foreach ($Value in $Values) {
                            foreach ($Element in $Value) {
                                if ($Element -is [System.Management.Automation.PSCustomObject] -or $Element -is [System.Collections.IDictionary]) { $ObjectList = $true; break }
                            }
                            if ($ObjectList) { break }
                        }
                    }

                    if ($Kinds[0] -ne $Kinds[1] -and -not ($Kinds[0] -in 1, 2 -and $Kinds[1] -in 1, 2 -and -not $ObjectList)) {
                        $Differences.Add([pscustomobject]@{ Path = $Path; Reference = $Values[0]; Difference = $Values[1] })
                        continue
                    }

                    if ($Kinds[0] -eq 3) {
                        $Children = [System.Collections.Generic.List[object]]::new()
                        $Properties = [object[]]::new(2)
                        for ($s = 0; $s -lt 2; $s++) {
                            $Members = [System.Collections.Generic.Dictionary[string, object]]::new($Comparer)
                            $Value = $Values[$s]
                            if ($Value -is [System.Collections.IDictionary]) {
                                foreach ($Name in $Value.Keys) {
                                    $Name = [string]$Name
                                    if (-not $Ignored.Contains($Name) -and ($Name -eq '@odata.type' -or $Name.IndexOf('@odata.', [System.StringComparison]::OrdinalIgnoreCase) -lt 0)) { $Members[$Name] = $Value[$Name] }
                                }
                            } else {
                                foreach ($Member in $Value.PSObject.Properties) {
                                    $Name = $Member.Name
                                    if (-not $Ignored.Contains($Name) -and ($Name -eq '@odata.type' -or $Name.IndexOf('@odata.', [System.StringComparison]::OrdinalIgnoreCase) -lt 0)) { $Members[$Name] = $Member.Value }
                                }
                            }
                            $Properties[$s] = $Members
                        }
                        foreach ($Name in $Properties[0].Keys) {
                            $Other = $null
                            $null = $Properties[1].TryGetValue($Name, [ref]$Other)
                            $Children.Add([object[]]@($(if ($Path) { "$Path.$Name" } else { $Name }), $Properties[0][$Name], $Other, $Name))
                        }
                        foreach ($Name in $Properties[1].Keys) {
                            if ($Properties[0].ContainsKey($Name)) { continue }
                            $Children.Add([object[]]@($(if ($Path) { "$Path.$Name" } else { $Name }), $null, $Properties[1][$Name], $Name))
                        }
                        for ($c = $Children.Count - 1; $c -ge 0; $c--) { $Stack.Push($Children[$c]) }
                        continue
                    }

                    if (-not $ObjectList) {
                        for ($s = 0; $s -lt 2; $s++) {
                            $Map = if ($IsTagList) { $TagMaps[$s] } else { $Maps[$s] }
                            $Set = [System.Collections.Generic.List[string]]::new()
                            foreach ($Element in $Values[$s]) {
                                if ($null -eq $Element) { continue }
                                if ($Element -is [string]) {
                                    if ($Element.Length -eq 0) { continue }
                                    $Text = $Element
                                    $Parsed = [datetime]::MinValue
                                    if ($Map.Count -gt 0 -and $Map.ContainsKey($Text)) {
                                        $Text = $Map[$Text]
                                    } elseif ($Text.Length -ge 19 -and $Text.Length -le 40 -and $Text[10] -eq 'T' -and [char]::IsDigit($Text[0]) -and
                                        [datetime]::TryParse($Text, $Invariant, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$Parsed)) {
                                        $Text = $Parsed.ToString('yyyy-MM-ddTHH:mm:ss.FFFFFFF', $Invariant)
                                    }
                                } elseif ($Element -is [datetime]) {
                                    $Text = $(if ($Element.Kind -eq [System.DateTimeKind]::Local) { $Element.ToUniversalTime() } else { $Element }).ToString('yyyy-MM-ddTHH:mm:ss.FFFFFFF', $Invariant)
                                } elseif ($Element -is [System.IFormattable]) {
                                    $Text = $Element.ToString($null, $Invariant)
                                } else {
                                    $Text = [string]$Element
                                }
                                $Set.Add($Text)
                            }
                            $Set.Sort([System.StringComparer]::Ordinal)
                            $Normalized[$s] = [string]::Join([char]0x1F, $Set)
                        }
                        if ($Normalized[0] -cne $Normalized[1]) {
                            $Differences.Add([pscustomobject]@{ Path = $Path; Reference = $Values[0]; Difference = $Values[1] })
                        }
                        continue
                    }

                    $Lists = @([object[]]@($Values[0]), [object[]]@($Values[1]))
                    $Pairs = @([int[]]::new($Lists[0].Count), [int[]]::new($Lists[1].Count))
                    for ($s = 0; $s -lt 2; $s++) { for ($e = 0; $e -lt $Pairs[$s].Length; $e++) { $Pairs[$s][$e] = -1 } }
                    $Equal = [bool[]]::new($Lists[0].Count)

                    $ByJson = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.Queue[int]]]::new([System.StringComparer]::Ordinal)
                    for ($e = 0; $e -lt $Lists[1].Count; $e++) {
                        $Json = [CIPP.CippJson]::ToJson($Lists[1][$e], 100)
                        if ($null -eq $Json) { continue }
                        if (-not $ByJson.ContainsKey($Json)) { $ByJson[$Json] = [System.Collections.Generic.Queue[int]]::new() }
                        $ByJson[$Json].Enqueue($e)
                    }
                    for ($e = 0; $e -lt $Lists[0].Count; $e++) {
                        $Json = [CIPP.CippJson]::ToJson($Lists[0][$e], 100)
                        $Queue = $null
                        if ($null -ne $Json -and $ByJson.TryGetValue($Json, [ref]$Queue) -and $Queue.Count -gt 0) {
                            $Match = $Queue.Dequeue()
                            $Pairs[0][$e] = $Match
                            $Pairs[1][$Match] = $e
                            $Equal[$e] = $true
                        }
                    }

                    $IdentityKeys = @([string[]]::new($Lists[0].Count), [string[]]::new($Lists[1].Count))
                    for ($s = 0; $s -lt 2; $s++) {
                        for ($e = 0; $e -lt $Lists[$s].Count; $e++) {
                            if ($Pairs[$s][$e] -ge 0) { continue }
                            $Element = $Lists[$s][$e]
                            if (-not ($Element -is [System.Management.Automation.PSCustomObject] -or $Element -is [System.Collections.IDictionary])) { continue }
                            $Target = $Element.target
                            $IdentityKeys[$s][$e] = if ($null -ne $Target) {
                                $GroupId = [string]$Target.groupId
                                if ($Maps[$s].ContainsKey($GroupId)) { $GroupId = $Maps[$s][$GroupId] }
                                "target|$($Target.'@odata.type')|$GroupId"
                            } elseif ($null -ne $Element.settingInstance) {
                                "setting|$($Element.settingInstance.settingDefinitionId)"
                            } elseif ($null -ne $Element.definition -and $Element.definition.id) {
                                "definition|$($Element.definition.id)"
                            } elseif ($null -ne $Element.presentation -and $Element.presentation.id) {
                                "presentation|$($Element.presentation.id)"
                            } elseif ($Element.definitionId) {
                                "definitionId|$($Element.definitionId)"
                            } elseif (-not $MatchByName -and $Element.id) {
                                "id|$($Element.id)"
                            } elseif ($Element.displayName) {
                                "displayName|$($Element.displayName)"
                            } elseif ($Element.name) {
                                "name|$($Element.name)"
                            }
                        }
                    }
                    $ByIdentity = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.Queue[int]]]::new($Comparer)
                    for ($e = 0; $e -lt $Lists[1].Count; $e++) {
                        $IdentityKey = $IdentityKeys[1][$e]
                        if ($null -eq $IdentityKey) { continue }
                        if (-not $ByIdentity.ContainsKey($IdentityKey)) { $ByIdentity[$IdentityKey] = [System.Collections.Generic.Queue[int]]::new() }
                        $ByIdentity[$IdentityKey].Enqueue($e)
                    }
                    for ($e = 0; $e -lt $Lists[0].Count; $e++) {
                        $IdentityKey = $IdentityKeys[0][$e]
                        $Queue = $null
                        if ($null -ne $IdentityKey -and $ByIdentity.TryGetValue($IdentityKey, [ref]$Queue) -and $Queue.Count -gt 0) {
                            $Match = $Queue.Dequeue()
                            $Pairs[0][$e] = $Match
                            $Pairs[1][$Match] = $e
                        }
                    }

                    $Next = 0
                    for ($e = 0; $e -lt $Lists[0].Count; $e++) {
                        if ($Pairs[0][$e] -ge 0) { continue }
                        while ($Next -lt $Lists[1].Count -and $Pairs[1][$Next] -ge 0) { $Next++ }
                        if ($Next -ge $Lists[1].Count) { break }
                        $Pairs[0][$e] = $Next
                        $Pairs[1][$Next] = $e
                    }

                    $Children = [System.Collections.Generic.List[object]]::new()
                    for ($e = 0; $e -lt $Lists[0].Count; $e++) {
                        if ($Equal[$e]) { continue }
                        $Match = $Pairs[0][$e]
                        if ($Match -lt 0) {
                            $Differences.Add([pscustomobject]@{ Path = "$Path[$e]"; Reference = $Lists[0][$e]; Difference = $null })
                        } else {
                            $Children.Add([object[]]@("$Path[$e]", $Lists[0][$e], $Lists[1][$Match], ''))
                        }
                    }
                    for ($e = 0; $e -lt $Lists[1].Count; $e++) {
                        if ($Pairs[1][$e] -lt 0) { $Differences.Add([pscustomobject]@{ Path = "$Path[$e]"; Reference = $null; Difference = $Lists[1][$e] }) }
                    }
                    for ($c = $Children.Count - 1; $c -ge 0; $c--) { $Stack.Push($Children[$c]) }
                }
            }

            [pscustomobject]@{
                Area         = $Area
                Section      = $Section
                SectionLabel = $SectionLabel
                Key          = $RefInfo[$i].Key
                Name         = $RefInfo[$i].Name
                Change       = if ($Differences.Count -gt 0) { 'Changed' } else { 'Unchanged' }
                Differences  = $Differences.ToArray()
            }
        }

        for ($j = 0; $j -lt $DiffItems.Count; $j++) {
            if ($DiffUsed[$j]) { continue }
            [pscustomobject]@{ Area = $Area; Section = $Section; SectionLabel = $SectionLabel; Key = $DiffInfo[$j].Key; Name = $DiffInfo[$j].Name; Change = 'Added'; Differences = @() }
        }
    }
}
