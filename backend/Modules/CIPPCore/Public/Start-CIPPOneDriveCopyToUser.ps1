function Start-CIPPOneDriveCopyToUser {
    <#
    .SYNOPSIS
        Copies a leaver's OneDrive root contents into a folder named after the leaver's UPN in each recipient's OneDrive.
    .DESCRIPTION
        Everything is checked before anything is written: the leaver must already be blocked from signing
        in (accountEnabled false), and the leaver and every recipient are resolved in
        $TenantFilter, each recipient must have a OneDrive licence, a OneDrive on the same host as the
        leaver's, and enough free quota for the leaver's files. Any refusal throws ArgumentException
        naming every problem, and nothing is created.

        Then, per recipient, the folder /<leaver UPN> is created at the root of their OneDrive (or
        reused) and one SharePoint CreateCopyJobs job per root item of the leaver's OneDrive is
        submitted into it, with NameConflictBehavior KeepBoth so nothing that is already there is
        overwritten. Jobs are stored per recipient in the OneDriveCopyToUser table and polled by
        Update-CIPPOneDriveCopyToUserStatus.
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TenantFilter,

        # UPN or object id of the user whose OneDrive is copied.
        [Parameter(Mandatory = $true)]
        [string]$Leaver,

        # UPNs or object ids of the users who receive the copy.
        [Parameter(Mandatory = $true)]
        [string[]]$Recipients,

        # Copy every version of each file instead of only the current one. Off by default: version
        # history can use many times the space the quota check counts.
        [bool]$IncludeVersionHistory = $false,

        [string]$StartedBy,

        # Internal: lets the offboarding job name the operation up front, so its licence step waits
        # for exactly this copy. Not exposed by the HTTP endpoint. An id that is already in use is refused.
        [string]$OperationId,

        $Headers,
        $APIName = 'OneDrive Copy To User'
    )

    $TableName = 'OneDriveCopyToUser'
    $MaxRecipients = 10
    $MaxRootItems = 1000
    $JobsPerRequest = 100
    $KeepBoth = 2
    # SharePoint's documented limit for one move/copy across sites; each root item is its own job.
    $PerJobByteLimit = 100GB

    if ($OperationId) {
        if ($OperationId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
            throw [System.ArgumentException]::new('OperationId is not a valid operation id.')
        }
        $IdTable = Get-CIPPTable -TableName $TableName
        $SafeTenant = $TenantFilter -replace "'", "''"
        if (@(Get-CIPPAzDataTableEntity @IdTable -Filter "PartitionKey eq '$SafeTenant' and RowKey eq '$OperationId'").Count -gt 0) {
            throw [System.ArgumentException]::new("OneDrive copy $OperationId already exists; it was not started again.")
        }
    }

    $RecipientIds = @($Recipients | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } |
            Sort-Object -Unique)
    if ($RecipientIds.Count -eq 0) {
        throw [System.ArgumentException]::new('At least one recipient is required.')
    }
    if ($RecipientIds.Count -gt $MaxRecipients) {
        throw [System.ArgumentException]::new("At most $MaxRecipients recipients can receive one copy.")
    }

    # --- Preflight: nothing is written until every check has passed ---------------------------
    $Source = Get-CIPPOneDriveCopyUser -TenantFilter $TenantFilter -UserId $Leaver -Kind Leaver
    $FolderName = $Source.UserPrincipalName
    # Only a blocked account is copied: a leaver who can still sign in could keep changing the files
    # while they are copied. Anything but an explicit false (including not returned) is refused.
    if ($Source.AccountEnabled -ne $false) {
        throw [System.ArgumentException]::new("Leaver $($Source.UserPrincipalName) can still sign in. Block sign-in for the account first, then start the copy.")
    }

    $Children = @(New-GraphGetRequest -uri "https://graph.microsoft.com/v1.0/drives/$($Source.DriveId)/root/children?`$select=id,name,size,folder,file,package&`$top=999" -tenantid $TenantFilter -asapp $true)
    $RootItems = @($Children | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.name) -and ($_.folder -or $_.file -or $_.package) })
    if ($RootItems.Count -eq 0) {
        throw [System.ArgumentException]::new("Leaver $($Source.UserPrincipalName)'s OneDrive has nothing to copy.")
    }
    if ($RootItems.Count -gt $MaxRootItems) {
        throw [System.ArgumentException]::new("Leaver $($Source.UserPrincipalName)'s OneDrive has $($RootItems.Count) items at its root (limit $MaxRootItems). Group files into folders and try again.")
    }
    $SourceBytes = [int64](($RootItems | ForEach-Object { [int64]($_.size ?? 0) } | Measure-Object -Sum).Sum)

    $Warnings = [System.Collections.Generic.List[string]]::new()
    $Oversized = @($RootItems | Where-Object { [int64]($_.size ?? 0) -gt $PerJobByteLimit })
    if ($Oversized.Count -gt 0) {
        $Warnings.Add("$($Oversized.Count) root item(s) are larger than 100 GB, SharePoint's limit for one copy job. Those items are likely to fail; split them into smaller folders and copy again.")
    }

    $Targets = [System.Collections.Generic.List[object]]::new()
    $Problems = [System.Collections.Generic.List[string]]::new()
    foreach ($RecipientId in $RecipientIds) {
        try {
            $Target = Get-CIPPOneDriveCopyUser -TenantFilter $TenantFilter -UserId $RecipientId -Kind Recipient
        } catch [System.ArgumentException] {
            $Problems.Add($_.Exception.Message)
            continue
        }
        if ($Target.UserId -eq $Source.UserId) {
            $Problems.Add("Recipient $($Target.UserPrincipalName) is the leaver.")
            continue
        }
        if (@($Targets | Where-Object { $_.UserId -eq $Target.UserId }).Count -gt 0) { continue }
        if ($Target.DriveHost -ne $Source.DriveHost) {
            $Problems.Add("Recipient $($Target.UserPrincipalName)'s OneDrive is not in the same tenant as the leaver's.")
            continue
        }
        if ($null -ne $Target.QuotaRemaining -and $Target.QuotaRemaining -lt $SourceBytes) {
            $Problems.Add("Recipient $($Target.UserPrincipalName) does not have enough space: the copy needs $SourceBytes bytes and $($Target.QuotaRemaining) are free.")
            continue
        }
        if ($null -eq $Target.QuotaRemaining) {
            $Warnings.Add("Free space in $($Target.UserPrincipalName)'s OneDrive could not be read, so it was not checked.")
        }
        $Targets.Add($Target)
    }
    if ($Problems.Count -gt 0) {
        throw [System.ArgumentException]::new("OneDrive copy not started. $($Problems -join ' ')")
    }

    # CreateCopyJobs takes absolute URLs. Graph's webUrl is one for folders, but for Office files
    # it can be a _layouts/Doc.aspx link, so build the path from the library URL instead.
    $SourceUris = @($RootItems | ForEach-Object {
            "$($Source.DriveWebUrl)/$([System.Uri]::EscapeDataString([string]$_.name))"
        })

    # --- Destination folders (created or reused) -------------------------------------------------
    foreach ($Target in $Targets) {
        $Folder = $null
        $Created = $false
        $FolderPath = "https://graph.microsoft.com/v1.0/drives/$($Target.DriveId)/root:/$([System.Uri]::EscapeDataString($FolderName))"
        try {
            $Body = ConvertTo-Json -Compress -InputObject @{
                name                                = $FolderName
                folder                              = @{}
                '@microsoft.graph.conflictBehavior' = 'fail'
            }
            $Folder = New-GraphPOSTRequest -uri "https://graph.microsoft.com/v1.0/drives/$($Target.DriveId)/root/children" -tenantid $TenantFilter -type POST -body $Body -AsApp $true
            $Created = $true
        } catch {
            $CreateError = $_
            if ($CreateError.Exception.Message -notmatch 'nameAlreadyExists|already exists|conflict|409') { throw }
            $Folder = New-GraphGetRequest -uri "$FolderPath`?`$select=id,name,webUrl,folder,file" -tenantid $TenantFilter -asapp $true
        }
        if (-not $Folder.id) {
            throw "Could not create or find the folder $FolderName in $($Target.UserPrincipalName)'s OneDrive."
        }
        if (-not $Created -and -not $Folder.folder) {
            throw [System.ArgumentException]::new("Recipient $($Target.UserPrincipalName) already has a file named $FolderName at the root of their OneDrive. Rename it and try again.")
        }
        $DestinationUri = "$($Target.DriveWebUrl)/$([System.Uri]::EscapeDataString($FolderName))"
        $Target | Add-Member -NotePropertyName FolderId -NotePropertyValue ([string]$Folder.id) -Force
        $Target | Add-Member -NotePropertyName FolderCreated -NotePropertyValue $Created -Force
        $Target | Add-Member -NotePropertyName DestinationUri -NotePropertyValue $DestinationUri -Force
    }

    # --- Copy jobs ------------------------------------------------------------------------------
    if (-not $OperationId) { $OperationId = (New-Guid).Guid }
    $Expiry = ([DateTime]::UtcNow.AddDays(14)).ToString('o')
    $RecipientRecords = [System.Collections.Generic.List[object]]::new()
    $Index = 0
    foreach ($Target in $Targets) {
        $SubOperationId = "$OperationId-r$Index"
        $Record = [ordered]@{
            Index             = $Index
            UserId            = $Target.UserId
            UserPrincipalName = $Target.UserPrincipalName
            FolderName        = $FolderName
            FolderCreated     = [bool]$Target.FolderCreated
            SubOperationId    = $SubOperationId
            JobCount          = 0
            StartError        = $null
        }
        try {
            $Jobs = [System.Collections.Generic.List[object]]::new()
            for ($i = 0; $i -lt $SourceUris.Count; $i += $JobsPerRequest) {
                $Batch = @($SourceUris[$i..([Math]::Min($i + $JobsPerRequest, $SourceUris.Count) - 1)])
                foreach ($Job in @(Invoke-CIPPSharePointCreateCopyJobs -TenantFilter $TenantFilter -SourceSiteUrl $Source.SiteUrl `
                            -ExportObjectUris $Batch -DestinationUri $Target.DestinationUri -NameConflictBehavior $KeepBoth `
                            -SameWebCopyMoveOptimization $false -IgnoreVersionHistory (-not $IncludeVersionHistory))) {
                    $Jobs.Add($Job)
                }
            }
            $Record.JobCount = $Jobs.Count
            Set-CIPPSharePointLibraryCopyOperation -TenantFilter $TenantFilter -OperationId $SubOperationId -TableName $TableName -Entity @{
                SourceSiteUrl     = $Source.SiteUrl
                SourceSiteName    = $Source.UserPrincipalName
                SourceLibraryName = 'OneDrive'
                DestSiteName      = $Target.UserPrincipalName
                DestLibraryName   = $FolderName
                StartedBy         = $StartedBy
                Status            = 'Processing'
                JobHandleCount    = $Jobs.Count
                Expiry            = $Expiry
                CopyJobInfos      = @($Jobs)
                HandleStates      = (ConvertTo-Json -InputObject @($Jobs | ForEach-Object { [PSCustomObject]@{ Status = 'Queued'; IsComplete = $false } }) -Compress -Depth 4)
            }
        } catch {
            $Detail = (Get-CippException -Exception $_).NormalizedError
            $Detail = [regex]::Replace([string]$Detail, 'https?://[^\s''"]+', '[url redacted]', 'IgnoreCase')
            $Record.StartError = "Copy failed to start: $Detail"
            Write-LogMessage -headers $Headers -API $APIName -tenant $TenantFilter -sev Error `
                -message "OneDrive copy $OperationId could not start for $($Target.UserPrincipalName): $Detail" -LogData (Get-CippException -Exception $_)
        }
        $RecipientRecords.Add([PSCustomObject]$Record)
        $Index++
    }

    if (@($RecipientRecords | Where-Object { -not $_.StartError }).Count -eq 0) {
        throw "OneDrive copy failed to start for every recipient. $(@($RecipientRecords | ForEach-Object { "$($_.UserPrincipalName): $($_.StartError)" }) -join ' ')"
    }

    $StartedAt = [DateTimeOffset]::UtcNow
    $StartedUtc = $StartedAt.UtcDateTime.ToString('o')
    $Table = Get-CIPPTable -TableName $TableName
    Add-CIPPAzDataTableEntity @Table -Force -Entity @{
        PartitionKey          = $TenantFilter
        RowKey                = $OperationId
        Kind                  = 'Operation'
        LeaverId              = $Source.UserId
        LeaverUPN             = $Source.UserPrincipalName
        StartedBy             = [string]$StartedBy
        StartedUtc            = $StartedUtc
        StartedUnix           = [int64]$StartedAt.ToUnixTimeSeconds()
        RootItemCount         = $RootItems.Count
        ExpectedBytes         = $SourceBytes
        IncludeVersionHistory = $IncludeVersionHistory
        Expiry                = $Expiry
        Recipients            = (ConvertTo-Json -InputObject @($RecipientRecords) -Compress -Depth 4)
    }

    $Names = ($RecipientRecords | ForEach-Object { $_.UserPrincipalName }) -join ', '
    Write-LogMessage -headers $Headers -API $APIName -tenant $TenantFilter -sev Info `
        -message "OneDrive copy $OperationId started by $StartedBy`: $($Source.UserPrincipalName) to $Names (folder $FolderName, $($RootItems.Count) root items, $SourceBytes bytes)"

    [PSCustomObject]@{
        OperationId   = $OperationId
        Leaver        = $Source.UserPrincipalName
        FolderName    = $FolderName
        RootItemCount = $RootItems.Count
        ExpectedBytes = $SourceBytes
        StartedBy     = [string]$StartedBy
        StartedUtc    = $StartedUtc
        Recipients    = @($RecipientRecords | ForEach-Object {
                [PSCustomObject]@{
                    UserPrincipalName = $_.UserPrincipalName
                    FolderCreated     = $_.FolderCreated
                    State             = if ($_.StartError) { 'Failed' } else { 'Queued' }
                    JobCount          = $_.JobCount
                    Message           = if ($_.StartError) { $_.StartError } else { 'Copy queued.' }
                }
            })
        Warnings      = @($Warnings)
        Message       = 'OneDrive copy started. Poll ListOneDriveCopyToUser with the OperationId until State is Completed before removing licences.'
    }
}
