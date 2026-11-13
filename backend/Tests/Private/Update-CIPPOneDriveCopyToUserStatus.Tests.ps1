# Pester tests for Update-CIPPOneDriveCopyToUserStatus: per-recipient and overall state mapping

BeforeAll {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    $FunctionPath = Join-Path $RepoRoot 'Modules/CIPPCore/Public/Update-CIPPOneDriveCopyToUserStatus.ps1'
    if (-not (Test-Path $FunctionPath)) { throw "Could not locate $FunctionPath" }

    function Get-CIPPTable { param($TableName) @{ TableName = $TableName } }
    function Get-CIPPAzDataTableEntity { param($Filter, $TableName) }
    function Update-CIPPSharePointLibraryCopyStatus { param($TenantFilter, $OperationId, $TableName) }

    . $FunctionPath

    $script:OpId = '11111111-2222-3333-4444-555555555555'
    function New-OperationRow([object[]]$Recipients) {
        [pscustomobject]@{
            PartitionKey  = 'contoso.com'
            RowKey        = $script:OpId
            Kind          = 'Operation'
            LeaverUPN     = 'jane@contoso.com'
            StartedBy     = 'admin@partner.com'
            StartedUtc    = '2026-11-13T00:00:00Z'
            RootItemCount = 3
            ExpectedBytes = 1510
            Recipients    = (ConvertTo-Json -InputObject @($Recipients) -Compress -Depth 4)
        }
    }
    function New-Recipient([int]$Index, [string]$Upn, [string]$StartError) {
        [pscustomobject]@{ Index = $Index; UserPrincipalName = $Upn; FolderName = 'jane@contoso.com'; SubOperationId = "$($script:OpId)-r$Index"; JobCount = 3; StartError = $StartError }
    }
    function New-Snapshot([string]$Status, [int]$Done, [int]$Objects = 0, [int]$Errors = 0) {
        [pscustomobject]@{
            Status = $Status; JobsComplete = $Done; JobsTotal = 3; ObjectsProcessed = $Objects; TotalExpectedObjects = 10
            FilesCreated = $Objects; BytesProcessed = $Objects * 100; TotalErrors = $Errors
            Errors = @(if ($Errors) { [pscustomobject]@{ Severity = 'Error'; Message = 'File: access denied' } }); Warnings = @()
        }
    }
}

