function Update-CIPPOneDriveCopyToUserStatus {
    <#
    .SYNOPSIS
        Polls a OneDrive copy started by Start-CIPPOneDriveCopyToUser and returns per-recipient state.
    .DESCRIPTION
        Each recipient's copy jobs are polled through Update-CIPPSharePointLibraryCopyStatus (same
        progress parsing and sanitised error messages as the library copy). A recipient's State is
        Queued, InProgress, Completed or Failed. Completed and Failed are final: Failed is only reported
        once every job for that recipient has finished (or the copy never started), and means at least
        one item was not copied. The operation's State is Completed only when every recipient is.
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TenantFilter,

        [Parameter(Mandatory = $true)]
        [string]$OperationId
    )

    $TableName = 'OneDriveCopyToUser'
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

        $Snapshot = Update-CIPPSharePointLibraryCopyStatus -TenantFilter $TenantFilter -OperationId $Record.SubOperationId -TableName $TableName

        $Entry.JobsComplete = [int]$Snapshot.JobsComplete
        $Entry.JobsTotal = [int]$Snapshot.JobsTotal
        $Entry.ItemsCopied = [int64]($Snapshot.FilesCreated ?? 0)
        $Entry.ObjectsProcessed = [int64]($Snapshot.ObjectsProcessed ?? 0)
        $Entry.TotalExpectedObjects = $Snapshot.TotalExpectedObjects
        $Entry.BytesCopied = [int64]($Snapshot.BytesProcessed ?? 0)
        $Entry.ErrorCount = [int64]($Snapshot.TotalErrors ?? 0)
        $Entry.Errors = @($Snapshot.Errors | ForEach-Object { [string]($_.Message ?? $_) } | Where-Object { $_ })
        $Entry.Warnings = @($Snapshot.Warnings | ForEach-Object { [string]($_.Message ?? $_) } | Where-Object { $_ })

        $AllJobsDone = $Entry.JobsTotal -gt 0 -and $Entry.JobsComplete -ge $Entry.JobsTotal
        if ($AllJobsDone -and $Snapshot.Status -eq 'Completed') {
            $Entry.State = 'Completed'
            $Entry.IsComplete = $true
            $Entry.Message = 'Copy completed.'
        } elseif ($AllJobsDone) {
            $Entry.State = 'Failed'
            $Entry.IsComplete = $true
            if ($Entry.ErrorCount -lt 1) { $Entry.ErrorCount = 1 }
            $Entry.Message = "Copy finished, but $($Entry.ErrorCount) error(s) were reported; some items were not copied."
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

    $States = @($Results | ForEach-Object { $_.State })
    $State = if ($States.Count -gt 0 -and @($States | Where-Object { $_ -ne 'Completed' }).Count -eq 0) { 'Completed' }
    elseif (@($States | Where-Object { $_ -notin @('Completed', 'Failed') }).Count -eq 0) { 'Failed' }
    elseif (@($States | Where-Object { $_ -ne 'Queued' }).Count -eq 0) { 'Queued' }
    else { 'InProgress' }

    $Message = switch ($State) {
        'Completed' { 'Copy completed for every recipient.' }
        'Failed' { 'Copy finished, but failed for at least one recipient. Do not remove licences until the failures are resolved.' }
        'Queued' { 'Copy queued.' }
        default { 'Copy in progress.' }
    }

    [PSCustomObject]@{
        OperationId    = $OperationId
        Leaver         = $Operation.LeaverUPN
        StartedBy      = $Operation.StartedBy
        StartedUtc     = $Operation.StartedUtc
        State          = $State
        IsComplete     = $State -in @('Completed', 'Failed')
        AllCompleted   = $State -eq 'Completed'
        RootItemCount  = [int]$Operation.RootItemCount
        ExpectedBytes  = [int64]($Operation.ExpectedBytes ?? 0)
        Recipients     = $Results
        LastUpdatedUtc = ([DateTime]::UtcNow).ToString('o')
        Message        = $Message
    }
}
