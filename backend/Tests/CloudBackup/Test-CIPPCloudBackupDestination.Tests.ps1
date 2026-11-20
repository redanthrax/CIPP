BeforeAll {
    $BackendRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    function Set-CIPPCloudBackupObject { param($Destination, $Key, $Body, $ContentType, $Metadata) }
    function Get-CIPPCloudBackupObject { param($Destination, $Key) }
    function Remove-CIPPCloudBackupObject { param($Destination, $Key) }
    function Get-CIPPCloudBackupRetentionRule { param($Destination, $RuleName) }
    function Get-CIPPCloudBackupVersioning { param($Destination) }
    . (Join-Path $BackendRoot 'Modules/CIPPCore/Public/CloudBackup/Test-CIPPCloudBackupDestination.ps1')
    $script:Destination = [pscustomobject]@{ Provider = 'AzureBlob' }
}

Describe 'Test-CIPPCloudBackupDestination' {
    BeforeEach {
        $script:Written = $null
        Mock Set-CIPPCloudBackupObject { $script:Written = @{ Key = $Key; Body = $Body } }
        Mock Get-CIPPCloudBackupObject { @{ Body = $script:Written.Body; Metadata = @{} } }
        Mock Remove-CIPPCloudBackupObject { }
        Mock Get-CIPPCloudBackupRetentionRule { $null }
        Mock Get-CIPPCloudBackupVersioning { 'Enabled' }
    }

    It 'passes when every check works and probes with one .cipp-test object' {
        $Result = Test-CIPPCloudBackupDestination -Destination $Destination
        $Result.Write | Should -BeTrue
        $Result.Read | Should -BeTrue
        $Result.Delete | Should -BeTrue
        $Result.Lifecycle | Should -BeTrue
        $Result.Versioning | Should -Be 'Enabled'
        $Result.Passed | Should -BeTrue
        $Result.Errors.Count | Should -Be 0
        $Written.Key | Should -Match '^\.cipp-test-[0-9a-f-]{36}$'
        Should -Invoke Get-CIPPCloudBackupObject -ParameterFilter { $Key -eq $script:Written.Key }
        Should -Invoke Remove-CIPPCloudBackupObject -ParameterFilter { $Key -eq $script:Written.Key }
    }

    It 'skips read and delete when the write fails' {
        Mock Set-CIPPCloudBackupObject { throw 'Azure Storage returned 403 (AuthorizationPermissionMismatch): denied' }
        $Result = Test-CIPPCloudBackupDestination -Destination $Destination
        $Result.Write | Should -BeFalse
        $Result.Read | Should -BeFalse
        $Result.Delete | Should -BeFalse
        $Result.Lifecycle | Should -BeTrue
        $Result.Passed | Should -BeFalse
        $Result.Errors | Should -Be @('Write: Azure Storage returned 403 (AuthorizationPermissionMismatch): denied')
        Should -Invoke Get-CIPPCloudBackupObject -Times 0 -Exactly
        Should -Invoke Remove-CIPPCloudBackupObject -Times 0 -Exactly
    }

    It 'fails the read when the object comes back different' {
        Mock Get-CIPPCloudBackupObject { @{ Body = [byte[]](1, 2); Metadata = @{} } }
        $Result = Test-CIPPCloudBackupDestination -Destination $Destination
        $Result.Read | Should -BeFalse
        $Result.Delete | Should -BeTrue
        $Result.Passed | Should -BeFalse
        $Result.Errors[0] | Should -BeLike 'Read:*'
    }

    It 'still deletes the probe when the read throws' {
        Mock Get-CIPPCloudBackupObject { throw 'read denied' }
        $Result = Test-CIPPCloudBackupDestination -Destination $Destination
        $Result.Delete | Should -BeTrue
        $Result.Errors | Should -Be @('Read: read denied')
    }

    It 'reports a delete failure' {
        Mock Remove-CIPPCloudBackupObject { throw 'delete denied' }
        $Result = Test-CIPPCloudBackupDestination -Destination $Destination
        $Result.Delete | Should -BeFalse
        $Result.Passed | Should -BeFalse
        $Result.Errors | Should -Be @('Delete: delete denied')
    }

    It 'fails when the lifecycle configuration cannot be read' {
        Mock Get-CIPPCloudBackupRetentionRule { throw 'Azure Resource Manager returned AuthorizationFailed: no' }
        $Result = Test-CIPPCloudBackupDestination -Destination $Destination
        $Result.Lifecycle | Should -BeFalse
        $Result.Passed | Should -BeFalse
        $Result.Errors | Should -Be @('Lifecycle: Azure Resource Manager returned AuthorizationFailed: no')
    }

    It 'records a versioning failure without failing the test' {
        Mock Get-CIPPCloudBackupVersioning { throw 'versioning denied' }
        $Result = Test-CIPPCloudBackupDestination -Destination $Destination
        $Result.Versioning | Should -Be 'Unknown'
        $Result.Passed | Should -BeTrue
        $Result.Errors | Should -Be @('Versioning: versioning denied')
    }
}
