function Push-CloudBackupTenant {
    <#
    .SYNOPSIS
        Backs up one tenant's configuration for a cloud backup policy
    .FUNCTIONALITY
        Entrypoint
    #>
    [CmdletBinding()]
    param($Item)

    $PolicyId = "$($Item.PolicyId)"
    $TenantId = "$($Item.customerId)"
    $StartedAt = [datetime]::UtcNow
    $Stamp = $StartedAt.ToString('yyyyMMddTHHmmssZ')
    $AreaResults = [System.Collections.Generic.List[object]]::new()
    $ManifestAreas = [System.Collections.Generic.List[object]]::new()
    $Warnings = [System.Collections.Generic.List[string]]::new()
    $Run = @{
        PartitionKey  = $PolicyId
        RowKey        = '{0:D19}_{1}' -f ([datetime]::MaxValue.Ticks - $StartedAt.Ticks), $TenantId
        PolicyId      = $PolicyId
        PolicyName    = ''
        DestinationId = ''
        TenantId      = $TenantId
        Tenant        = "$($Item.QueueName)"
        Workload      = 'Config'
        Status        = 'Running'
        StartedAt     = $StartedAt.ToString('o')
        CompletedAt   = ''
        Items         = 0
        Bytes         = [int64]0
        Areas         = '[]'
        Warnings      = '[]'
        Location      = ''
    }
    $RunsTable = $null
    $Policy = $null

    try {
        $RunsTable = Get-CIPPTable -TableName 'CloudBackupRuns'
        Add-CIPPAzDataTableEntity @RunsTable -Entity $Run -Force

        $Policy = Get-CIPPCloudBackupPolicy -Id $PolicyId
        if (-not $Policy) { throw "Cloud backup policy $PolicyId no longer exists" }
        $Run.PolicyName = $Policy.Name
        $Run.DestinationId = "$($Policy.DestinationId)"

        $Tenant = @(Get-Tenants -TenantFilter $TenantId)[0]
        if (-not $Tenant) { throw "Tenant $TenantId was not found or is excluded" }
        $Run.Tenant = $Tenant.defaultDomainName

        $Destination = Get-CIPPCloudBackupDestination -Id $Policy.DestinationId -IncludeSecret
        if (-not $Destination) { throw "Destination $($Policy.DestinationId) no longer exists" }

        $KeyId = $null
        $Key = $null
        if ($Policy.Encryption) {
            if (-not $Policy.CurrentKeyId) { throw 'Encryption is on but the policy has no encryption key' }
            $KeyId = $Policy.CurrentKeyId
            $Key = Get-CIPPCloudBackupKey -KeyId $KeyId
        }

        $Prefix = "$PolicyId/$TenantId/config/$Stamp"
        $Run.Location = "$Prefix/"

        foreach ($Area in $Policy.ConfigAreas) {
            $AreaResult = [ordered]@{ Area = "$Area"; Items = 0; Bytes = [int64]0; Status = 'Failed'; Error = $null }
            try {
                $Data = Get-CIPPCloudBackupConfigData -TenantFilter $Tenant.defaultDomainName -Area $Area -IncludeSecrets:([bool]$Policy.Encryption)
                $AreaWarnings = @($Data.Warnings).Where({ $_ })
                foreach ($Warning in $AreaWarnings) { $Warnings.Add($Warning) }
                $ItemCount = [int](@(foreach ($Section in $Data.Sections.Values) { if ($null -ne $Section) { @($Section).Count } }) | Measure-Object -Sum).Sum

                $Document = [ordered]@{
                    Area       = "$Area"
                    TenantId   = $TenantId
                    CapturedAt = [datetime]::UtcNow.ToString('o')
                    Sections   = $Data.Sections
                    References = $Data.References ?? @{ Groups = @{}; Users = @{} }
                }
                $Data = $null
                $Json = [CIPP.CippJson]::ToJson($Document, 100) ?? (ConvertTo-Json -InputObject $Document -Depth 100 -Compress)
                $Document = $null

                $Buffer = [System.IO.MemoryStream]::new()
                $Gzip = [System.IO.Compression.GZipStream]::new($Buffer, [System.IO.Compression.CompressionLevel]::Optimal, $true)
                $Writer = [System.IO.StreamWriter]::new($Gzip, [System.Text.UTF8Encoding]::new($false))
                $Writer.Write($Json)
                $Writer.Dispose()
                $Json = $null
                $Body = $Buffer.ToArray()
                $Buffer.Dispose()

                $ObjectKey = "$Prefix/$Area.json.gz"
                $ContentType = 'application/gzip'
                if ($Policy.Encryption) {
                    $Body = Protect-CIPPCloudBackupData -Bytes $Body -KeyId $KeyId -Key $Key
                    $ObjectKey = "$ObjectKey.enc"
                    $ContentType = 'application/octet-stream'
                }
                Set-CIPPCloudBackupObject -Destination $Destination -Key $ObjectKey -Body $Body -ContentType $ContentType

                $AreaResult.Items = $ItemCount
                $AreaResult.Bytes = [int64]$Body.Length
                $AreaResult.Status = if ($AreaWarnings.Count -gt 0) { 'PartialSuccess' } else { 'Succeeded' }
                $ManifestAreas.Add([ordered]@{
                        Area   = "$Area"
                        Key    = $ObjectKey
                        Items  = $AreaResult.Items
                        Bytes  = $AreaResult.Bytes
                        Sha256 = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($Body)).ToLowerInvariant()
                        Status = $AreaResult.Status
                    })
            } catch {
                $AreaResult.Error = (Get-CippException -Exception $_).NormalizedError
                $AreaResult.Status = 'Failed'
            } finally {
                $Data = $null
                $Document = $null
                $Json = $null
                $Body = $null
            }
            $AreaResults.Add($AreaResult)
        }

        if ($ManifestAreas.Count -gt 0) {
            try {
                $Manifest = [ordered]@{
                    PolicyId      = $PolicyId
                    TenantId      = $TenantId
                    DestinationId = $Run.DestinationId
                    StartedAt     = $Run.StartedAt
                    CompletedAt   = [datetime]::UtcNow.ToString('o')
                    Encrypted     = [bool]$Policy.Encryption
                    KeyId         = $KeyId
                    Areas         = $ManifestAreas
                }
                $ManifestJson = [CIPP.CippJson]::ToJson($Manifest, 10) ?? (ConvertTo-Json -InputObject $Manifest -Depth 10 -Compress)
                Set-CIPPCloudBackupObject -Destination $Destination -Key "$Prefix/manifest.json" -Body ([System.Text.Encoding]::UTF8.GetBytes($ManifestJson)) -ContentType 'application/json'
            } catch {
                $Warnings.Add("Manifest: $((Get-CippException -Exception $_).NormalizedError)")
            }
        }
    } catch {
        $Warnings.Add((Get-CippException -Exception $_).NormalizedError)
    } finally {
        $Uploaded = @($AreaResults.Where({ $_.Status -ne 'Failed' })).Count
        $Run.Status = if ($Uploaded -eq 0) {
            'Failed'
        } elseif ($Uploaded -lt $AreaResults.Count -or $Warnings.Count -gt 0) {
            'PartialSuccess'
        } else {
            'Succeeded'
        }
        $Run.CompletedAt = [datetime]::UtcNow.ToString('o')
        $Run.Items = [int](@(foreach ($Result in $AreaResults) { $Result.Items }) | Measure-Object -Sum).Sum
        $Run.Bytes = [int64](@(foreach ($Result in $AreaResults) { $Result.Bytes }) | Measure-Object -Sum).Sum
        $Run.Areas = [CIPP.CippJson]::ToJson($AreaResults, 5) ?? (ConvertTo-Json -InputObject @($AreaResults) -Depth 5 -Compress)
        $Run.Warnings = [CIPP.CippJson]::ToJson($Warnings, 5) ?? (ConvertTo-Json -InputObject @($Warnings) -Depth 5 -Compress)
        try {
            $RunsTable = $RunsTable ?? (Get-CIPPTable -TableName 'CloudBackupRuns')
            Add-CIPPAzDataTableEntity @RunsTable -Entity $Run -Force
        } catch {
            $ErrorMessage = Get-CippException -Exception $_
            Write-LogMessage -API 'CloudBackup' -tenant $Run.Tenant -tenantid $TenantId -message "Could not record the cloud backup run for policy $($Run.PolicyName): $($ErrorMessage.NormalizedError)" -sev Error -LogData $ErrorMessage
        }
        $Severity = switch ($Run.Status) { 'Succeeded' { 'Info' } 'PartialSuccess' { 'Warning' } default { 'Error' } }
        $Detail = if ($Warnings.Count -gt 0) { ": $($Warnings -join '; ')" } else { '' }
        Write-LogMessage -API 'CloudBackup' -tenant $Run.Tenant -tenantid $TenantId -message "Cloud backup $($Run.PolicyName) finished with status $($Run.Status)$Detail" -sev $Severity
    }
}
