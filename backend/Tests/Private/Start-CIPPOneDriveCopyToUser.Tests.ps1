# Pester tests for Start-CIPPOneDriveCopyToUser: preflight refusals, folder handling and job submission

BeforeAll {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    $FunctionPath = Join-Path $RepoRoot 'Modules/CIPPCore/Public/Start-CIPPOneDriveCopyToUser.ps1'
    if (-not (Test-Path $FunctionPath)) { throw "Could not locate $FunctionPath" }

    function Get-CIPPOneDriveCopyUser { param($TenantFilter, $UserId, $Kind) }
    function New-GraphGetRequest { param($uri, $tenantid, $asapp) }
    function New-GraphPOSTRequest { param($uri, $tenantid, $type, $body, $AsApp) }
    function Invoke-CIPPSharePointCreateCopyJobs { param($TenantFilter, $SourceSiteUrl, $ExportObjectUris, $DestinationUri, $NameConflictBehavior, $SameWebCopyMoveOptimization, $IgnoreVersionHistory) }
    function Set-CIPPSharePointLibraryCopyOperation { param($TenantFilter, $OperationId, $Entity, $TableName) }
    function Get-CIPPTable { param($TableName) @{ TableName = $TableName } }
    function Add-CIPPAzDataTableEntity { param($Entity, [switch]$Force, $TableName) }
    function Write-LogMessage { param($headers, $API, $tenant, $message, $sev, $LogData) }
    function Get-CippException { param($Exception) [pscustomobject]@{ NormalizedError = [string]$Exception.Exception.Message } }

    . $FunctionPath

    function New-TestUser([string]$Name, [int64]$Remaining = 10GB, [string]$DriveHost = 'contoso-my.sharepoint.com') {
        $Personal = "$($Name)_contoso_com"
        [pscustomobject]@{
            UserId            = "id-$Name"
            UserPrincipalName = "$Name@contoso.com"
            DriveId           = "drive-$Name"
            DriveWebUrl       = "https://$DriveHost/personal/$Personal/Documents"
            DriveHost         = $DriveHost
            SiteUrl           = "https://$DriveHost/personal/$Personal"
            QuotaRemaining    = $Remaining
        }
    }
    $script:Params = @{ TenantFilter = 'contoso.com'; Leaver = 'jane@contoso.com'; Recipients = @('bob@contoso.com'); StartedBy = 'admin@partner.com' }
}

