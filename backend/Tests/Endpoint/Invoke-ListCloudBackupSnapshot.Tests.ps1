BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'Fixtures/CloudBackup/CloudBackupTestStubs.ps1')
    $script:RunId = '11111111-1111-1111-1111-111111111111_0000000000000000001_c1'
    function Invoke-Snapshot { param($Query) Invoke-ListCloudBackupSnapshot -Request (New-CloudBackupRequest -Endpoint 'ListCloudBackupSnapshot' -Query $Query) }
}

Describe 'Invoke-ListCloudBackupSnapshot' {
    BeforeEach {
        $script:Allowed = @('AllTenants')
        $script:Runs = @(New-CloudBackupRunRow)
        Mock Test-CIPPAccess { $script:Allowed }
        Mock Get-CIPPAzDataTableEntity { @($script:Runs).Where({ $Filter -eq "PartitionKey eq '$($_.PartitionKey)' and RowKey eq '$($_.RowKey)'" }) } -ParameterFilter { $TableName -eq 'CloudBackupRuns' }
        Mock Get-CIPPCloudBackupSnapshot {
            [pscustomobject]@{
                Run      = $script:Runs[0]
                Manifest = @{}
                Areas    = [ordered]@{
                    ConditionalAccess = [pscustomobject]@{
                        Sections   = [ordered]@{
                            policies       = @([pscustomobject]@{ id = 'p1'; displayName = 'Block legacy' }, [pscustomobject]@{ id = 'p2'; displayName = 'MFA' })
                            namedLocations = @()
                        }
                        References = @{ Groups = @{}; Users = @{} }
                    }
                    SharePoint        = [pscustomobject]@{
                        Sections   = [ordered]@{ tenantSettings = [pscustomobject]@{ SharingCapability = 'Disabled' } }
                        References = @{ Groups = @{}; Users = @{} }
                    }
                }
            }
        }
        Mock Write-LogMessage { }
    }

    It 'returns 400 for a bad RunId or Area' {
        (Invoke-Snapshot -Query @{ RunId = 'x' }).StatusCode | Should -Be 400
        (Invoke-Snapshot -Query @{ RunId = $script:RunId; Area = 'Teams' }).StatusCode | Should -Be 400
        Should -Invoke Get-CIPPCloudBackupSnapshot -Times 0 -Exactly
    }

    It 'returns 404 for an unknown run' {
        (Invoke-Snapshot -Query @{ RunId = '11111111-1111-1111-1111-111111111111_0000000000000000009_c1' }).StatusCode | Should -Be 404
        Should -Invoke Get-CIPPCloudBackupSnapshot -Times 0 -Exactly
    }

    It 'returns 403 when the caller cannot access the run''s tenant' {
        $script:Allowed = @('c2')
        (Invoke-Snapshot -Query @{ RunId = $script:RunId }).StatusCode | Should -Be 403
        Should -Invoke Get-CIPPCloudBackupSnapshot -Times 0 -Exactly
    }

    It 'returns 404 when the snapshot reader cannot find the backup' {
        Mock Get-CIPPCloudBackupSnapshot { throw [System.Management.Automation.ItemNotFoundException]::new('manifest missing') }
        (Invoke-Snapshot -Query @{ RunId = $script:RunId }).StatusCode | Should -Be 404
    }

    It 'flattens every item with its area, section, label, key and name' {
        $Response = Invoke-Snapshot -Query @{ RunId = $script:RunId }

        $Response.StatusCode | Should -Be 200
        $Rows = @($Response.Body)
        $Rows.Count | Should -Be 3
        $Rows[0].Area | Should -Be 'ConditionalAccess'
        $Rows[0].Section | Should -Be 'policies'
        $Rows[0].SectionLabel | Should -Be 'Label policies'
        $Rows[0].Key | Should -Be 'p1'
        $Rows[0].Name | Should -Be 'Block legacy'
        $Rows[0].Item.id | Should -Be 'p1'
        $Rows[2].Area | Should -Be 'SharePoint'
        $Rows[2].Key | Should -Be 'tenantSettings'
        $Rows[2].Item.SharingCapability | Should -Be 'Disabled'
    }

    It 'passes the area filter to the snapshot reader' {
        Invoke-Snapshot -Query @{ RunId = $script:RunId; Area = 'Intune' } | Out-Null
        Should -Invoke Get-CIPPCloudBackupSnapshot -Times 1 -Exactly -ParameterFilter { $RunId -eq '11111111-1111-1111-1111-111111111111_0000000000000000001_c1' -and @($Area) -join ',' -eq 'Intune' }
    }
}
