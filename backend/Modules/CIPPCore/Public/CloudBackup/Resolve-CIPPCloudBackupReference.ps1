function Resolve-CIPPCloudBackupReference {
    <#
    .SYNOPSIS
        Maps the groups and users a backup references to their ids in the restore target
    .DESCRIPTION
        References is @{ Groups = @{ <id> = <displayName> }; Users = @{ <id> = <userPrincipalName> } }. In the same
        tenant an id maps to itself while it still exists. In another tenant a group maps by exact display name (more
        than one match is ambiguous and stays unmapped) and a user by userPrincipalName. Unmapped ids map to $null,
        and Missing holds the reason for each one. Throws when the target cannot be read.
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetTenantFilter,
        $References,
        [switch]$SameTenant
    )

    $Result = @{ Groups = @{}; Users = @{}; Missing = @{} }
    $Requests = [System.Collections.Generic.List[object]]::new()
    $Lookups = @{}
    $Index = 0

    foreach ($Kind in 'Groups', 'Users') {
        $Map = if ($null -ne $References) { $References.$Kind }
        if ($null -eq $Map) { continue }
        $Pairs = [System.Collections.Generic.List[object]]::new()
        if ($Map -is [System.Collections.IDictionary]) {
            foreach ($Entry in $Map.GetEnumerator()) { $Pairs.Add(@{ Id = [string]$Entry.Key; Name = [string]$Entry.Value }) }
        } else {
            foreach ($Property in $Map.PSObject.Properties) { $Pairs.Add(@{ Id = [string]$Property.Name; Name = [string]$Property.Value }) }
        }
        $Noun = if ($Kind -eq 'Groups') { 'Group' } else { 'User' }
        foreach ($Pair in $Pairs) {
            $Id = $Pair.Id
            $Name = $Pair.Name
            if (-not $Id -or $Result[$Kind].ContainsKey($Id)) { continue }
            $Result[$Kind][$Id] = $null
            $Label = if ($Name) { "$Noun '$Name'" } else { "$Noun $Id" }
            $Result.Missing[$Id] = "$Label not found in the target"

            $Url = if ($SameTenant) {
                $Parsed = [guid]::Empty
                if (-not [guid]::TryParse($Id, [ref]$Parsed)) { continue }
                if ($Kind -eq 'Groups') { "/groups/$Id`?`$select=id" } else { "/users/$Id`?`$select=id" }
            } else {
                if (-not $Name) {
                    $Result.Missing[$Id] = "$Label not found in the target: the backup does not record its name"
                    continue
                }
                $Value = [uri]::EscapeDataString($Name.Replace("'", "''"))
                if ($Kind -eq 'Groups') {
                    "/groups?`$filter=displayName eq '$Value'&`$select=id,displayName&`$top=999"
                } else {
                    "/users?`$filter=userPrincipalName eq '$Value'&`$select=id,userPrincipalName"
                }
            }
            $RequestId = "ref$Index"
            $Index++
            $Lookups[$RequestId] = @{ Kind = $Kind; Id = $Id; Name = $Name; Label = $Label }
            $Requests.Add(@{ id = $RequestId; method = 'GET'; url = $Url })
        }
    }

    if ($Requests.Count -eq 0) { return $Result }

    $Responses = @{}
    foreach ($Response in @(New-GraphBulkRequest -tenantid $TargetTenantFilter -Requests @($Requests))) {
        $Responses[[string]$Response.id] = $Response
    }

    foreach ($RequestId in $Lookups.Keys) {
        $Lookup = $Lookups[$RequestId]
        $Response = $Responses[$RequestId]
        $Status = $Response.status -as [int]
        if ($Status -eq 404) { continue }
        if ($Status -lt 200 -or $Status -ge 300) {
            $Reason = if ($Response) { $Response.body.error.message ?? "HTTP $Status" } else { 'no response from Graph' }
            throw "Could not look up $($Lookup.Label) in the target: $Reason"
        }
        if ($SameTenant) {
            if ($Response.body.id) { $Result[$Lookup.Kind][$Lookup.Id] = [string]$Response.body.id }
        } else {
            $Found = foreach ($Candidate in @($Response.body.value)) {
                if ($null -eq $Candidate) { continue }
                $Matched = if ($Lookup.Kind -eq 'Groups') { [string]$Candidate.displayName -ceq $Lookup.Name } else { [string]$Candidate.userPrincipalName -eq $Lookup.Name }
                if ($Matched) { [string]$Candidate.id }
            }
            $Found = @($Found)
            if ($Found.Count -eq 1) {
                $Result[$Lookup.Kind][$Lookup.Id] = $Found[0]
            } elseif ($Found.Count -gt 1) {
                $Result.Missing[$Lookup.Id] = "$($Lookup.Label) matches $($Found.Count) groups in the target, so it was not mapped"
            }
        }
        if ($Result[$Lookup.Kind][$Lookup.Id]) { $Result.Missing.Remove($Lookup.Id) }
    }
    $Result
}
