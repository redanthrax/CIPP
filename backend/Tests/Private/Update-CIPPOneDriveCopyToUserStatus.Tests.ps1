# Pester tests for Update-CIPPOneDriveCopyToUserStatus: per-job polling, rate limit, rotation and state mapping.
# The table is faked in memory so successive status calls see what earlier ones stored.

BeforeAll {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    $FunctionPath = Join-Path $RepoRoot 'Modules/CIPPCore/Public/Update-CIPPOneDriveCopyToUserStatus.ps1'
    if (-not (Test-Path $FunctionPath)) { throw "Could not locate $FunctionPath" }

    function Get-CIPPTable { param($TableName) @{ TableName = $TableName } }
    function Get-CIPPAzDataTableEntity { param($Filter, $TableName) }
    function Add-CIPPAzDataTableEntity { param($Entity, [switch]$Force, $OperationType, $TableName) }
    function Get-CIPPSharePointLibraryCopyOperation { param($TenantFilter, $OperationId, $TableName) }
    function Get-CIPPSharePointCopyJobProgress { param($TenantFilter, $SourceSiteUrl, $CopyJobInfo) }
    function Update-CIPPSharePointLibraryCopyStatus { param($TenantFilter, $OperationId, $TableName) }

    . $FunctionPath

    $script:OpId = '11111111-2222-3333-4444-555555555555'
    function New-Recipient([int]$Index, [string]$Upn, [string]$StartError, [int]$JobCount = 3) {
        [pscustomobject]@{ Index = $Index; UserPrincipalName = $Upn; FolderName = 'jane@contoso.com'; SubOperationId = "$($script:OpId)-r$Index"; JobCount = $JobCount; StartError = $StartError }
    }
    function Set-Operation([object[]]$Recipients, [int]$RootItemCount = 3, [bool[]]$Empty = @()) {
        $script:Store = @{}
        $script:Store[$script:OpId] = [pscustomobject]@{
            PartitionKey = 'contoso.com'; RowKey = $script:OpId; Kind = 'Operation'; LeaverUPN = 'jane@contoso.com'
            StartedBy = 'admin@partner.com'; StartedUtc = '2026-11-13T00:00:00Z'; RootItemCount = $RootItemCount; ExpectedBytes = 1510
            RootItemEmpty = (ConvertTo-Json -InputObject @($Empty) -Compress)
            Recipients = (ConvertTo-Json -InputObject @($Recipients) -Compress -Depth 4)
        }
    }
    # Progress per job: "<recipient>-<job>" -> object or scriptblock; default = still running.
    function New-Progress([bool]$Complete, [int]$Objects = 1, [int]$Errors = 0, [string[]]$Messages = @()) {
        [pscustomobject]@{ IsComplete = $Complete; ObjectsProcessed = $Objects; TotalExpectedObjects = 2; FilesCreated = $Objects; BytesProcessed = $Objects * 10; TotalErrors = $Errors; TotalWarnings = 0; ErrorMessages = $Messages; WarningMessages = @() }
    }
    function Invoke-Status([int]$Interval = 0, [int]$Max = 100) {
        Update-CIPPOneDriveCopyToUserStatus -TenantFilter 'contoso.com' -OperationId $script:OpId -MinimumIntervalSeconds $Interval -MaxJobsPerCheck $Max
    }
}