Describe 'Start-CIPPOneDriveCopyToUser' {
    BeforeEach {
        $script:Users = @{
            'jane@contoso.com'  = New-TestUser 'jane'
            'bob@contoso.com'   = New-TestUser 'bob'
            'carol@contoso.com' = New-TestUser 'carol'
        }
        Mock Get-CIPPOneDriveCopyUser {
            $Found = $script:Users[$UserId]
            if (-not $Found) { throw [System.ArgumentException]::new("Recipient '$UserId' was not found in tenant contoso.com.") }
            $Found.PSObject.Copy()
        }
        $script:Children = @(
            [pscustomobject]@{ id = 'i1'; name = 'Projects'; size = 1000; folder = @{ childCount = 3 } }
            [pscustomobject]@{ id = 'i2'; name = 'Budget #1.xlsx'; size = 500; file = @{} }
            [pscustomobject]@{ id = 'i3'; name = 'Notebook'; size = 10; package = @{ type = 'oneNote' } }
            [pscustomobject]@{ id = 'i4'; name = 'odd'; size = 1 }
        )
        Mock New-GraphGetRequest { $script:Children } -ParameterFilter { $uri -like '*/root/children*' }
        Mock New-GraphGetRequest { [pscustomobject]@{ id = 'existing'; name = 'jane@contoso.com'; folder = @{ childCount = 1 } } } -ParameterFilter { $uri -like '*/root:/*' }
        Mock New-GraphPOSTRequest { [pscustomobject]@{ id = 'new-folder'; name = 'jane@contoso.com'; folder = @{} } }
        Mock Invoke-CIPPSharePointCreateCopyJobs {
            @($ExportObjectUris | ForEach-Object { [pscustomobject]@{ JobId = (New-Guid).Guid; JobQueueUri = 'https://q.queue.core.windows.net/x'; EncryptionKey = 'k' } })
        }
        Mock Set-CIPPSharePointLibraryCopyOperation {}
        Mock Add-CIPPAzDataTableEntity {}
        Mock Write-LogMessage {}
    }

    It 'creates the UPN folder and submits KeepBoth copy jobs for every root item into it' {
        $Result = Start-CIPPOneDriveCopyToUser @script:Params

        $Result.OperationId | Should -Match '^[0-9a-f-]{36}$'
        $Result.FolderName | Should -Be 'jane@contoso.com'
        $Result.RootItemCount | Should -Be 3
        $Result.ExpectedBytes | Should -Be 1510
        $Result.Recipients[0].State | Should -Be 'Queued'
        $Result.Recipients[0].FolderCreated | Should -BeTrue
        $Result.Recipients[0].JobCount | Should -Be 3

        Should -Invoke New-GraphPOSTRequest -Times 1 -Exactly -ParameterFilter {
            $Body = $body | ConvertFrom-Json
            $uri -eq 'https://graph.microsoft.com/v1.0/drives/drive-bob/root/children' -and $Body.name -eq 'jane@contoso.com' -and $Body.'@microsoft.graph.conflictBehavior' -eq 'fail'
        }
        Should -Invoke Invoke-CIPPSharePointCreateCopyJobs -Times 1 -Exactly -ParameterFilter {
            $SourceSiteUrl -eq 'https://contoso-my.sharepoint.com/personal/jane_contoso_com' -and
            $DestinationUri -eq 'https://contoso-my.sharepoint.com/personal/bob_contoso_com/Documents/jane%40contoso.com' -and
            $NameConflictBehavior -eq 2 -and $IgnoreVersionHistory -eq $true -and
            @($ExportObjectUris).Count -eq 3 -and
            $ExportObjectUris[1] -eq 'https://contoso-my.sharepoint.com/personal/jane_contoso_com/Documents/Budget%20%231.xlsx'
        }
        Should -Invoke Set-CIPPSharePointLibraryCopyOperation -Times 1 -Exactly -ParameterFilter {
            $TableName -eq 'OneDriveCopyToUser' -and $OperationId -like '*-r0' -and $Entity.JobHandleCount -eq 3 -and $Entity.StartedBy -eq 'admin@partner.com'
        }
        Should -Invoke Add-CIPPAzDataTableEntity -Times 1 -Exactly -ParameterFilter {
            $Entity.Kind -eq 'Operation' -and $Entity.PartitionKey -eq 'contoso.com' -and $Entity.LeaverUPN -eq 'jane@contoso.com' -and $Entity.StartedBy -eq 'admin@partner.com'
        }
        Should -Invoke Write-LogMessage -Times 1 -Exactly -ParameterFilter { $sev -eq 'Info' -and $message -like '*started by admin@partner.com*' -and $tenant -eq 'contoso.com' }
    }

    It 'reuses an existing UPN folder' {
        Mock New-GraphPOSTRequest { throw 'nameAlreadyExists: Name already exists' }
        $Result = Start-CIPPOneDriveCopyToUser @script:Params
        $Result.Recipients[0].FolderCreated | Should -BeFalse
        Should -Invoke Invoke-CIPPSharePointCreateCopyJobs -Times 1 -Exactly
    }

    It 'copies version history only when asked' {
        Start-CIPPOneDriveCopyToUser @script:Params -IncludeVersionHistory $true | Out-Null
        Should -Invoke Invoke-CIPPSharePointCreateCopyJobs -ParameterFilter { $IgnoreVersionHistory -eq $false }
    }

    It 'submits jobs in batches of 100 root items' {
        $script:Children = @(1..250 | ForEach-Object { [pscustomobject]@{ id = "i$_"; name = "f$_.txt"; size = 1; file = @{} } })
        $Result = Start-CIPPOneDriveCopyToUser @script:Params
        Should -Invoke Invoke-CIPPSharePointCreateCopyJobs -Times 3 -Exactly
        $Result.Recipients[0].JobCount | Should -Be 250
    }

    It 'starts one copy per recipient and de-duplicates recipients' {
        $Params = $script:Params.Clone()
        $Params.Recipients = @('bob@contoso.com', 'carol@contoso.com', 'BOB@contoso.com ')
        $script:Users['BOB@contoso.com'] = $script:Users['bob@contoso.com']
        $Result = Start-CIPPOneDriveCopyToUser @Params
        @($Result.Recipients).Count | Should -Be 2
        Should -Invoke Invoke-CIPPSharePointCreateCopyJobs -Times 2 -Exactly
    }

    It 'refuses <Case> before writing anything' -ForEach @(
        @{ Case = 'a recipient without enough space'; Setup = { $script:Users['bob@contoso.com'] = New-TestUser 'bob' -Remaining 100 }; Recipients = @('bob@contoso.com'); Message = '*bob@contoso.com does not have enough space*' }
        @{ Case = 'a recipient in another tenant'; Setup = { $script:Users['bob@contoso.com'] = New-TestUser 'bob' -DriveHost 'fabrikam-my.sharepoint.com' }; Recipients = @('bob@contoso.com'); Message = '*not in the same tenant*' }
        @{ Case = 'the leaver as recipient'; Setup = {}; Recipients = @('jane@contoso.com'); Message = '*is the leaver*' }
        @{ Case = 'an unknown recipient among good ones'; Setup = {}; Recipients = @('bob@contoso.com', 'ghost@contoso.com'); Message = "*'ghost@contoso.com' was not found*" }
        @{ Case = 'an empty leaver OneDrive'; Setup = { $script:Children = @() }; Recipients = @('bob@contoso.com'); Message = '*has nothing to copy*' }
        @{ Case = 'more than 1,000 root items'; Setup = { $script:Children = @(1..1001 | ForEach-Object { [pscustomobject]@{ name = "f$_"; size = 1; file = @{} } }) }; Recipients = @('bob@contoso.com'); Message = '*1001 items at its root*' }
        @{ Case = 'no recipients'; Setup = {}; Recipients = @(' '); Message = 'At least one recipient is required.' }
        @{ Case = 'too many recipients'; Setup = {}; Recipients = @(1..11 | ForEach-Object { "u$_@contoso.com" }); Message = 'At most 10 recipients*' }
    ) {
        . $Setup
        $Params = $script:Params.Clone()
        $Params.Recipients = $Recipients
        { Start-CIPPOneDriveCopyToUser @Params } | Should -Throw -ExceptionType ([System.ArgumentException]) -ExpectedMessage $Message
        Should -Invoke New-GraphPOSTRequest -Times 0 -Exactly
        Should -Invoke Invoke-CIPPSharePointCreateCopyJobs -Times 0 -Exactly
        Should -Invoke Add-CIPPAzDataTableEntity -Times 0 -Exactly
    }

    It 'names the folder exactly after a <Case> leaver UPN and escapes it in every URI' -ForEach @(
        @{ Case = 'guest'; Upn = 'jo_fabrikam.com#EXT#@contoso.onmicrosoft.com'; Escaped = 'jo_fabrikam.com%23EXT%23%40contoso.onmicrosoft.com' }
        @{ Case = 'apostrophe and plus'; Upn = "o'brien+it@contoso.com"; Escaped = 'o%27brien%2Bit%40contoso.com' }
        @{ Case = 'unicode'; Upn = 'zoë@contoso.com'; Escaped = 'zo%C3%AB%40contoso.com' }
    ) {
        $Leaver = New-TestUser 'jane'
        $Leaver.UserPrincipalName = $Upn
        $script:Users[$Upn] = $Leaver
        $Params = $script:Params.Clone()
        $Params.Leaver = $Upn
        $script:Upn = $Upn
        $script:Escaped = $Escaped
        Mock New-GraphPOSTRequest { throw 'nameAlreadyExists: Name already exists' }
        Mock New-GraphGetRequest { [pscustomobject]@{ id = 'existing'; name = $script:Upn; folder = @{} } } -ParameterFilter { $uri -like '*/root:/*' }

        $Result = Start-CIPPOneDriveCopyToUser @Params

        $Result.FolderName | Should -BeExactly $Upn
        Should -Invoke New-GraphPOSTRequest -Times 1 -Exactly -ParameterFilter { ($body | ConvertFrom-Json).name -ceq $script:Upn }
        Should -Invoke New-GraphGetRequest -Times 1 -Exactly -ParameterFilter { $uri -like "https://graph.microsoft.com/v1.0/drives/drive-bob/root:/$($script:Escaped)?*" }
        Should -Invoke Invoke-CIPPSharePointCreateCopyJobs -Times 1 -Exactly -ParameterFilter {
            $DestinationUri -ceq "https://contoso-my.sharepoint.com/personal/bob_contoso_com/Documents/$($script:Escaped)"
        }
    }

    It 'escapes root item names in the source URIs' {
        $script:Children = @([pscustomobject]@{ id = 'i1'; name = "Q1 #2 50% o'clock+ü.docx"; size = 1; file = @{} })
        Start-CIPPOneDriveCopyToUser @script:Params | Out-Null
        Should -Invoke Invoke-CIPPSharePointCreateCopyJobs -ParameterFilter {
            $ExportObjectUris[0] -ceq 'https://contoso-my.sharepoint.com/personal/jane_contoso_com/Documents/Q1%20%232%2050%25%20o%27clock%2B%C3%BC.docx'
        }
    }

    It 'refuses the leaver as a recipient when one is given by UPN and the other by object id' {
        $script:Users['id-jane'] = $script:Users['jane@contoso.com']
        $Params = $script:Params.Clone()
        $Params.Recipients = @('id-jane')
        { Start-CIPPOneDriveCopyToUser @Params } | Should -Throw -ExceptionType ([System.ArgumentException]) -ExpectedMessage '*is the leaver*'
        Should -Invoke New-GraphPOSTRequest -Times 0 -Exactly
    }

    It 'copies once to a recipient given both by UPN and by object id' {
        $script:Users['id-bob'] = $script:Users['bob@contoso.com']
        $Params = $script:Params.Clone()
        $Params.Recipients = @('bob@contoso.com', 'id-bob')
        $Result = Start-CIPPOneDriveCopyToUser @Params
        @($Result.Recipients).Count | Should -Be 1
        Should -Invoke New-GraphPOSTRequest -Times 1 -Exactly
    }

    It 'does not treat a non-conflict folder creation error as an existing folder' {
        Mock New-GraphPOSTRequest { throw 'accessDenied: Access denied' }
        { Start-CIPPOneDriveCopyToUser @script:Params } | Should -Throw '*Access denied*'
        Should -Invoke New-GraphGetRequest -Times 0 -Exactly -ParameterFilter { $uri -like '*/root:/*' }
        Should -Invoke Invoke-CIPPSharePointCreateCopyJobs -Times 0 -Exactly
    }

    It 'checks free space against the leaver total for every recipient' {
        $Params = $script:Params.Clone()
        $Params.Recipients = @('bob@contoso.com', 'carol@contoso.com')
        $script:Users['carol@contoso.com'] = New-TestUser 'carol' -Remaining 1509
        { Start-CIPPOneDriveCopyToUser @Params } | Should -Throw -ExceptionType ([System.ArgumentException]) -ExpectedMessage '*carol@contoso.com does not have enough space: the copy needs 1510 bytes and 1509 are free*'
        Should -Invoke New-GraphPOSTRequest -Times 0 -Exactly
    }

    It 'warns, but starts, when a recipient quota cannot be read' {
        $script:Users['bob@contoso.com'].QuotaRemaining = $null
        (Start-CIPPOneDriveCopyToUser @script:Params).Warnings | Should -BeLike '*could not be read*'
    }

    It 'refuses when the recipient has a file named like the folder' {
        Mock New-GraphPOSTRequest { throw 'nameAlreadyExists: Name already exists' }
        Mock New-GraphGetRequest { [pscustomobject]@{ id = 'a-file'; name = 'jane@contoso.com'; file = @{} } } -ParameterFilter { $uri -like '*/root:/*' }
        { Start-CIPPOneDriveCopyToUser @script:Params } | Should -Throw -ExceptionType ([System.ArgumentException]) -ExpectedMessage '*already has a file named jane@contoso.com*'
        Should -Invoke Invoke-CIPPSharePointCreateCopyJobs -Times 0 -Exactly
    }

    It 'warns about root items over the 100 GB per-job limit' {
        $script:Users['bob@contoso.com'] = New-TestUser 'bob' -Remaining 1TB
        $script:Children = @([pscustomobject]@{ name = 'Huge'; size = 101GB; folder = @{} })
        (Start-CIPPOneDriveCopyToUser @script:Params).Warnings | Should -BeLike '*larger than 100 GB*'
    }

    It 'reports a recipient whose jobs fail to start as Failed and keeps the others' {
        $Params = $script:Params.Clone()
        $Params.Recipients = @('bob@contoso.com', 'carol@contoso.com')
        Mock Invoke-CIPPSharePointCreateCopyJobs { throw 'Access denied https://contoso-my.sharepoint.com/personal/x' } -ParameterFilter { $DestinationUri -like '*bob_contoso_com*' }
        $Result = Start-CIPPOneDriveCopyToUser @Params
        ($Result.Recipients | Where-Object UserPrincipalName -EQ 'bob@contoso.com').State | Should -Be 'Failed'
        ($Result.Recipients | Where-Object UserPrincipalName -EQ 'bob@contoso.com').Message | Should -Not -BeLike '*https://*'
        ($Result.Recipients | Where-Object UserPrincipalName -EQ 'carol@contoso.com').State | Should -Be 'Queued'
        Should -Invoke Add-CIPPAzDataTableEntity -Times 1 -Exactly
    }

    It 'throws when no recipient could start' {
        Mock Invoke-CIPPSharePointCreateCopyJobs { throw 'SharePoint CreateCopyJobs returned no job handles.' }
        { Start-CIPPOneDriveCopyToUser @script:Params } | Should -Throw '*failed to start for every recipient*'
        Should -Invoke Add-CIPPAzDataTableEntity -Times 0 -Exactly
    }
}
