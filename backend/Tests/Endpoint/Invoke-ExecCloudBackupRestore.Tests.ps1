BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'Fixtures/CloudBackup/CloudBackupTestStubs.ps1')
    $script:RunId = '11111111-1111-1111-1111-111111111111_0000000000000000001_c1'

    function New-PrincipalHeader([string]$User) {
        $Json = @{ identityProvider = 'aad'; userDetails = $User; userRoles = @('admin') } | ConvertTo-Json -Compress
        [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Json))
    }
    function Invoke-Restore {
        param($Body, $User = 'tech@partner.com')
        $Request = New-CloudBackupRequest -Endpoint 'ExecCloudBackupRestore' -Body $Body
        $Request.Headers = @{ 'x-ms-client-principal' = (New-PrincipalHeader $User) }
        Invoke-ExecCloudBackupRestore -Request $Request
    }
    function Get-LastJob { $script:JobWrites[$script:JobWrites.Count - 1] }
    function Complete-Preview {
        $Preview = Get-LastJob
        $script:Jobs[$Preview.RowKey] = [pscustomobject]@{
            PartitionKey   = 'CloudBackupJob'
            RowKey         = $Preview.RowKey
            Type           = $Preview.Type
            Status         = 'Completed'
            RequestedBy    = $Preview.RequestedBy
            CreatedAt      = $Preview.CreatedAt
            ParametersHash = $Preview.ParametersHash
        }
        $Preview.RowKey
    }
}