Describe 'Update-CIPPOneDriveCopyToUserStatus' {
    BeforeEach {
        $script:Row = New-OperationRow @((New-Recipient 0 'bob@contoso.com'))
        Mock Get-CIPPAzDataTableEntity { $script:Row }
        $script:Snapshots = @{ 0 = (New-Snapshot 'Processing' 0) }
        Mock Update-CIPPSharePointLibraryCopyStatus { $script:Snapshots[[int]($OperationId -replace '.*-r', '')] }
    }

    It 'maps <Case> to <Expected>' -ForEach @(
        @{ Case = 'nothing processed yet'; Snapshot = { New-Snapshot 'Processing' 0 }; Expected = 'Queued'; Complete = $false }
        @{ Case = 'jobs running'; Snapshot = { New-Snapshot 'Processing' 1 4 }; Expected = 'InProgress'; Complete = $false }
        @{ Case = 'a failed job while others still run'; Snapshot = { New-Snapshot 'Failed' 1 4 1 }; Expected = 'InProgress'; Complete = $false }
        @{ Case = 'every job done cleanly'; Snapshot = { New-Snapshot 'Completed' 3 10 }; Expected = 'Completed'; Complete = $true }
        @{ Case = 'every job done with errors'; Snapshot = { New-Snapshot 'CompletedWithErrors' 3 9 1 }; Expected = 'Failed'; Complete = $true }
    ) {
        $script:Snapshots[0] = & $Snapshot
        $Result = Update-CIPPOneDriveCopyToUserStatus -TenantFilter 'contoso.com' -OperationId $script:OpId

        $Result.Recipients[0].State | Should -Be $Expected
        $Result.Recipients[0].IsComplete | Should -Be $Complete
        $Result.State | Should -Be $Expected
        $Result.AllCompleted | Should -Be ($Expected -eq 'Completed')
        Should -Invoke Update-CIPPSharePointLibraryCopyStatus -Times 1 -Exactly -ParameterFilter { $TableName -eq 'OneDriveCopyToUser' -and $OperationId -eq "$($script:OpId)-r0" }
    }

    It 'reports item count, bytes and errors per recipient' {
        $script:Snapshots[0] = New-Snapshot 'CompletedWithErrors' 3 9 1
        $Recipient = (Update-CIPPOneDriveCopyToUserStatus -TenantFilter 'contoso.com' -OperationId $script:OpId).Recipients[0]
        $Recipient.ItemsCopied | Should -Be 9
        $Recipient.BytesCopied | Should -Be 900
        $Recipient.ErrorCount | Should -Be 1
        $Recipient.Errors | Should -Be @('File: access denied')
    }

    It 'is Completed only when every recipient is, and Failed once all are final with a failure' {
        $script:Row = New-OperationRow @((New-Recipient 0 'bob@contoso.com'), (New-Recipient 1 'carol@contoso.com'))
        $script:Snapshots = @{ 0 = (New-Snapshot 'Completed' 3 10); 1 = (New-Snapshot 'Processing' 1 2) }
        (Update-CIPPOneDriveCopyToUserStatus -TenantFilter 'contoso.com' -OperationId $script:OpId).State | Should -Be 'InProgress'

        $script:Snapshots[1] = New-Snapshot 'Completed' 3 10
        (Update-CIPPOneDriveCopyToUserStatus -TenantFilter 'contoso.com' -OperationId $script:OpId).State | Should -Be 'Completed'

        $script:Snapshots[1] = New-Snapshot 'CompletedWithErrors' 3 8 2
        $Result = Update-CIPPOneDriveCopyToUserStatus -TenantFilter 'contoso.com' -OperationId $script:OpId
        $Result.State | Should -Be 'Failed'
        $Result.IsComplete | Should -BeTrue
        $Result.AllCompleted | Should -BeFalse
    }

    It 'reports a recipient that never started as Failed without polling it' {
        $script:Row = New-OperationRow @((New-Recipient 0 'bob@contoso.com' 'Copy failed to start: Access denied'))
        $Result = Update-CIPPOneDriveCopyToUserStatus -TenantFilter 'contoso.com' -OperationId $script:OpId
        $Result.Recipients[0].State | Should -Be 'Failed'
        $Result.Recipients[0].Message | Should -Be 'Copy failed to start: Access denied'
        $Result.State | Should -Be 'Failed'
        Should -Invoke Update-CIPPSharePointLibraryCopyStatus -Times 0 -Exactly
    }

    It 'only reads the operation in the requested tenant' {
        Update-CIPPOneDriveCopyToUserStatus -TenantFilter "o'brien.com" -OperationId $script:OpId | Out-Null
        Should -Invoke Get-CIPPAzDataTableEntity -ParameterFilter { $Filter -eq "PartitionKey eq 'o''brien.com' and RowKey eq '$($script:OpId)'" }
    }

    It 'throws ItemNotFoundException for an unknown operation' {
        Mock Get-CIPPAzDataTableEntity { $null }
        { Update-CIPPOneDriveCopyToUserStatus -TenantFilter 'contoso.com' -OperationId $script:OpId } | Should -Throw -ExceptionType ([System.Management.Automation.ItemNotFoundException])
    }

    It 'throws ArgumentException for a malformed OperationId without querying storage' {
        { Update-CIPPOneDriveCopyToUserStatus -TenantFilter 'contoso.com' -OperationId "x' or PartitionKey ne '" } | Should -Throw -ExceptionType ([System.ArgumentException])
        Should -Invoke Get-CIPPAzDataTableEntity -Times 0 -Exactly
    }
}
