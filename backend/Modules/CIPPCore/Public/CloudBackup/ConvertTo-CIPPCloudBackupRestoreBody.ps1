function ConvertTo-CIPPCloudBackupRestoreBody {
    <#
    .SYNOPSIS
        Copies a backed-up Graph object into a writable request body
    .DESCRIPTION
        Returns a deep copy as nested hashtables, without the named top-level properties and without the OData
        annotations Graph rejects on a write (context, links, etags) at any depth. @odata.type and @odata.bind are kept.
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Item,
        [string[]]$Remove = @()
    )

    $Body = ConvertTo-Json -InputObject $Item -Depth 100 -Compress | ConvertFrom-Json -AsHashtable -Depth 100
    foreach ($Name in $Remove) { if ($Name) { $Body.Remove($Name) } }

    $Pending = [System.Collections.Generic.Stack[object]]::new()
    $Pending.Push($Body)
    while ($Pending.Count -gt 0) {
        $Node = $Pending.Pop()
        if ($Node -is [System.Collections.IDictionary]) {
            foreach ($Key in @($Node.Keys)) {
                if ($Key -match '@odata\.(context|navigationLink|associationLink|editLink|mediaReadLink|etag|id|count|nextLink)$') {
                    $Node.Remove($Key)
                    continue
                }
                $Value = $Node[$Key]
                if ($null -ne $Value -and $Value -isnot [string]) { $Pending.Push($Value) }
            }
        } elseif ($Node -is [System.Collections.IList]) {
            foreach ($Child in $Node) {
                if ($null -ne $Child -and $Child -isnot [string]) { $Pending.Push($Child) }
            }
        }
    }
    $Body
}
