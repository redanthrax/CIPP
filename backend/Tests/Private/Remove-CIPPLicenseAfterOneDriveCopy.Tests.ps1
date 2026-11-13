# Pester tests for Remove-CIPPLicenseAfterOneDriveCopy: licences are only removed once the copy has completed

BeforeAll {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    $FunctionPath = Join-Path $RepoRoot 'Modules/CIPPCore/Public/Remove-CIPPLicenseAfterOneDriveCopy.ps1'

    function Get-CIPPTable { param($TableName) @{ TableName = $TableName } }
    function Get-CippTable { param($tablename) @{ TableName = $tablename } }
    function Get-CIPPAzDataTableEntity { param($Filter, $TableName) }
    function Update-AzDataTableEntity { param($Entity, [switch]$Force, $TableName) }
    function Update-CIPPOneDriveCopyToUserStatus { param($TenantFilter, $OperationId) }
    function Remove-CIPPLicense { param($Headers, $userid, $username, $APIName, $TenantFilter, [switch]$Schedule) }
    function Add-CIPPScheduledTask { param($Task, $hidden, $DisallowDuplicateName) }
    function Write-LogMessage { param($headers, $API, $tenant, $message, $sev) }

    . $FunctionPath

    $script:UserId = 'aaaaaaaa-1111-2222-3333-444444444444'
    $script:OpId = '11111111-2222-3333-4444-555555555555'
    $script:Base = @{ TenantFilter = 'contoso.com'; userid = $script:UserId; username = 'pat@contoso.com' }
    function New-Status([string]$State) {
        [pscustomobject]@{ State = $State; Recipients = @([pscustomobject]@{ UserPrincipalName = 'bob@contoso.com'; State = $State; Message = "Copy $State."; ItemsCopied = 5; BytesCopied = 50 }) }
    }
}

