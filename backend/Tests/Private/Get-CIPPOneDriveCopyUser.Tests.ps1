# Pester tests for Get-CIPPOneDriveCopyUser: user + OneDrive resolution and its refusals

BeforeAll {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    $FunctionPath = Join-Path $RepoRoot 'Modules/CIPPCore/Public/Get-CIPPOneDriveCopyUser.ps1'
    if (-not (Test-Path $FunctionPath)) { throw "Could not locate $FunctionPath" }

    function New-GraphGetRequest { param($uri, $tenantid, $asapp) }

    . $FunctionPath

    $script:Licensed = @([pscustomobject]@{ service = 'SharePoint'; capabilityStatus = 'Enabled' })
    $script:Unlicensed = @([pscustomobject]@{ service = 'exchange'; capabilityStatus = 'Enabled' }, [pscustomobject]@{ service = 'SharePoint'; capabilityStatus = 'Deleted' })
}

Describe 'Get-CIPPOneDriveCopyUser' {
    BeforeEach {
        $script:Plans = $script:Licensed
        Mock New-GraphGetRequest {
            switch -Wildcard ($uri) {
                '*/users/*/drive?*' { [pscustomobject]@{ id = 'drive-bob'; webUrl = 'https://contoso-my.sharepoint.com/personal/bob_contoso_com/Documents'; driveType = 'business'; quota = [pscustomobject]@{ remaining = 1000; total = 5000 } }; break }
                '*/users/*' { [pscustomobject]@{ id = 'u-bob'; userPrincipalName = 'bob@contoso.com'; displayName = 'Bob'; assignedPlans = $script:Plans }; break }
                '*/root?*' { [pscustomobject]@{ id = 'root-bob'; sharepointIds = [pscustomobject]@{ siteUrl = 'https://contoso-my.sharepoint.com/personal/bob_contoso_com' } } }
            }
        }
    }

    It 'resolves the user, drive, site and quota' {
        $Result = Get-CIPPOneDriveCopyUser -TenantFilter 'contoso.com' -UserId 'bob@contoso.com'
        $Result.UserId | Should -Be 'u-bob'
        $Result.DriveId | Should -Be 'drive-bob'
        $Result.DriveHost | Should -Be 'contoso-my.sharepoint.com'
        $Result.SiteUrl | Should -Be 'https://contoso-my.sharepoint.com/personal/bob_contoso_com'
        $Result.QuotaRemaining | Should -Be 1000
        Should -Invoke New-GraphGetRequest -ParameterFilter { $uri -like '*/users/bob%40contoso.com?*' -and $tenantid -eq 'contoso.com' }
    }

    It 'falls back to the library parent when the root has no sharepointIds' {
        Mock New-GraphGetRequest { [pscustomobject]@{ id = 'root-bob' } } -ParameterFilter { $uri -like '*/root?*' }
        (Get-CIPPOneDriveCopyUser -TenantFilter 'contoso.com' -UserId 'bob@contoso.com').SiteUrl | Should -Be 'https://contoso-my.sharepoint.com/personal/bob_contoso_com'
    }

    It 'refuses <Case> with ArgumentException' -ForEach @(
        @{ Case = 'a malformed id'; Id = 'bob/../x'; Kind = 'Recipient'; Setup = {}; Message = "*is not a user principal name or object id*" }
        @{ Case = 'an unknown user'; Id = 'nobody@contoso.com'; Kind = 'Recipient'; Setup = { Mock New-GraphGetRequest { throw 'Request_ResourceNotFound: Resource does not exist' } -ParameterFilter { $uri -like '*/users/*' -and $uri -notlike '*/drive?*' } }; Message = '*was not found in tenant contoso.com*' }
        @{ Case = 'a recipient without a OneDrive licence'; Id = 'bob@contoso.com'; Kind = 'Recipient'; Setup = { $script:Plans = $script:Unlicensed }; Message = '*has no licence that includes OneDrive*' }
        @{ Case = 'a user without a OneDrive'; Id = 'bob@contoso.com'; Kind = 'Leaver'; Setup = { Mock New-GraphGetRequest { throw 'itemNotFound: mysite not found' } -ParameterFilter { $uri -like '*/drive?*' } }; Message = 'Leaver bob@contoso.com has no OneDrive*' }
    ) {
        . $Setup
        { Get-CIPPOneDriveCopyUser -TenantFilter 'contoso.com' -UserId $Id -Kind $Kind } | Should -Throw -ExceptionType ([System.ArgumentException]) -ExpectedMessage $Message
    }

    It 'does not require a licence for the leaver' {
        $script:Plans = $script:Unlicensed
        (Get-CIPPOneDriveCopyUser -TenantFilter 'contoso.com' -UserId 'bob@contoso.com' -Kind Leaver).HasOneDrivePlan | Should -BeFalse
    }

    It 'lets upstream failures through untyped' {
        Mock New-GraphGetRequest { throw 'Graph 503 Service Unavailable' } -ParameterFilter { $uri -like '*/drive?*' }
        $Thrown = { Get-CIPPOneDriveCopyUser -TenantFilter 'contoso.com' -UserId 'bob@contoso.com' } | Should -Throw -PassThru
        $Thrown.Exception | Should -Not -BeOfType ([System.ArgumentException])
    }
}
