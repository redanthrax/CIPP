function Test-CIPPCloudBackupDestination {
    <#
    .SYNOPSIS
        Checks that CIPP can write, read and delete objects and read the lifecycle configuration on a cloud backup destination.
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Destination
    )

    $Errors = [System.Collections.Generic.List[string]]::new()
    $Write = $false
    $Read = $false
    $Delete = $false
    $Lifecycle = $false
    $Versioning = 'Unknown'

    $Key = ".cipp-test-$([guid]::NewGuid())"
    $Content = [System.Text.Encoding]::UTF8.GetBytes("CIPP cloud backup connection test $([datetime]::UtcNow.ToString('o'))")

    try {
        Set-CIPPCloudBackupObject -Destination $Destination -Key $Key -Body $Content -ContentType 'text/plain'
        $Write = $true
    } catch {
        $Errors.Add("Write: $($_.Exception.Message)")
    }

    if ($Write) {
        try {
            $Object = Get-CIPPCloudBackupObject -Destination $Destination -Key $Key
            if ($Object -and [System.Convert]::ToBase64String([byte[]]$Object.Body) -eq [System.Convert]::ToBase64String($Content)) {
                $Read = $true
            } else {
                $Errors.Add('Read: the test object came back missing or different from what was written.')
            }
        } catch {
            $Errors.Add("Read: $($_.Exception.Message)")
        }
        try {
            Remove-CIPPCloudBackupObject -Destination $Destination -Key $Key
            $Delete = $true
        } catch {
            $Errors.Add("Delete: $($_.Exception.Message)")
        }
    }

    try {
        $null = Get-CIPPCloudBackupRetentionRule -Destination $Destination -RuleName 'cipp-connection-test'
        $Lifecycle = $true
    } catch {
        $Errors.Add("Lifecycle: $($_.Exception.Message)")
    }

    try {
        $Versioning = Get-CIPPCloudBackupVersioning -Destination $Destination
    } catch {
        $Errors.Add("Versioning: $($_.Exception.Message)")
    }

    return [pscustomobject]@{
        Write      = $Write
        Read       = $Read
        Delete     = $Delete
        Lifecycle  = $Lifecycle
        Versioning = $Versioning
        Passed     = $Write -and $Read -and $Delete -and $Lifecycle
        Errors     = @($Errors)
    }
}
