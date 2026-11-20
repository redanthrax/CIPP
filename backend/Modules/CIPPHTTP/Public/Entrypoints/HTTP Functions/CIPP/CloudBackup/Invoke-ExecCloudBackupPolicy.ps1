function Invoke-ExecCloudBackupPolicy {
    <#
    .FUNCTIONALITY
        Entrypoint,AnyTenant
    .ROLE
        CIPP.CloudBackup.ReadWrite
    .SYNOPSIS
        Add, edit, delete or rotate the key of a cloud backup policy
    .DESCRIPTION
        Saves a cloud backup policy (tenants, configuration areas, schedule, retention, encryption). The destination's lifecycle rule that deletes backups older than the retention is set before the policy is saved, and the policy is not saved when that fails. Delete removes the policy and its lifecycle rule but keeps stored backups and keys. RotateKey creates a new encryption key for future backups.
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $Headers = $Request.Headers
    $Action = $Request.Body.Action
    $Id = $Request.Body.Id
    $Name = "$($Request.Body.Name)".Trim()
    $DestinationId = "$($Request.Body.DestinationId.value ?? $Request.Body.DestinationId)"
    # Tenant selector entries: { value, label, type: 'Tenant' | 'Group', addedFields: { customerId } }; value 'AllTenants' for all tenants
    $TenantInput = @($Request.Body.Tenants).Where({ $null -ne $_ })
    $ConfigAreas = @(foreach ($Area in @($Request.Body.ConfigAreas)) { if ($null -ne $Area) { "$($Area.value ?? $Area)" } })
    $ConfigSchedule = "$($Request.Body.ConfigSchedule.value ?? $Request.Body.ConfigSchedule)"
    $RetentionDays = if ($null -eq $Request.Body.RetentionDays -or "$($Request.Body.RetentionDays)" -eq '') { 90 } else { $Request.Body.RetentionDays -as [int] }
    $Encryption = $Request.Body.Encryption -eq $true
    $Enabled = $null -eq $Request.Body.Enabled -or $Request.Body.Enabled -eq $true
    $AllowedAreas = @('ConditionalAccess', 'Intune', 'Exchange', 'SharePoint')
    $AllowedSchedules = @('1h', '4h', '12h', '1d', '7d')

    if ($Action -notin @('Add', 'Edit', 'Delete', 'RotateKey')) {
        return ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::BadRequest
                Body       = @{ Results = 'Action must be Add, Edit, Delete or RotateKey' }
            })
    }
    if ($Action -ne 'Add' -and -not ($Id -as [guid])) {
        return ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::BadRequest
                Body       = @{ Results = 'Id must be a policy id (GUID)' }
            })
    }
    if ($Action -in @('Add', 'Edit')) {
        $Problem = if (-not $Name) {
            'Name is required'
        } elseif (-not ($DestinationId -as [guid])) {
            'Choose a destination'
        } elseif ($TenantInput.Count -eq 0) {
            'Choose at least one tenant'
        } elseif (@($TenantInput.Where({ $_.type -notin @('Tenant', 'Group') -or -not $_.value })).Count -gt 0) {
            'Tenants must be tenant or tenant group selections'
        } elseif ($ConfigAreas.Count -eq 0) {
            'Choose at least one configuration area'
        } elseif (@($ConfigAreas.Where({ $_ -notin $AllowedAreas })).Count -gt 0) {
            "Configuration areas must be from: $($AllowedAreas -join ', ')"
        } elseif ($ConfigSchedule -notin $AllowedSchedules) {
            "Schedule must be one of: $($AllowedSchedules -join ', ')"
        } elseif ($null -eq $RetentionDays -or $RetentionDays -lt 7 -or $RetentionDays -gt 3650) {
            'Retention days must be a whole number from 7 to 3650'
        }
        if ($Problem) {
            return ([HttpResponseContext]@{
                    StatusCode = [HttpStatusCode]::BadRequest
                    Body       = @{ Results = $Problem }
                })
        }
    }

    try {
        $AllowedTenants = @(Test-CIPPAccess -Request $Request -TenantList)
        $Table = Get-CIPPTable -TableName 'Config'

        $Existing = $null
        if ($Action -ne 'Add') {
            $Existing = Get-CIPPCloudBackupPolicy -Id $Id
            if (-not $Existing) {
                return ([HttpResponseContext]@{
                        StatusCode = [HttpStatusCode]::NotFound
                        Body       = @{ Results = "Policy $Id was not found" }
                    })
            }
            if (-not (Test-CIPPCloudBackupPolicyScope -Tenants $Existing.Tenants -AllowedTenants $AllowedTenants)) {
                return ([HttpResponseContext]@{
                        StatusCode = [HttpStatusCode]::Forbidden
                        Body       = @{ Results = 'This policy includes tenants you do not have access to' }
                    })
            }
        }

        switch ($Action) {
            'Delete' {
                try {
                    $Destination = Get-CIPPCloudBackupDestination -Id $Existing.DestinationId -IncludeSecret
                    if ($Destination) { Remove-CIPPCloudBackupRetentionRule -Destination $Destination -RuleName "cipp-$Id" }
                } catch {
                    $ErrorMessage = Get-CippException -Exception $_
                    Write-LogMessage -headers $Headers -API $Request.Params.CIPPEndpoint -message "Could not remove the retention rule for cloud backup policy $($Existing.Name): $($ErrorMessage.NormalizedError)" -sev Warning -LogData $ErrorMessage
                }
                Remove-CIPPAzDataTableEntity @Table -Entity @{ PartitionKey = 'CloudBackupPolicy'; RowKey = "$Id" } -Force
                Write-LogMessage -headers $Headers -API $Request.Params.CIPPEndpoint -message "Deleted cloud backup policy $($Existing.Name)" -sev Info
                $Result = "Deleted policy $($Existing.Name). Backups already stored stay in the destination until its retention rule removes them."
            }
            'RotateKey' {
                if (-not $Existing.Encryption) {
                    return ([HttpResponseContext]@{
                            StatusCode = [HttpStatusCode]::BadRequest
                            Body       = @{ Results = "Encryption is off for policy $($Existing.Name)" }
                        })
                }
                $KeyId = New-CIPPCloudBackupKey
                $KeyIds = @(@($Existing.KeyIds).Where({ $_ }); "$KeyId")
                Add-CIPPAzDataTableEntity @Table -Entity @{
                    PartitionKey = 'CloudBackupPolicy'
                    RowKey       = "$Id"
                    CurrentKeyId = "$KeyId"
                    KeyIds       = [CIPP.CippJson]::ToJson($KeyIds, 2) ?? (ConvertTo-Json -InputObject $KeyIds -Compress)
                } -OperationType 'UpsertMerge'
                Write-LogMessage -headers $Headers -API $Request.Params.CIPPEndpoint -message "Rotated the encryption key of cloud backup policy $($Existing.Name)" -sev Info
                $Result = "Created a new encryption key for policy $($Existing.Name). New backups use it; older backups keep their key."
            }
            default {
                $Lookup = Get-CIPPTenantLookup
                $Unknown = [System.Collections.Generic.List[string]]::new()
                $StoredTenants = @(foreach ($Entry in $TenantInput) {
                        if ($Entry.type -eq 'Group') {
                            [ordered]@{ type = 'Group'; id = "$($Entry.value)" }
                        } elseif ($Entry.value -eq 'AllTenants') {
                            [ordered]@{ type = 'AllTenants' }
                        } else {
                            $CustomerId = $Entry.addedFields.customerId ?? $Lookup["$($Entry.value)"].customerId
                            if ($CustomerId) { [ordered]@{ type = 'Tenant'; customerId = "$CustomerId" } } else { $Unknown.Add("$($Entry.label ?? $Entry.value)") }
                        }
                    })
                if ($Unknown.Count -gt 0) {
                    return ([HttpResponseContext]@{
                            StatusCode = [HttpStatusCode]::BadRequest
                            Body       = @{ Results = "Unknown tenants: $($Unknown -join ', ')" }
                        })
                }
                if (-not (Test-CIPPCloudBackupPolicyScope -Tenants $StoredTenants -AllowedTenants $AllowedTenants)) {
                    return ([HttpResponseContext]@{
                            StatusCode = [HttpStatusCode]::Forbidden
                            Body       = @{ Results = 'You can only back up tenants you have access to; All Tenants and tenant groups need access to every tenant' }
                        })
                }

                $Destination = Get-CIPPCloudBackupDestination -Id $DestinationId -IncludeSecret
                if (-not $Destination) {
                    return ([HttpResponseContext]@{
                            StatusCode = [HttpStatusCode]::BadRequest
                            Body       = @{ Results = "Destination $DestinationId does not exist" }
                        })
                }

                if ($Action -eq 'Add') { $Id = [guid]::NewGuid().ToString() }
                try {
                    Set-CIPPCloudBackupRetentionRule -Destination $Destination -RuleName "cipp-$Id" -Prefix "$Id/" -Days $RetentionDays
                } catch {
                    $ErrorMessage = Get-CippException -Exception $_
                    $Message = "Policy not saved: could not set the retention rule on destination $($Destination.Name): $($ErrorMessage.NormalizedError)"
                    Write-LogMessage -headers $Headers -API $Request.Params.CIPPEndpoint -message $Message -sev Error -LogData $ErrorMessage
                    return ([HttpResponseContext]@{
                            StatusCode = Get-CippErrorStatusCode -ErrorRecord $_
                            Body       = @{ Results = $Message }
                        })
                }
                if ($Existing -and $Existing.DestinationId -ne $DestinationId) {
                    try {
                        $OldDestination = Get-CIPPCloudBackupDestination -Id $Existing.DestinationId -IncludeSecret
                        if ($OldDestination) { Remove-CIPPCloudBackupRetentionRule -Destination $OldDestination -RuleName "cipp-$Id" }
                    } catch {
                        $ErrorMessage = Get-CippException -Exception $_
                        Write-LogMessage -headers $Headers -API $Request.Params.CIPPEndpoint -message "Could not remove the retention rule for cloud backup policy $Name from its previous destination: $($ErrorMessage.NormalizedError)" -sev Warning -LogData $ErrorMessage
                    }
                }

                $CurrentKeyId = "$($Existing.CurrentKeyId)"
                $KeyIds = @(@($Existing.KeyIds).Where({ $_ }))
                if ($Encryption -and -not $CurrentKeyId) {
                    $CurrentKeyId = "$(New-CIPPCloudBackupKey)"
                    $KeyIds = @($KeyIds; $CurrentKeyId)
                }
                $NextRun = if ($Existing.ConfigNextRun) { "$($Existing.ConfigNextRun)" } else { [datetime]::UtcNow.ToString('o') }

                $Entity = @{
                    PartitionKey   = 'CloudBackupPolicy'
                    RowKey         = "$Id"
                    Name           = $Name
                    Enabled        = $Enabled
                    DestinationId  = $DestinationId
                    Tenants        = [CIPP.CippJson]::ToJson($StoredTenants, 5) ?? (ConvertTo-Json -InputObject $StoredTenants -Depth 5 -Compress)
                    ConfigAreas    = [CIPP.CippJson]::ToJson($ConfigAreas, 2) ?? (ConvertTo-Json -InputObject $ConfigAreas -Compress)
                    ConfigSchedule = $ConfigSchedule
                    ConfigNextRun  = $NextRun
                    RetentionDays  = [int]$RetentionDays
                    Encryption     = $Encryption
                    CurrentKeyId   = $CurrentKeyId
                    KeyIds         = [CIPP.CippJson]::ToJson($KeyIds, 2) ?? (ConvertTo-Json -InputObject $KeyIds -Compress)
                }
                Add-CIPPAzDataTableEntity @Table -Entity $Entity -Force
                Write-LogMessage -headers $Headers -API $Request.Params.CIPPEndpoint -message "Saved cloud backup policy $Name" -sev Info
                $Result = "Saved policy $Name"
            }
        }
        $StatusCode = [HttpStatusCode]::OK
    } catch {
        $ErrorMessage = Get-CippException -Exception $_
        $Result = "Failed to $($Action.ToLower()) cloud backup policy: $($ErrorMessage.NormalizedError)"
        Write-LogMessage -headers $Headers -API $Request.Params.CIPPEndpoint -message $Result -sev Error -LogData $ErrorMessage
        $StatusCode = Get-CippErrorStatusCode -ErrorRecord $_
    }

    return ([HttpResponseContext]@{
            StatusCode = $StatusCode
            Body       = @{ Results = $Result }
        })
}