Describe 'Invoke-ExecCloudBackupRestore' {
    BeforeEach {
        $script:Allowed = @('AllTenants')
        $script:Runs = @(New-CloudBackupRunRow)
        $script:Jobs = @{}
        $script:JobWrites = [System.Collections.Generic.List[object]]::new()
        $script:Started = [System.Collections.Generic.List[object]]::new()
        Mock Test-CIPPAccess { $script:Allowed }
        Mock Get-Tenants { $script:CloudBackupTenants }
        Mock Get-CIPPAzDataTableEntity { @($script:Runs).Where({ $Filter -eq "PartitionKey eq '$($_.PartitionKey)' and RowKey eq '$($_.RowKey)'" }) } -ParameterFilter { $TableName -eq 'CloudBackupRuns' }
        Mock Get-CIPPAzDataTableEntity {
            if ($Filter -match "RowKey eq '([^']+)'") { $script:Jobs[$Matches[1]] }
        } -ParameterFilter { $TableName -eq 'CloudBackupJobs' }
        Mock Add-CIPPAzDataTableEntity { if ($Entity -is [hashtable]) { $script:JobWrites.Add(@{} + $Entity) } else { $script:Jobs[$Entity.RowKey] = $Entity } } -ParameterFilter { $TableName -eq 'CloudBackupJobs' }
        Mock Start-CIPPOrchestrator { $script:Started.Add($InputObject); 'Craft-run' }
        Mock Write-LogMessage { }
    }

    It 'returns 400 for <Case>' -ForEach @(
        @{ Case = 'a bad RunId'; Body = @{ RunId = 'nope'; Mode = 'Preview' } }
        @{ Case = 'a bad Mode'; Body = @{ RunId = '11111111-1111-1111-1111-111111111111_0000000000000000001_c1'; Mode = 'Go' } }
        @{ Case = 'a bad ConflictAction'; Body = @{ RunId = '11111111-1111-1111-1111-111111111111_0000000000000000001_c1'; Mode = 'Preview'; ConflictAction = 'Merge' } }
        @{ Case = 'a bad CAState'; Body = @{ RunId = '11111111-1111-1111-1111-111111111111_0000000000000000001_c1'; Mode = 'Preview'; CAState = 'On' } }
        @{ Case = 'a bad area'; Body = @{ RunId = '11111111-1111-1111-1111-111111111111_0000000000000000001_c1'; Mode = 'Preview'; Areas = @('Teams') } }
        @{ Case = 'an item outside the areas'; Body = @{ RunId = '11111111-1111-1111-1111-111111111111_0000000000000000001_c1'; Mode = 'Preview'; Areas = @('Intune'); Items = @(@{ Area = 'ConditionalAccess'; Section = 'policies'; Key = 'p1' }) } }
        @{ Case = 'an item without a key'; Body = @{ RunId = '11111111-1111-1111-1111-111111111111_0000000000000000001_c1'; Mode = 'Preview'; Items = @(@{ Area = 'Intune'; Section = 'policies' }) } }
        @{ Case = 'AllTenants as target'; Body = @{ RunId = '11111111-1111-1111-1111-111111111111_0000000000000000001_c1'; Mode = 'Preview'; TargetTenant = 'AllTenants' } }
        @{ Case = 'Apply without a preview'; Body = @{ RunId = '11111111-1111-1111-1111-111111111111_0000000000000000001_c1'; Mode = 'Apply' } }
    ) {
        (Invoke-Restore -Body $Body).StatusCode | Should -Be 400
        Should -Invoke Start-CIPPOrchestrator -Times 0 -Exactly
    }

    It 'returns 404 for an unknown run or target tenant' {
        (Invoke-Restore -Body @{ RunId = '11111111-1111-1111-1111-111111111111_0000000000000000009_c1'; Mode = 'Preview' }).StatusCode | Should -Be 404
        (Invoke-Restore -Body @{ RunId = $script:RunId; Mode = 'Preview'; TargetTenant = 'unknown.com' }).StatusCode | Should -Be 404
    }

    It 'returns 400 for a failed backup run' {
        $script:Runs = @(New-CloudBackupRunRow -Status 'Failed')
        (Invoke-Restore -Body @{ RunId = $script:RunId; Mode = 'Preview' }).StatusCode | Should -Be 400
    }

    It 'returns 403 when the caller cannot access the source or the target tenant' {
        $script:Allowed = @('c2')
        (Invoke-Restore -Body @{ RunId = $script:RunId; Mode = 'Preview'; TargetTenant = 'fabrikam.com' }).StatusCode | Should -Be 403
        $script:Allowed = @('c1')
        (Invoke-Restore -Body @{ RunId = $script:RunId; Mode = 'Preview'; TargetTenant = 'fabrikam.com' }).StatusCode | Should -Be 403
        (Invoke-Restore -Body @{ RunId = $script:RunId; Mode = 'Preview' }).StatusCode | Should -Be 202
    }

    It 'queues a same-tenant preview with the run''s areas and same-tenant defaults' {
        $Response = Invoke-Restore -Body @{ RunId = $script:RunId; Mode = 'Preview' }

        $Response.StatusCode | Should -Be 202
        $Job = Get-LastJob
        $Response.Body.JobId | Should -Be $Job.RowKey
        $Job.PartitionKey | Should -Be 'CloudBackupJob'
        $Job.Type | Should -Be 'RestorePreview'
        $Job.Status | Should -Be 'Queued'
        $Job.SourceTenantId | Should -Be 'c1'
        $Job.TargetTenantId | Should -Be 'c1'
        $Job.TargetTenant | Should -Be 'contoso.com'
        $Job.RequestedBy | Should -Be 'tech@partner.com'
        $Job.ParametersHash | Should -Match '^[0-9a-f]{64}$'
        $Parameters = [CIPP.CippJson]::ConvertFromJson($Job.Parameters)
        @($Parameters.Areas) | Should -Be @('ConditionalAccess', 'Intune')
        $Parameters.ConflictAction | Should -Be 'Skip'
        $Parameters.CAState | Should -Be 'AsBackedUp'
        $script:Started[0].Batch[0].FunctionName | Should -Be 'CloudBackupJob'
        $script:Started[0].Batch[0].JobId | Should -Be $Job.RowKey
    }

    It 'defaults Conditional Access to report-only for another tenant and accepts a selector value' {
        Invoke-Restore -Body @{ RunId = $script:RunId; Mode = 'Preview'; TargetTenant = @{ value = 'fabrikam.com'; label = 'Fabrikam' } } | Out-Null

        $Job = Get-LastJob
        $Job.TargetTenantId | Should -Be 'c2'
        ([CIPP.CippJson]::ConvertFromJson($Job.Parameters)).CAState | Should -Be 'ReportOnly'
    }

    It 'takes the areas from the selected items when Areas is omitted' {
        Invoke-Restore -Body @{ RunId = $script:RunId; Mode = 'Preview'; Items = @(@{ Area = 'Intune'; Section = 'configurationPolicies'; Key = 'x' }) } | Out-Null

        @(([CIPP.CippJson]::ConvertFromJson((Get-LastJob).Parameters)).Areas) | Should -Be @('Intune')
    }

    It 'applies after a matching completed preview by the same user, whatever the item order' {
        $Items = @(@{ Area = 'Intune'; Section = 'b'; Key = '2' }, @{ Area = 'ConditionalAccess'; Section = 'policies'; Key = '1' })
        Invoke-Restore -Body @{ RunId = $script:RunId; Mode = 'Preview'; Items = $Items; ConflictAction = 'Overwrite' } | Out-Null
        $PreviewId = Complete-Preview

        $Response = Invoke-Restore -Body @{ RunId = $script:RunId; Mode = 'Apply'; Items = @($Items[1], $Items[0]); ConflictAction = 'Overwrite'; PreviewJobId = $PreviewId }

        $Response.StatusCode | Should -Be 202
        $Job = Get-LastJob
        $Job.Type | Should -Be 'Restore'
        $Job.PreviewJobId | Should -Be $PreviewId
        $Job.ParametersHash | Should -Be $script:Jobs[$PreviewId].ParametersHash
        Should -Invoke Start-CIPPOrchestrator -Times 2 -Exactly
    }

    It 'refuses Apply when <Case>' -ForEach @(
        @{ Case = 'the preview is by another user'; Change = { }; User = 'other@partner.com'; Body = @{} }
        @{ Case = 'the options differ'; Change = { }; User = 'tech@partner.com'; Body = @{ ConflictAction = 'Copy' } }
        @{ Case = 'the preview is older than 60 minutes'; Change = { param($P) $P.CreatedAt = [datetime]::UtcNow.AddMinutes(-61).ToString('o') }; User = 'tech@partner.com'; Body = @{} }
        @{ Case = 'the preview has not completed'; Change = { param($P) $P.Status = 'Running' }; User = 'tech@partner.com'; Body = @{} }
        @{ Case = 'the job is not a preview'; Change = { param($P) $P.Type = 'Compare' }; User = 'tech@partner.com'; Body = @{} }
    ) {
        Invoke-Restore -Body @{ RunId = $script:RunId; Mode = 'Preview' } | Out-Null
        $PreviewId = Complete-Preview
        & $Change $script:Jobs[$PreviewId]

        $ApplyBody = @{ RunId = $script:RunId; Mode = 'Apply'; PreviewJobId = $PreviewId } + $Body
        $Response = Invoke-Restore -Body $ApplyBody -User $User

        $Response.StatusCode | Should -Be 400
        $Response.Body.Results | Should -Match 'preview'
        Should -Invoke Start-CIPPOrchestrator -Times 1 -Exactly
    }

    It 'uses a preview for one restore only' {
        Invoke-Restore -Body @{ RunId = $script:RunId; Mode = 'Preview' } | Out-Null
        $PreviewId = Complete-Preview

        (Invoke-Restore -Body @{ RunId = $script:RunId; Mode = 'Apply'; PreviewJobId = $PreviewId }).StatusCode | Should -Be 202
        $script:Jobs[$PreviewId].AppliedJobId | Should -Be (Get-LastJob).RowKey

        $Again = Invoke-Restore -Body @{ RunId = $script:RunId; Mode = 'Apply'; PreviewJobId = $PreviewId }
        $Again.StatusCode | Should -Be 400
        $Again.Body.Results | Should -Match 'already used'
    }

    It 'frees the preview again when the restore cannot be queued' {
        Invoke-Restore -Body @{ RunId = $script:RunId; Mode = 'Preview' } | Out-Null
        $PreviewId = Complete-Preview
        Mock Start-CIPPOrchestrator { $null }

        (Invoke-Restore -Body @{ RunId = $script:RunId; Mode = 'Apply'; PreviewJobId = $PreviewId }).StatusCode | Should -Be 500
        $script:Jobs[$PreviewId].AppliedJobId | Should -BeNullOrEmpty
    }

    It 'refuses Apply for an unknown preview' {
        (Invoke-Restore -Body @{ RunId = $script:RunId; Mode = 'Apply'; PreviewJobId = ([guid]::NewGuid().ToString()) }).StatusCode | Should -Be 400
    }

    It 'marks the job failed and returns 500 when it cannot be queued' {
        Mock Start-CIPPOrchestrator { $null }

        $Response = Invoke-Restore -Body @{ RunId = $script:RunId; Mode = 'Preview' }

        $Response.StatusCode | Should -Be 500
        (Get-LastJob).Status | Should -Be 'Failed'
    }
}
