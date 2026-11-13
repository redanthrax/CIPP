function Update-CIPPOneDriveCopyToUserStatus {
    <#
    .SYNOPSIS
        Polls a OneDrive copy started by Start-CIPPOneDriveCopyToUser and returns per-recipient state.
    .DESCRIPTION
        Each copy job (one per root item per recipient) has its own state row in the OneDriveCopyToUser
        table, so a status call never has to poll everything:
          - SharePoint is asked at most once per MinimumIntervalSeconds per operation. Inside that
            window the stored job states are returned without calling SharePoint.
          - A check polls at most MaxJobsPerCheck unfinished jobs, least recently polled first, so
            every job is reached over successive checks however many there are.
        Jobs are polled with Get-CIPPSharePointCopyJobProgress, the library copy's parser; the library
        copy's own status code is not used or changed.

        A recipient's State is Queued, InProgress, Completed or Failed. Completed needs every one of its
        jobs to have been polled and confirmed finished without errors; Completed and Failed are final.
        The operation's State is Completed only when every recipient is.
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TenantFilter,

        [Parameter(Mandatory = $true)]
        [string]$OperationId,

        # Minimum time between two checks of SharePoint for one operation.
        [int]$MinimumIntervalSeconds = 60,

        # At most this many unfinished jobs are polled per check (about a second each), which keeps a
        # status call well inside the HTTP timeout.
        [int]$MaxJobsPerCheck = 100
    )

    $TableName = 'OneDriveCopyToUser'
    # A job whose progress cannot be read this many times in a row is given up as failed.
    $MaxPollFailures = 5
    $MaxMessagesPerJob = 25
    $MaxMessagesPerRecipient = 50

    if ($OperationId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        throw [System.ArgumentException]::new('OperationId is not a valid operation id.')
    }

    $Table = Get-CIPPTable -TableName $TableName
    $SafeTenant = $TenantFilter -replace "'", "''"
    $Operation = @(Get-CIPPAzDataTableEntity @Table -Filter "PartitionKey eq '$SafeTenant' and RowKey eq '$OperationId'") | Select-Object -First 1
    if (-not $Operation -or $Operation.Kind -ne 'Operation') {
        throw [System.Management.Automation.ItemNotFoundException]::new('OneDrive copy operation not found.')
    }

    $Records = @()
    if ($Operation.Recipients) { $Records = @($Operation.Recipients | ConvertFrom-Json) }

    $ReadList = {
        param($Value)
        if ([string]::IsNullOrWhiteSpace([string]$Value)) { return @() }
        try { @([string]$Value | ConvertFrom-Json) } catch { @() }
    }

    # --- Stored job states ------------------------------------------------------------------------
    $StatePrefix = "$OperationId-js-"
    $States = @{}
    foreach ($Row in @(Get-CIPPAzDataTableEntity @Table -Filter "PartitionKey eq '$SafeTenant' and RowKey ge '$StatePrefix' and RowKey lt '$OperationId-js.'")) {
        if ($null -eq $Row -or $null -eq $Row.RecipientIndex -or $null -eq $Row.JobIndex) { continue }
        $States["$([int]$Row.RecipientIndex)-$([int]$Row.JobIndex)"] = [PSCustomObject]@{
            RecipientIndex       = [int]$Row.RecipientIndex
            JobIndex             = [int]$Row.JobIndex
            IsFinal              = [bool]$Row.IsFinal
            Failed               = [bool]$Row.Failed
            ObjectsProcessed     = [int64]($Row.ObjectsProcessed ?? 0)
            TotalExpectedObjects = $Row.TotalExpectedObjects
            FilesCreated         = [int64]($Row.FilesCreated ?? 0)
            BytesProcessed       = [int64]($Row.BytesProcessed ?? 0)
            TotalErrors          = [int64]($Row.TotalErrors ?? 0)
            TotalWarnings        = [int64]($Row.TotalWarnings ?? 0)
            ErrorMessages        = @(& $ReadList $Row.ErrorMessages)
            WarningMessages      = @(& $ReadList $Row.WarningMessages)
            PollFailures         = [int]($Row.PollFailures ?? 0)
            LastPolledUnix       = [int64]($Row.LastPolledUnix ?? 0)
        }
    }

    $NewState = {
        param([int]$RecipientIndex, [int]$JobIndex)
        [PSCustomObject]@{
            RecipientIndex = $RecipientIndex; JobIndex = $JobIndex; IsFinal = $false; Failed = $false
            ObjectsProcessed = 0; TotalExpectedObjects = $null; FilesCreated = 0; BytesProcessed = 0
            TotalErrors = 0; TotalWarnings = 0; ErrorMessages = @(); WarningMessages = @(); PollFailures = 0; LastPolledUnix = 0
        }
    }
    $AddMessages = {
        param([object[]]$Existing, [object[]]$New)
        $Seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $List = [System.Collections.Generic.List[string]]::new()
        foreach ($Message in @($Existing) + @($New)) {
            if ([string]::IsNullOrWhiteSpace([string]$Message)) { continue }
            if ($List.Count -ge $MaxMessagesPerJob) { break }
            if ($Seen.Add([string]$Message)) { $List.Add([string]$Message) }
        }
        @($List)
    }
    # Folds one progress reading into a job's stored state and decides whether the job is final.
    $MergeProgress = {
        param($State, $Progress)
        $State.PollFailures = 0
        $State.ObjectsProcessed = [int64]($Progress.ObjectsProcessed ?? 0)
        $State.TotalExpectedObjects = $Progress.TotalExpectedObjects
        $State.FilesCreated = [int64]($Progress.FilesCreated ?? 0)
        $State.BytesProcessed = [int64]($Progress.BytesProcessed ?? 0)
        $State.TotalErrors = [int64]($Progress.TotalErrors ?? 0)
        $State.TotalWarnings = [int64]($Progress.TotalWarnings ?? 0)
        $State.ErrorMessages = @(& $AddMessages @() $Progress.ErrorMessages)
        $State.WarningMessages = @(& $AddMessages @() $Progress.WarningMessages)
        if ($Progress.IsComplete) {
            $State.IsFinal = $true
            $State.Failed = $State.TotalErrors -gt 0
        }
    }

    # --- Check SharePoint, rate limited -----------------------------------------------------------
    $Now = [int64]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    $LastChecked = [int64]($Operation.LastCheckedUnix ?? 0)
    $Polled = 0
    $CheckedSharePoint = $false
    if ($Now - $LastChecked -ge $MinimumIntervalSeconds) {
        $CheckedSharePoint = $true
        $LastChecked = $Now
        # Claimed before polling, so concurrent status calls inside the window read the stored states.
        Add-CIPPAzDataTableEntity @Table -Entity @{ PartitionKey = $TenantFilter; RowKey = $OperationId; LastCheckedUnix = $Now } -OperationType UpsertMerge

        $Candidates = foreach ($Record in $Records) {
            if ($Record.StartError -or [int]$Record.JobCount -le 0) { continue }
            for ($j = 0; $j -lt [int]$Record.JobCount; $j++) {
                $State = $States["$([int]$Record.Index)-$j"]
                if ($State -and $State.IsFinal) { continue }
                [PSCustomObject]@{ Record = $Record; JobIndex = $j; LastPolledUnix = if ($State) { $State.LastPolledUnix } else { 0 } }
            }
        }
        $Selected = @($Candidates | Sort-Object LastPolledUnix, { [int]$_.Record.Index }, JobIndex | Select-Object -First $MaxJobsPerCheck)

        $Changed = [System.Collections.Generic.List[object]]::new()
        foreach ($Group in @($Selected | Group-Object { [int]$_.Record.Index })) {
            $Record = $Group.Group[0].Record
            $Sub = Get-CIPPSharePointLibraryCopyOperation -TenantFilter $TenantFilter -OperationId $Record.SubOperationId -TableName $TableName
            if (-not $Sub) {
                throw [System.Management.Automation.ItemNotFoundException]::new("Copy jobs for $($Record.UserPrincipalName) not found.")
            }
            foreach ($Candidate in $Group.Group) {
                $Key = "$([int]$Record.Index)-$($Candidate.JobIndex)"
                $State = $States[$Key] ?? (& $NewState ([int]$Record.Index) $Candidate.JobIndex)
                $Handle = @($Sub.CopyJobInfos)[$Candidate.JobIndex]
                if ($null -eq $Handle) {
                    $State.IsFinal = $true
                    $State.Failed = $true
                    $State.ErrorMessages = @(& $AddMessages $State.ErrorMessages @('SharePoint returned no copy job for this item.'))
                } else {
                    try {
                        $Progress = Get-CIPPSharePointCopyJobProgress -TenantFilter $TenantFilter -SourceSiteUrl $Sub.SourceSiteUrl -CopyJobInfo $Handle
                        & $MergeProgress $State $Progress
                    } catch {
                        $Detail = [regex]::Replace([string]$_.Exception.Message, 'https?://[^\s''"]+', '[url redacted]', 'IgnoreCase')
                        $Detail = ($Detail -replace '\s{2,}', ' ').Trim()
                        if ($Detail.Length -gt 280) { $Detail = $Detail.Substring(0, 280).Trim() + '…' }
                        $State.PollFailures++
                        if ($State.PollFailures -ge $MaxPollFailures) {
                            $State.IsFinal = $true
                            $State.Failed = $true
                            $State.ErrorMessages = @(& $AddMessages $State.ErrorMessages @("Progress could not be read $MaxPollFailures times in a row: $Detail"))
                        }
                    }
                }
                $State.LastPolledUnix = $Now
                $States[$Key] = $State
                $Polled++
                $StateRowKey = '{0}{1}-{2:D4}' -f $StatePrefix, $State.RecipientIndex, $State.JobIndex
                $Changed.Add(@{
                        PartitionKey     = $TenantFilter
                        RowKey           = $StateRowKey
                        RecipientIndex   = $State.RecipientIndex
                        JobIndex         = $State.JobIndex
                        IsFinal          = [bool]$State.IsFinal
                        Failed           = [bool]$State.Failed
                        ObjectsProcessed = [int64]$State.ObjectsProcessed
                        TotalExpectedObjects = if ($null -ne $State.TotalExpectedObjects) { [int64]$State.TotalExpectedObjects } else { $null }
                        FilesCreated     = [int64]$State.FilesCreated
                        BytesProcessed   = [int64]$State.BytesProcessed
                        TotalErrors      = [int64]$State.TotalErrors
                        TotalWarnings    = [int64]$State.TotalWarnings
                        ErrorMessages    = (ConvertTo-Json -InputObject @($State.ErrorMessages) -Compress)
                        WarningMessages  = (ConvertTo-Json -InputObject @($State.WarningMessages) -Compress)
                        PollFailures     = [int]$State.PollFailures
                        LastPolledUnix   = [int64]$State.LastPolledUnix
                    })
            }
        }
        if ($Changed.Count -gt 0) {
            Add-CIPPAzDataTableEntity @Table -Entity @($Changed) -Force
        }
    }

    # --- Per-recipient and overall state ----------------------------------------------------------
    $Results = foreach ($Record in $Records) {
        $Entry = [ordered]@{
            UserPrincipalName    = $Record.UserPrincipalName
            FolderName           = $Record.FolderName
            State                = 'Queued'
            IsComplete           = $false
            JobsComplete         = 0
            JobsTotal            = [int]$Record.JobCount
            ItemsCopied          = 0
            ObjectsProcessed     = 0
            TotalExpectedObjects = $null
            BytesCopied          = 0
            ErrorCount           = 0
            Errors               = @()
            Warnings             = @()
            Message              = 'Copy queued.'
        }

        if ($Record.StartError) {
            $Entry.State = 'Failed'
            $Entry.IsComplete = $true
            $Entry.ErrorCount = 1
            $Entry.Errors = @([string]$Record.StartError)
            $Entry.Message = [string]$Record.StartError
            [PSCustomObject]$Entry
            continue
        }

        $JobStates = @(for ($j = 0; $j -lt $Entry.JobsTotal; $j++) { $States["$([int]$Record.Index)-$j"] })
        $Known = @($JobStates | Where-Object { $_ })
        $FailedJobs = @($Known | Where-Object { $_.Failed })
        $Entry.JobsComplete = @($Known | Where-Object { $_.IsFinal }).Count
        $Entry.ItemsCopied = [int64](($Known | ForEach-Object { $_.FilesCreated } | Measure-Object -Sum).Sum)
        $Entry.ObjectsProcessed = [int64](($Known | ForEach-Object { $_.ObjectsProcessed } | Measure-Object -Sum).Sum)
        $Expected = @($Known | Where-Object { $null -ne $_.TotalExpectedObjects } | ForEach-Object { [int64]$_.TotalExpectedObjects })
        $Entry.TotalExpectedObjects = if ($Expected.Count -gt 0) { [int64](($Expected | Measure-Object -Sum).Sum) } else { $null }
        $Entry.BytesCopied = [int64](($Known | ForEach-Object { $_.BytesProcessed } | Measure-Object -Sum).Sum)
        $Entry.ErrorCount = [int64](($Known | ForEach-Object { [Math]::Max([int64]$_.TotalErrors, [int64]($_.Failed -and $_.TotalErrors -eq 0)) } | Measure-Object -Sum).Sum)
        $Entry.Errors = @($Known | ForEach-Object { $_.ErrorMessages } | Where-Object { $_ } | Select-Object -Unique | Select-Object -First $MaxMessagesPerRecipient)
        $Entry.Warnings = @($Known | ForEach-Object { $_.WarningMessages } | Where-Object { $_ } | Select-Object -Unique | Select-Object -First $MaxMessagesPerRecipient)

        # Completed only when every job has been polled and confirmed finished.
        $AllJobsDone = $Entry.JobsTotal -gt 0 -and $Known.Count -eq $Entry.JobsTotal -and $Entry.JobsComplete -eq $Entry.JobsTotal
        if ($AllJobsDone -and $FailedJobs.Count -eq 0) {
            $Entry.State = 'Completed'
            $Entry.IsComplete = $true
            $Entry.Message = 'Copy completed.'
        } elseif ($AllJobsDone) {
            $Entry.State = 'Failed'
            $Entry.IsComplete = $true
            if ($Entry.ErrorCount -lt 1) { $Entry.ErrorCount = 1 }
            $Entry.Message = "Copy finished, but $($FailedJobs.Count) of $($Entry.JobsTotal) root item(s) failed; some items were not copied."
        } elseif ($Entry.JobsComplete -eq 0 -and $Entry.ObjectsProcessed -eq 0) {
            $Entry.State = 'Queued'
            $Entry.Message = 'Copy queued.'
        } else {
            $Entry.State = 'InProgress'
            $Entry.Message = "Copy in progress ($($Entry.JobsComplete) of $($Entry.JobsTotal) root items done)."
        }
        [PSCustomObject]$Entry
    }
    $Results = @($Results)

    $RecipientStates = @($Results | ForEach-Object { $_.State })
    $State = if ($RecipientStates.Count -gt 0 -and @($RecipientStates | Where-Object { $_ -ne 'Completed' }).Count -eq 0) { 'Completed' }
    elseif ($RecipientStates.Count -gt 0 -and @($RecipientStates | Where-Object { $_ -notin @('Completed', 'Failed') }).Count -eq 0) { 'Failed' }
    elseif (@($RecipientStates | Where-Object { $_ -ne 'Queued' }).Count -eq 0) { 'Queued' }
    else { 'InProgress' }

    $Message = switch ($State) {
        'Completed' { 'Copy completed for every recipient.' }
        'Failed' { 'Copy finished, but failed for at least one recipient. Do not remove licences until the failures are resolved.' }
        'Queued' { 'Copy queued.' }
        default { 'Copy in progress.' }
    }

    [PSCustomObject]@{
        OperationId       = $OperationId
        Leaver            = $Operation.LeaverUPN
        StartedBy         = $Operation.StartedBy
        StartedUtc        = $Operation.StartedUtc
        State             = $State
        IsComplete        = $State -in @('Completed', 'Failed')
        AllCompleted      = $State -eq 'Completed'
        RootItemCount     = [int]$Operation.RootItemCount
        ExpectedBytes     = [int64]($Operation.ExpectedBytes ?? 0)
        Recipients        = $Results
        CheckedSharePoint = $CheckedSharePoint
        JobsPolled        = $Polled
        LastCheckedUtc    = if ($LastChecked -gt 0) { [DateTimeOffset]::FromUnixTimeSeconds($LastChecked).UtcDateTime.ToString('o') } else { $null }
        NextCheckAfterUtc = if ($LastChecked -gt 0) { [DateTimeOffset]::FromUnixTimeSeconds($LastChecked + $MinimumIntervalSeconds).UtcDateTime.ToString('o') } else { $null }
        LastUpdatedUtc    = ([DateTime]::UtcNow).ToString('o')
        Message           = $Message
    }
}