Describe 'Remove-CIPPLicenseAfterOneDriveCopy' {
    BeforeEach {
        $script:Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $script:Rows = @(
            [pscustomobject]@{ RowKey = 'old-op'; Kind = 'Operation'; LeaverId = $script:UserId; StartedUnix = $script:Now - 86400 }
            [pscustomobject]@{ RowKey = $script:OpId; Kind = 'Operation'; LeaverId = $script:UserId; StartedUnix = $script:Now }
        )
        Mock Get-CIPPAzDataTableEntity { $script:Rows }
        Mock Update-CIPPOneDriveCopyToUserStatus { New-Status 'Completed' }
        Mock Remove-CIPPLicense { if ($Schedule) { 'Scheduled license removal for pat@contoso.com.' } else { 'Removed licenses for pat@contoso.com.' } }
        Mock Add-CIPPScheduledTask { }
        Mock Update-AzDataTableEntity { }
        Mock Write-LogMessage { }
        $script:CippScheduledTaskIdStorage = $null
    }

    Context 'offboarding run' {
        It 'hands over to the normal scheduled licence removal when the copy has completed' {
            $Result = Remove-CIPPLicenseAfterOneDriveCopy @script:Base -CopyStartedAfter ($script:Now - 10)
            $Result | Should -Be 'Scheduled license removal for pat@contoso.com.'
            Should -Invoke Update-CIPPOneDriveCopyToUserStatus -Times 1 -Exactly -ParameterFilter { $OperationId -eq $script:OpId }
            Should -Invoke Remove-CIPPLicense -Times 1 -Exactly -ParameterFilter { $Schedule -and $userid -eq $script:UserId }
            Should -Invoke Get-CIPPAzDataTableEntity -ParameterFilter { $Filter -eq "PartitionKey eq 'contoso.com' and Kind eq 'Operation' and LeaverId eq '$($script:UserId)'" }
        }

        It 'defers licence removal to a recurring check while the copy is <_>' -ForEach @('Queued', 'InProgress') {
            $script:State = $_
            Mock Update-CIPPOneDriveCopyToUserStatus { New-Status $script:State }
            $Result = Remove-CIPPLicenseAfterOneDriveCopy @script:Base -CopyStartedAfter ($script:Now - 10)
            $Result | Should -BeLike '*Licence removal for pat@contoso.com is deferred*'
            Should -Invoke Remove-CIPPLicense -Times 0 -Exactly
            Should -Invoke Add-CIPPScheduledTask -Times 1 -Exactly -ParameterFilter {
                $Task.Command.value -eq 'Remove-CIPPLicenseAfterOneDriveCopy' -and $Task.Parameters.OperationId -eq $script:OpId -and
                $Task.Recurrence -eq '30m' -and $Task.Parameters.Deadline -gt $script:Now -and $Task.TenantFilter -eq 'contoso.com'
            }
        }

        It 'keeps the licences and fails the step when <Case>' -ForEach @(
            @{ Case = 'the copy failed'; Setup = { Mock Update-CIPPOneDriveCopyToUserStatus { New-Status 'Failed' } }; After = 0; Message = '*NOT removed*failed*' }
            @{ Case = 'this run started no copy (only an older one exists)'; Setup = {}; After = 'now'; Message = '*NOT removed*did not start a copy*' }
            @{ Case = 'there is no copy at all'; Setup = { $script:Rows = @() }; After = 0; Message = '*NOT removed*did not start a copy*' }
            @{ Case = 'the copy has gone from storage'; Setup = { Mock Update-CIPPOneDriveCopyToUserStatus { throw [System.Management.Automation.ItemNotFoundException]::new('gone') } }; After = 0; Message = '*NOT removed*could not be found*' }
        ) {
            . $Setup
            if ($After -eq 'now') { $script:Rows = @($script:Rows[0]); $After = $script:Now }
            { Remove-CIPPLicenseAfterOneDriveCopy @script:Base -CopyStartedAfter $After } | Should -Throw -ExpectedMessage $Message
            Should -Invoke Remove-CIPPLicense -Times 0 -Exactly
            Should -Invoke Add-CIPPScheduledTask -Times 0 -Exactly
            Should -Invoke Write-LogMessage -ParameterFilter { $sev -eq 'Error' }
        }

        It 'fails the step instead of claiming a deferral when the follow-up cannot be scheduled (<Case>)' -ForEach @(
            @{ Case = 'a check is already pending'; Reply = "Error - A scheduled task named 'Remove License after OneDrive copy: pat@contoso.com' already exists and was not created again." }
            @{ Case = 'storage error'; Reply = 'Error - Could not add task: table unavailable' }
        ) {
            $script:Reply = $Reply
            Mock Update-CIPPOneDriveCopyToUserStatus { New-Status 'InProgress' }
            Mock Add-CIPPScheduledTask { $script:Reply }
            { Remove-CIPPLicenseAfterOneDriveCopy @script:Base -CopyStartedAfter ($script:Now - 10) } | Should -Throw -ExpectedMessage '*NOT removed*could not be scheduled*'
            Should -Invoke Remove-CIPPLicense -Times 0 -Exactly
            Should -Invoke Write-LogMessage -ParameterFilter { $sev -eq 'Error' }
        }

        It 'does not treat the scheduler success message as an error' {
            Mock Update-CIPPOneDriveCopyToUserStatus { New-Status 'Queued' }
            Mock Add-CIPPScheduledTask { 'Successfully added task: Remove License after OneDrive copy: pat@contoso.com. It will run in 30 minutes.' }
            Remove-CIPPLicenseAfterOneDriveCopy @script:Base -CopyStartedAfter ($script:Now - 10) | Should -BeLike '*deferred*'
        }

        It 'never removes licences early: only a Completed copy reaches Remove-CIPPLicense (<_>)' -ForEach @('Queued', 'InProgress', 'Failed', 'Unknown', '') {
            $script:State = $_
            Mock Update-CIPPOneDriveCopyToUserStatus { New-Status $script:State }
            try { $null = Remove-CIPPLicenseAfterOneDriveCopy @script:Base -CopyStartedAfter ($script:Now - 10) } catch { }
            $script:CippScheduledTaskIdStorage = [pscustomobject]@{ Value = 'task-row-1' }
            $null = Remove-CIPPLicenseAfterOneDriveCopy @script:Base -OperationId $script:OpId -Deadline 0
            Should -Invoke Remove-CIPPLicense -Times 0 -Exactly
        }

        It 'keeps the licences when reading the copy status fails transiently' {
            Mock Update-CIPPOneDriveCopyToUserStatus { throw 'Storage 503' }
            { Remove-CIPPLicenseAfterOneDriveCopy @script:Base -CopyStartedAfter ($script:Now - 10) } | Should -Throw '*503*'
            Should -Invoke Remove-CIPPLicense -Times 0 -Exactly
        }

        It 'refuses a userid that is not an object id' {
            { Remove-CIPPLicenseAfterOneDriveCopy -TenantFilter 'contoso.com' -userid "x' or 1 eq 1" } | Should -Throw '*not a user object id*'
            Should -Invoke Get-CIPPAzDataTableEntity -Times 0 -Exactly
        }
    }

    Context 'scheduled check' {
        BeforeEach {
            $script:CippScheduledTaskIdStorage = [pscustomobject]@{ Value = 'task-row-1' }
            $script:Sched = $script:Base + @{ OperationId = $script:OpId; Deadline = $script:Now + 3600 }
        }

        It 'removes the licences directly and ends the recurrence once the copy completes' {
            $Result = Remove-CIPPLicenseAfterOneDriveCopy @script:Sched
            $Result | Should -BeLike '*completed. Removed licenses for pat@contoso.com.*'
            Should -Invoke Remove-CIPPLicense -Times 1 -Exactly -ParameterFilter { -not $Schedule }
            Should -Invoke Update-AzDataTableEntity -Times 1 -Exactly -ParameterFilter { $Entity.RowKey -eq 'task-row-1' -and $Entity.Recurrence -eq '0' }
            Should -Invoke Get-CIPPAzDataTableEntity -Times 0 -Exactly
        }

        It 'waits while the copy is in progress' {
            Mock Update-CIPPOneDriveCopyToUserStatus { New-Status 'InProgress' }
            Remove-CIPPLicenseAfterOneDriveCopy @script:Sched | Should -BeLike '*is InProgress*'
            Should -Invoke Remove-CIPPLicense -Times 0 -Exactly
            Should -Invoke Update-AzDataTableEntity -Times 0 -Exactly
            Should -Invoke Add-CIPPScheduledTask -Times 0 -Exactly
        }

        It 'keeps checking (does not end the recurrence) when the status read fails transiently' {
            Mock Update-CIPPOneDriveCopyToUserStatus { throw 'Storage 503' }
            { Remove-CIPPLicenseAfterOneDriveCopy @script:Sched } | Should -Throw '*503*'
            Should -Invoke Remove-CIPPLicense -Times 0 -Exactly
            Should -Invoke Update-AzDataTableEntity -Times 0 -Exactly
        }

        It 'never schedules another follow-up from inside the follow-up' {
            Mock Update-CIPPOneDriveCopyToUserStatus { New-Status 'Queued' }
            $null = Remove-CIPPLicenseAfterOneDriveCopy @script:Sched
            Should -Invoke Add-CIPPScheduledTask -Times 0 -Exactly
        }

        It 'ends the recurrence without removing licences when <Case>' -ForEach @(
            @{ Case = 'the copy failed'; Setup = { Mock Update-CIPPOneDriveCopyToUserStatus { New-Status 'Failed' } }; Deadline = 0 }
            @{ Case = 'the deadline has passed'; Setup = { Mock Update-CIPPOneDriveCopyToUserStatus { New-Status 'InProgress' } }; Deadline = 1 }
            @{ Case = 'the copy is gone'; Setup = { Mock Update-CIPPOneDriveCopyToUserStatus { throw [System.Management.Automation.ItemNotFoundException]::new('gone') } }; Deadline = 0 }
        ) {
            . $Setup
            $Params = $script:Sched.Clone()
            $Params.Deadline = $Deadline
            Remove-CIPPLicenseAfterOneDriveCopy @Params | Should -BeLike '*NOT removed*'
            Should -Invoke Remove-CIPPLicense -Times 0 -Exactly
            Should -Invoke Update-AzDataTableEntity -Times 1 -Exactly -ParameterFilter { $Entity.Recurrence -eq '0' }
            Should -Invoke Write-LogMessage -ParameterFilter { $sev -eq 'Error' }
        }
    }
}
