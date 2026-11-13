function Remove-CIPPLicenseAfterOneDriveCopy {
    <#
    .SYNOPSIS
        Removes a leaver's licences only once their OneDrive copy has completed.
    .DESCRIPTION
        Used by the offboarding job in place of Remove-CIPPLicense when "Copy OneDrive to user(s)" is
        selected, because removing the licence starts the countdown to the OneDrive being deleted.

        Offboarding run (no OperationId): finds the copy the same offboarding started (the newest
        OneDriveCopyToUser operation for this user that started at or after CopyStartedAfter) and checks
        it once.
          - Completed: hands over to Remove-CIPPLicense -Schedule, exactly as the normal step does.
          - Still queued or in progress: schedules itself as a recurring task (every 30 minutes) that
            checks again and removes the licences when the copy completes.
          - Failed, or no copy found (the copy step failed or was skipped): licences are NOT removed;
            the step fails with the reason.

        Scheduled run (OperationId given): Completed removes the licences directly and ends the
        recurrence; Failed, an unknown operation, or passing Deadline ends the recurrence without
        removing them; otherwise it waits for the next check. Every outcome that leaves the licences in
        place is logged as an error, so it shows in the CIPP log and alerts.
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TenantFilter,

        # Object id of the leaver.
        [Parameter(Mandatory = $true)]
        [string]$userid,

        [string]$username,

        # Unix time the offboarding job was built; a copy started before it (allowing two minutes of
        # clock skew between workers) belongs to another run.
        [int64]$CopyStartedAfter = 0,

        # Set by the follow-up scheduled task.
        [string]$OperationId,

        # Unix time after which the follow-up task stops waiting (0 = no deadline).
        [int64]$Deadline = 0,

        $APIName = 'Remove License',
        $Headers
    )

    $GuidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    if ($userid -notmatch $GuidPattern) { throw "Licences not removed: '$userid' is not a user object id." }
    $Name = if ($username) { $username } else { $userid }
    $Scheduled = -not [string]::IsNullOrWhiteSpace($OperationId)

    # Ends the recurring task this runs in (see Invoke-CIPPIntuneApprovalRetry). A no-op outside the scheduler.
    $StopChecking = {
        param([string]$Message, [string]$Sev)
        Write-LogMessage -headers $Headers -API $APIName -tenant $TenantFilter -message $Message -sev $Sev
        $TaskId = $script:CippScheduledTaskIdStorage.Value
        if ($TaskId) {
            $Table = Get-CippTable -tablename 'ScheduledTasks'
            $null = Update-AzDataTableEntity -Force @Table -Entity @{ PartitionKey = 'ScheduledTask'; RowKey = [string]$TaskId; Recurrence = '0' }
        }
        $Message
    }
    $KeptMessage = { param($Reason) "Licences were NOT removed for $Name because $Reason Remove them manually once the OneDrive has been copied." }

    if (-not $Scheduled) {
        $Table = Get-CIPPTable -TableName 'OneDriveCopyToUser'
        $SafeTenant = $TenantFilter -replace "'", "''"
        $Operation = @(Get-CIPPAzDataTableEntity @Table -Filter "PartitionKey eq '$SafeTenant' and Kind eq 'Operation' and LeaverId eq '$userid'") |
            Where-Object { [int64]($_.StartedUnix ?? 0) -ge ($CopyStartedAfter - 120) } |
            Sort-Object { [int64]($_.StartedUnix ?? 0) } -Descending | Select-Object -First 1
        if (-not $Operation) {
            $Message = & $KeptMessage 'the OneDrive copy step did not start a copy.'
            Write-LogMessage -headers $Headers -API $APIName -tenant $TenantFilter -message $Message -sev Error
            throw $Message
        }
        $OperationId = [string]$Operation.RowKey
    }

    try {
        $Status = Update-CIPPOneDriveCopyToUserStatus -TenantFilter $TenantFilter -OperationId $OperationId
    } catch [System.Management.Automation.ItemNotFoundException] {
        $Message = & $KeptMessage "OneDrive copy $OperationId could not be found."
        if ($Scheduled) { return & $StopChecking $Message 'Error' }
        Write-LogMessage -headers $Headers -API $APIName -tenant $TenantFilter -message $Message -sev Error
        throw $Message
    }

    switch ($Status.State) {
        'Completed' {
            Write-LogMessage -headers $Headers -API $APIName -tenant $TenantFilter -sev Info `
                -message "OneDrive copy $OperationId for $Name completed ($(@($Status.Recipients | ForEach-Object { "$($_.UserPrincipalName): $($_.ItemsCopied) files, $($_.BytesCopied) bytes" }) -join '; ')). Removing licences."
            if ($Scheduled) {
                $Result = Remove-CIPPLicense -userid $userid -username $username -TenantFilter $TenantFilter -APIName $APIName -Headers $Headers
                return & $StopChecking "OneDrive copy $OperationId completed. $(@($Result) -join ' ')" 'Info'
            }
            return Remove-CIPPLicense -userid $userid -username $username -TenantFilter $TenantFilter -APIName $APIName -Headers $Headers -Schedule
        }
        'Failed' {
            $Details = @($Status.Recipients | Where-Object { $_.State -eq 'Failed' } | ForEach-Object { "$($_.UserPrincipalName): $($_.Message)" }) -join ' '
            $Message = & $KeptMessage "OneDrive copy $OperationId failed. $Details"
            if ($Scheduled) { return & $StopChecking $Message 'Error' }
            Write-LogMessage -headers $Headers -API $APIName -tenant $TenantFilter -message $Message -sev Error
            throw $Message
        }
    }

    # Still queued or in progress.
    $Now = [int64]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    if ($Scheduled) {
        if ($Deadline -gt 0 -and $Now -gt $Deadline) {
            return & $StopChecking (& $KeptMessage "OneDrive copy $OperationId had not completed by the deadline (state $($Status.State)).") 'Error'
        }
        return "OneDrive copy $OperationId is $($Status.State). Licences for $Name will be removed once it completes."
    }

    # The copy expires from storage after 14 days, so stop waiting just before that.
    $ScheduledTask = @{
        TenantFilter  = $TenantFilter
        Name          = "Remove License after OneDrive copy: $Name"
        Command       = @{ value = 'Remove-CIPPLicenseAfterOneDriveCopy' }
        Parameters    = [pscustomobject]@{
            userid      = $userid
            username    = $username
            OperationId = $OperationId
            Deadline    = $Now + 13 * 86400
            APIName     = 'Scheduled License Removal'
            Headers     = $Headers
        }
        ScheduledTime = $Now + 1800
        Recurrence    = '30m'
        PostExecution = @{ Webhook = $false; Email = $false; PSA = $false }
        Reference     = "OneDriveCopy-$OperationId"
    }
    Add-CIPPScheduledTask -Task $ScheduledTask -hidden $false -DisallowDuplicateName $true | Out-Null
    $Message = "OneDrive copy $OperationId is $($Status.State). Licence removal for $Name is deferred: CIPP checks every 30 minutes and removes the licences once the copy completes, or leaves them in place if it fails."
    Write-LogMessage -headers $Headers -API $APIName -tenant $TenantFilter -message $Message -sev Info
    return $Message
}