Describe 'Update-CIPPOneDriveCopyToUserStatus' {
    BeforeEach {
        Set-Operation @((New-Recipient 0 'bob@contoso.com'))
        $script:Progress = @{}
        Mock Get-CIPPAzDataTableEntity {
            if ($Filter -match "RowKey eq '([^']+)'") { $script:Store[$Matches[1]] }
            elseif ($Filter -match "RowKey ge '([^']+)' and RowKey lt '([^']+)'") {
                $Low = $Matches[1]; $High = $Matches[2]
                $script:Store.Values | Where-Object { [string]::CompareOrdinal($_.RowKey, $Low) -ge 0 -and [string]::CompareOrdinal($_.RowKey, $High) -lt 0 }
            }
        }
        Mock Add-CIPPAzDataTableEntity {
            foreach ($Item in @($Entity)) {
                $Existing = $script:Store[$Item.RowKey]
                if ($OperationType -eq 'UpsertMerge' -and $Existing) {
                    foreach ($Key in $Item.Keys) { $Existing | Add-Member -NotePropertyName $Key -NotePropertyValue $Item[$Key] -Force }
                } else {
                    $script:Store[$Item.RowKey] = [pscustomobject]$Item
                }
            }
        }
        Mock Get-CIPPSharePointLibraryCopyOperation {
            $Index = [int]($OperationId -replace '.*-r', '')
            $Count = ($script:Store[$script:OpId].Recipients | ConvertFrom-Json | Where-Object Index -EQ $Index).JobCount
            [pscustomobject]@{ SourceSiteUrl = 'https://contoso-my.sharepoint.com/personal/jane'; CopyJobInfos = @(0..($Count - 1) | ForEach-Object { [pscustomobject]@{ JobId = "$Index-$_" } }) }
        }
        Mock Get-CIPPSharePointCopyJobProgress {
            $Value = $script:Progress[$CopyJobInfo.JobId]
            if ($Value -is [scriptblock]) { & $Value } elseif ($Value) { $Value } else { New-Progress $false 0 }
        }
        Mock Update-CIPPSharePointLibraryCopyStatus { throw 'the library copy status must not be used' }
    }

    It 'maps <Case> to <Expected>' -ForEach @(
        @{ Case = 'nothing processed yet'; Jobs = @{}; Expected = 'Queued'; Complete = $false }
        @{ Case = 'jobs running'; Jobs = @{ '0-0' = 'running' }; Expected = 'InProgress'; Complete = $false }
        @{ Case = 'a failed job while others still run'; Jobs = @{ '0-0' = 'errors' }; Expected = 'InProgress'; Complete = $false }
        @{ Case = 'every job done cleanly'; Jobs = @{ '0-0' = 'done'; '0-1' = 'done'; '0-2' = 'done' }; Expected = 'Completed'; Complete = $true }
        @{ Case = 'every job done, one with errors'; Jobs = @{ '0-0' = 'done'; '0-1' = 'errors'; '0-2' = 'done' }; Expected = 'Failed'; Complete = $true }
    ) {
        foreach ($Key in $Jobs.Keys) {
            $script:Progress[$Key] = switch ($Jobs[$Key]) {
                'running' { New-Progress $false 2 }
                'done' { New-Progress $true 2 }
                'errors' { New-Progress $true 1 1 @('File: access denied') }
            }
        }
        $Result = Invoke-Status
        $Result.Recipients[0].State | Should -Be $Expected
        $Result.Recipients[0].IsComplete | Should -Be $Complete
        $Result.State | Should -Be $Expected
        $Result.AllCompleted | Should -Be ($Expected -eq 'Completed')
        Should -Invoke Get-CIPPSharePointLibraryCopyOperation -ParameterFilter { $TableName -eq 'OneDriveCopyToUser' -and $OperationId -eq "$($script:OpId)-r0" }
    }

    It 'reports item count, bytes and errors per recipient' {
        $script:Progress['0-0'] = New-Progress $true 4
        $script:Progress['0-1'] = New-Progress $true 5 1 @('File: access denied')
        $script:Progress['0-2'] = New-Progress $true 1
        $Recipient = (Invoke-Status).Recipients[0]
        $Recipient.ItemsCopied | Should -Be 10
        $Recipient.BytesCopied | Should -Be 100
        $Recipient.ErrorCount | Should -Be 1
        $Recipient.Errors | Should -Be @('File: access denied')
        $Recipient.JobsComplete | Should -Be 3
    }

    It 'does not ask SharePoint again within the minimum interval, and returns the stored state' {
        $script:Progress['0-0'] = New-Progress $false 2
        $First = Invoke-Status -Interval 60
        $First.CheckedSharePoint | Should -BeTrue
        $First.JobsPolled | Should -Be 3
        Should -Invoke Get-CIPPSharePointCopyJobProgress -Times 3 -Exactly

        $Second = Invoke-Status -Interval 60
        $Second.CheckedSharePoint | Should -BeFalse
        $Second.JobsPolled | Should -Be 0
        $Second.Recipients[0].State | Should -Be 'InProgress'
        $Second.Recipients[0].ObjectsProcessed | Should -Be 2
        Should -Invoke Get-CIPPSharePointCopyJobProgress -Times 3 -Exactly
        Should -Invoke Get-CIPPSharePointLibraryCopyOperation -Times 1 -Exactly
    }

    It 'checks again once the interval has passed' {
        Invoke-Status -Interval 60 | Out-Null
        $script:Store[$script:OpId].LastCheckedUnix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 61
        (Invoke-Status -Interval 60).CheckedSharePoint | Should -BeTrue
        Should -Invoke Get-CIPPSharePointCopyJobProgress -Times 6 -Exactly
    }

    It 'polls at most MaxJobsPerCheck jobs per check, rotating so every job is reached, and is only Completed once all are confirmed' {
        Set-Operation @((New-Recipient 0 'bob@contoso.com' $null 5), (New-Recipient 1 'carol@contoso.com' $null 5)) -RootItemCount 5
        foreach ($r in 0..1) { foreach ($j in 0..4) { $script:Progress["$r-$j"] = New-Progress $true 1 } }

        $script:Seen = [System.Collections.Generic.List[string]]::new()
        Mock Get-CIPPSharePointCopyJobProgress { $script:Seen.Add($CopyJobInfo.JobId); $script:Progress[$CopyJobInfo.JobId] }

        $First = Invoke-Status -Max 4
        $First.JobsPolled | Should -Be 4
        $First.State | Should -Not -Be 'Completed'
        $First.AllCompleted | Should -BeFalse

        $Second = Invoke-Status -Max 4
        $Second.JobsPolled | Should -Be 4
        $Second.AllCompleted | Should -BeFalse

        $Third = Invoke-Status -Max 4
        $Third.JobsPolled | Should -Be 2
        $Third.State | Should -Be 'Completed'
        @($script:Seen | Sort-Object -Unique).Count | Should -Be 10
        $script:Seen.Count | Should -Be 10 -Because 'a finished job is never polled again'
    }

    It 'polls the least recently polled unfinished jobs first' {
        $script:Seen = [System.Collections.Generic.List[string]]::new()
        Mock Get-CIPPSharePointCopyJobProgress { $script:Seen.Add($CopyJobInfo.JobId); New-Progress $false 1 }
        Invoke-Status -Max 2 | Out-Null
        $script:Store["$($script:OpId)-js-0-0000"].LastPolledUnix = 1
        $script:Store["$($script:OpId)-js-0-0001"].LastPolledUnix = 5
        Invoke-Status -Max 2 | Out-Null
        $script:Seen | Should -Be @('0-0', '0-1', '0-2', '0-0')
    }

    It 'keeps a job unfinished through transient progress failures and fails it after five in a row' {
        Mock Get-CIPPSharePointCopyJobProgress { throw 'GetCopyJobProgress 503 https://contoso-my.sharepoint.com/x' }
        foreach ($i in 1..4) { (Invoke-Status).Recipients[0].IsComplete | Should -BeFalse }
        $Result = Invoke-Status
        $Result.Recipients[0].State | Should -Be 'Failed'
        $Result.Recipients[0].Errors[0] | Should -BeLike 'Progress could not be read 5 times in a row*'
        $Result.Recipients[0].Errors[0] | Should -Not -BeLike '*https://*'
    }

    It 'fails a job whose copy handle is missing' {
        Mock Get-CIPPSharePointLibraryCopyOperation { [pscustomobject]@{ SourceSiteUrl = 'https://contoso-my.sharepoint.com/personal/jane'; CopyJobInfos = @([pscustomobject]@{ JobId = '0-0' }) } }
        $script:Progress['0-0'] = New-Progress $true 1
        $Result = Invoke-Status
        $Result.Recipients[0].State | Should -Be 'Failed'
        $Result.Recipients[0].Errors | Should -Contain 'SharePoint returned no copy job for this item.'
    }

    It 'aggregates <Case> to <Expected>' -ForEach @(
        @{ Case = 'one completed, one never started'; Jobs = @{ 0 = 'done' }; StartErrors = @{ 1 = 'Copy failed to start: x' }; Expected = 'Failed'; IsComplete = $true }
        @{ Case = 'one never started, one still running'; Jobs = @{ 0 = 'running' }; StartErrors = @{ 1 = 'Copy failed to start: x' }; Expected = 'InProgress'; IsComplete = $false }
        @{ Case = 'one failed with errors, one still queued'; Jobs = @{ 0 = 'errors' }; StartErrors = @{}; Expected = 'InProgress'; IsComplete = $false }
        @{ Case = 'all queued'; Jobs = @{}; StartErrors = @{}; Expected = 'Queued'; IsComplete = $false }
        @{ Case = 'one queued, one completed'; Jobs = @{ 1 = 'done' }; StartErrors = @{}; Expected = 'InProgress'; IsComplete = $false }
    ) {
        Set-Operation @((New-Recipient 0 'bob@contoso.com' $StartErrors[0]), (New-Recipient 1 'carol@contoso.com' $StartErrors[1]))
        foreach ($r in $Jobs.Keys) {
            foreach ($j in 0..2) {
                $script:Progress["$r-$j"] = switch ($Jobs[$r]) {
                    'done' { New-Progress $true 2 }
                    'running' { New-Progress $false 2 }
                    'errors' { New-Progress $true 1 1 @('x') }
                }
            }
        }
        $Result = Invoke-Status
        $Result.State | Should -Be $Expected
        $Result.IsComplete | Should -Be $IsComplete
        $Result.AllCompleted | Should -BeFalse
        @($Result.Recipients).Count | Should -Be 2
    }

    It 'reports a recipient that never started as Failed without polling it' {
        Set-Operation @((New-Recipient 0 'bob@contoso.com' 'Copy failed to start: Access denied'))
        $Result = Invoke-Status
        $Result.Recipients[0].State | Should -Be 'Failed'
        $Result.Recipients[0].Message | Should -Be 'Copy failed to start: Access denied'
        $Result.State | Should -Be 'Failed'
        Should -Invoke Get-CIPPSharePointCopyJobProgress -Times 0 -Exactly
    }

    It 'is never Completed for an operation with no recipient records' {
        $script:Store[$script:OpId].Recipients = $null
        $Result = Invoke-Status
        $Result.AllCompleted | Should -BeFalse
        $Result.State | Should -Not -Be 'Completed'
    }

    It 'lets a missing per-recipient record surface as not found (so the licence gate keeps the licences)' {
        Mock Get-CIPPSharePointLibraryCopyOperation { $null }
        { Invoke-Status } | Should -Throw -ExceptionType ([System.Management.Automation.ItemNotFoundException])
    }

    It 'refuses a row in the table that is not an operation' {
        $script:Store[$script:OpId].Kind = $null
        { Invoke-Status } | Should -Throw -ExceptionType ([System.Management.Automation.ItemNotFoundException])
    }

    It 'only reads the operation in the requested tenant' {
        Update-CIPPOneDriveCopyToUserStatus -TenantFilter "o'brien.com" -OperationId $script:OpId -ErrorAction SilentlyContinue 2>$null | Out-Null
        Should -Invoke Get-CIPPAzDataTableEntity -ParameterFilter { $Filter -eq "PartitionKey eq 'o''brien.com' and RowKey eq '$($script:OpId)'" }
    }

    It 'throws ItemNotFoundException for an unknown operation' {
        $script:Store = @{}
        { Invoke-Status } | Should -Throw -ExceptionType ([System.Management.Automation.ItemNotFoundException])
    }

    It 'throws ArgumentException for a malformed OperationId without querying storage' {
        { Update-CIPPOneDriveCopyToUserStatus -TenantFilter 'contoso.com' -OperationId "x' or PartitionKey ne '" } | Should -Throw -ExceptionType ([System.ArgumentException])
        Should -Invoke Get-CIPPAzDataTableEntity -Times 0 -Exactly
    }

    It 'defaults to a 60 second interval and 100 jobs per check' {
        $Command = Get-Command Update-CIPPOneDriveCopyToUserStatus
        $Command.Parameters.Keys | Should -Contain 'MinimumIntervalSeconds'
        (Invoke-Status -Interval 60).CheckedSharePoint | Should -BeTrue
        (Update-CIPPOneDriveCopyToUserStatus -TenantFilter 'contoso.com' -OperationId $script:OpId).CheckedSharePoint | Should -BeFalse
    }
    Context 'licence gate safety (tester)' {
        BeforeEach {
            # Moves every stored timestamp back, as if this many seconds had passed before the next check.
            function Step-Clock([int]$Seconds = 60) {
                foreach ($Row in @($script:Store.Values)) {
                    if ($null -ne $Row.LastPolledUnix) { $Row.LastPolledUnix = [int64]$Row.LastPolledUnix - $Seconds }
                    if ($null -ne $Row.LastCheckedUnix) { $Row.LastCheckedUnix = [int64]$Row.LastCheckedUnix - $Seconds }
                }
            }
        }

        # LRU with ties broken by index is not perfectly even, but no unfinished job ever waits more
        # than ceil(unfinished / MaxJobsPerCheck) checks between two polls.
        It 'reaches every unfinished job within ceil(unfinished/cap) checks when none ever finishes (no starvation)' {
            Set-Operation @((New-Recipient 0 'bob@contoso.com' $null 7), (New-Recipient 1 'carol@contoso.com' $null 7)) -RootItemCount 7
            $script:Polls = [System.Collections.Generic.List[object]]::new()
            $script:Check = 0
            Mock Get-CIPPSharePointCopyJobProgress { $script:Polls.Add([pscustomobject]@{ Job = $CopyJobInfo.JobId; Check = $script:Check }); New-Progress $false 1 }

            foreach ($Check in 1..30) {
                $script:Check = $Check
                $Result = Invoke-Status -Interval 60 -Max 3
                $Result.CheckedSharePoint | Should -BeTrue
                $Result.JobsPolled | Should -Be 3
                $Result.AllCompleted | Should -BeFalse
                Step-Clock
            }
            $Jobs = @($script:Polls | Group-Object Job)
            $Jobs.Count | Should -Be 14
            foreach ($Job in $Jobs) {
                $Checks = @(0) + @($Job.Group.Check) + @(31)
                for ($i = 1; $i -lt $Checks.Count; $i++) {
                    ($Checks[$i] - $Checks[$i - 1]) | Should -BeLessOrEqual 5 -Because "job $($Job.Name) must be polled at least every ceil(14/3) checks"
                }
            }
        }

        It 'keeps rotating to the remaining jobs as others finish' {
            Set-Operation @((New-Recipient 0 'bob@contoso.com' $null 6)) -RootItemCount 6
            $script:Polls = [System.Collections.Generic.List[object]]::new()
            $script:Check = 0
            # Even jobs finish on their first poll, odd jobs never do.
            Mock Get-CIPPSharePointCopyJobProgress {
                $script:Polls.Add([pscustomobject]@{ Job = $CopyJobInfo.JobId; Check = $script:Check })
                New-Progress ([int]($CopyJobInfo.JobId -split '-')[1] % 2 -eq 0) 1
            }
            foreach ($Check in 1..12) { $script:Check = $Check; $Result = Invoke-Status -Interval 60 -Max 2; Step-Clock }
            foreach ($Even in '0-0', '0-2', '0-4') { @($script:Polls | Where-Object Job -EQ $Even).Count | Should -Be 1 }
            foreach ($Odd in '0-1', '0-3', '0-5') {
                $Checks = @($script:Polls | Where-Object Job -EQ $Odd | ForEach-Object Check)
                # after the first pass (3 checks), each of the 3 unfinished jobs is polled at least every ceil(3/2) = 2 checks
                @($Checks | Where-Object { $_ -gt 3 }).Count | Should -BeGreaterOrEqual 4
            }
            $Result.AllCompleted | Should -BeFalse
        }

        It 'returns the stored (unfinished) state inside the rate window even if SharePoint has since finished' {
            $script:Progress['0-0'] = New-Progress $false 1
            Invoke-Status -Interval 60 | Out-Null
            foreach ($j in 0..2) { $script:Progress["0-$j"] = New-Progress $true 1 }
            $Result = Invoke-Status -Interval 60
            $Result.CheckedSharePoint | Should -BeFalse
            $Result.AllCompleted | Should -BeFalse
        }

        It 'is never Completed while one job keeps failing to report, and fails it after five checks' {
            foreach ($j in 0..1) { $script:Progress["0-$j"] = New-Progress $true 1 }
            $script:Progress['0-2'] = { throw 'GetCopyJobProgress 429' }
            foreach ($Check in 1..4) {
                $Result = Invoke-Status
                $Result.AllCompleted | Should -BeFalse
                $Result.IsComplete | Should -BeFalse
            }
            $Result = Invoke-Status
            $Result.State | Should -Be 'Failed'
            $Result.AllCompleted | Should -BeFalse
        }

        It 'only gives up on five failures in a row, not five in total' {
            $script:Progress['0-0'] = { throw 'GetCopyJobProgress 503' }
            foreach ($Check in 1..4) { Invoke-Status | Out-Null }
            $script:Progress['0-0'] = New-Progress $false 1
            Invoke-Status | Out-Null
            $script:Progress['0-0'] = { throw 'GetCopyJobProgress 503' }
            foreach ($Check in 1..4) { (Invoke-Status).Recipients[0].IsComplete | Should -BeFalse }
        }

        It 'never completes a recipient from stored rows of another operation' {
            $Other = '99999999-2222-3333-4444-555555555555'
            foreach ($j in 0..2) {
                $script:Store["$Other-js-0-000$j"] = [pscustomobject]@{ RowKey = "$Other-js-0-000$j"; RecipientIndex = 0; JobIndex = $j; IsFinal = $true; Failed = $false; ObjectsProcessed = 1 }
            }
            (Invoke-Status -Interval 60).AllCompleted | Should -BeFalse
            # and inside the rate window, with nothing polled, still not complete
            (Invoke-Status -Interval 60).AllCompleted | Should -BeFalse
        }
    }

    Context 'strict completion (OneDrive copy only)' {
        It 'fails a recipient whose job count does not match the root items, without polling it' {
            Set-Operation @((New-Recipient 0 'bob@contoso.com' $null 2)) -RootItemCount 3
            $Result = Invoke-Status
            $Result.Recipients[0].State | Should -Be 'Failed'
            $Result.Recipients[0].Message | Should -BeLike '*2 copy job(s) for 3 root item(s)*'
            $Result.AllCompleted | Should -BeFalse
            Should -Invoke Get-CIPPSharePointCopyJobProgress -Times 0 -Exactly
        }

        It 'keeps the highest error count and every error message across checks' {
            $script:Progress['0-0'] = New-Progress $false 1 2 @('File: locked')
            Invoke-Status | Out-Null
            $script:Progress['0-0'] = New-Progress $false 2 0 @('File: too long')
            Invoke-Status | Out-Null
            $script:Progress['0-0'] = New-Progress $true 3 1 @()
            $script:Progress['0-1'] = New-Progress $true 1
            $script:Progress['0-2'] = New-Progress $true 1
            $Recipient = (Invoke-Status).Recipients[0]
            $Recipient.State | Should -Be 'Failed'
            $Recipient.ErrorCount | Should -Be 2
            $Recipient.Errors | Should -Be @('File: locked', 'File: too long')
        }

        It 'fails a job that finishes with nothing processed when its item was not empty' {
            $script:Progress['0-0'] = New-Progress $true 0
            $script:Progress['0-1'] = New-Progress $true 1
            $script:Progress['0-2'] = New-Progress $true 1
            $Recipient = (Invoke-Status).Recipients[0]
            $Recipient.State | Should -Be 'Failed'
            $Recipient.Errors | Should -Contain 'The copy job finished without copying anything.'
        }

        It 'accepts a job with nothing processed when its item was <Case> at start' -ForEach @(
            @{ Case = 'an empty folder or a 0-byte file'; Empty = @($true, $false, $false); Expected = 'Completed' }
            @{ Case = 'not recorded'; Empty = @(); Expected = 'Failed' }
        ) {
            Set-Operation @((New-Recipient 0 'bob@contoso.com')) -Empty $Empty
            $script:Progress['0-0'] = New-Progress $true 0
            $script:Progress['0-1'] = New-Progress $true 1
            $script:Progress['0-2'] = New-Progress $true 1
            (Invoke-Status).Recipients[0].State | Should -Be $Expected
        }

        It 'does not let a later reading lower the counts' {
            $script:Progress['0-0'] = New-Progress $false 5
            Invoke-Status | Out-Null
            $script:Progress['0-0'] = New-Progress $false 2
            (Invoke-Status).Recipients[0].ItemsCopied | Should -Be 5
        }
    }
}
