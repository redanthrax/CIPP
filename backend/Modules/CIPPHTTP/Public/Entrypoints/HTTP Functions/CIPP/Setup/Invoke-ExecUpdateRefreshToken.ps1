function Invoke-ExecUpdateRefreshToken {
    <#
    .FUNCTIONALITY
        Entrypoint,AnyTenant
    .ROLE
        CIPP.AppSettings.ReadWrite
    #>
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '')]
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $APIName = $Request.Params.CIPPEndpoint
    $Headers = $Request.Headers
    $KV = Get-CippKeyVaultName

    $TenantId = [string]$Request.Body.tenantId
    if ($TenantId -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z') {
        return ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::BadRequest
                Body       = @{ Results = 'tenantId must be a tenant ID (GUID).' }
            })
    }
    # A tenant CIPP does not manage yet is being onboarded, which only needs the permission.
    $AllowedTenants = Test-CIPPAccess -Request $Request -TenantList
    if ($AllowedTenants -notcontains 'AllTenants' -and $AllowedTenants -notcontains $TenantId) {
        $TenantsTable = Get-CIPPTable -tablename 'Tenants'
        if ($TenantId -eq $env:TenantID -or (Get-CIPPAzDataTableEntity @TenantsTable -Filter "PartitionKey eq 'Tenants' and customerId eq '$TenantId'")) {
            return ([HttpResponseContext]@{
                    StatusCode = [HttpStatusCode]::Forbidden
                    Body       = @{ Results = "$TenantId is outside your access." }
                })
        }
    }

    # A direct-tenant sign-in must never replace the partner tenant's refresh token, which backs every
    # GDAP tenant. The direct-tenant buttons send directTenant = true; a partner account used there is
    # refused here, before anything is written (ExecAddTenant would refuse it later, too late).
    if ($Request.Body.directTenant -eq $true -and $TenantId -eq $env:TenantID) {
        Write-LogMessage -headers $Headers -API $APIName -tenant $TenantId -message 'Refused a direct-tenant sign-in with a partner tenant account; the partner refresh token was not changed.' -Sev 'Warning'
        return ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::BadRequest
                Body       = @{ Results = @{ resultText = 'This is your partner tenant. Sign in with an account from the tenant you want to add. The stored credentials were not changed.'; state = 'failed' } }
            })
    }

    # An existing direct tenant's token is replaced only by a sign-in to that tenant in its stored cloud
    # (redanthrax/CIPP#2). Checked before anything is written: ExecAddTenant validates later, by which
    # time the working token would already be overwritten. The access token's claims are not verified
    # here; this guards against signing in to the wrong cloud or tenant, Microsoft validates the token.
    if ($TenantId -ne $env:TenantID) {
        $DirectTable = Get-CIPPTable -tablename 'Tenants'
        $ExistingDirect = @(Get-CIPPAzDataTableEntity @DirectTable -Filter "PartitionKey eq 'Tenants' and RowKey eq '$TenantId'") |
            Where-Object { $_.delegatedPrivilegeStatus -eq 'directTenant' } | Select-Object -First 1
        if ($ExistingDirect) {
            try {
                $StoredCloud = if ($ExistingDirect.cloudEnvironment) { [string]$ExistingDirect.cloudEnvironment } else { Get-CIPPPartnerCloudEnvironment }
                $SignIn = Resolve-CIPPSignInCloud -CloudEnvironment $Request.Body.cloudEnvironment -AccessToken ([string]$Request.Body.accessToken)
                if ($SignIn.CloudEnvironment -cne $StoredCloud) {
                    # USGovHigh and USGovDoD share an authority, so the stored cloud can be changed between them; a move
                    # between Commercial and government needs the tenant removed and added again (redanthrax/CIPP#3).
                    $Remedy = if ($SignIn.CloudEnvironment -cne 'Commercial' -and $StoredCloud -cne 'Commercial') { "or change the tenant's cloud environment first" } else { "or remove the tenant and add it again in $($SignIn.CloudEnvironment)" }
                    throw "The sign-in was for $($SignIn.CloudEnvironment) but the tenant is stored as $StoredCloud. Sign in again choosing $StoredCloud, $Remedy."
                }
                $Parts = ([string]$Request.Body.accessToken) -split '\.'
                $Payload = $Parts[1].Replace('-', '+').Replace('_', '/')
                $Payload = $Payload.PadRight($Payload.Length + (4 - $Payload.Length % 4) % 4, '=')
                $TokenTenant = [string](([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Payload)) | ConvertFrom-Json -ErrorAction Stop).tid)
                if ($TokenTenant -ne $TenantId) { throw 'The sign-in token does not belong to this tenant.' }
            } catch {
                $Reason = $_.Exception.Message
                Write-LogMessage -headers $Headers -API $APIName -tenant $TenantId -message "Kept the stored refresh token for direct tenant ${TenantId}: $Reason" -Sev 'Warning'
                return ([HttpResponseContext]@{
                        StatusCode = [HttpStatusCode]::BadRequest
                        Body       = @{ Results = @{ resultText = "The stored credentials were not changed. $Reason"; state = 'failed' } }
                    })
            }
        }
    }

    try {
        # Handle refresh token update
        #make sure we get the latest authentication:
        $auth = Get-CIPPAuthentication
        $IsPartnerTenant = $env:TenantID -eq $Request.body.tenantId

        if ($env:AzureWebJobsStorage -eq 'UseDevelopmentStorage=true' -or $env:NonLocalHostAzurite -eq 'true') {
            $DevSecretsTable = Get-CIPPTable -tablename 'DevSecrets'
            $Secret = Get-CIPPAzDataTableEntity @DevSecretsTable -Filter "PartitionKey eq 'Secret' and RowKey eq 'Secret'"
            if ($IsPartnerTenant) {
                $Secret | Add-Member -MemberType NoteProperty -Name 'RefreshToken' -Value $Request.body.refreshtoken -Force
                Set-Item -Path env:RefreshToken -Value $Request.body.refreshtoken -Force
            } else {
                $name = $Request.body.tenantId -replace '-', '_'
                $Secret | Add-Member -MemberType NoteProperty -Name $name -Value $Request.body.refreshtoken -Force
                Set-Item -Path env:$name -Value $Request.body.refreshtoken -Force
            }
            Add-CIPPAzDataTableEntity @DevSecretsTable -Entity $Secret -Force
        } else {
            if ($IsPartnerTenant) {
                $null = Set-CippKeyVaultSecret -VaultName $kv -Name 'RefreshToken' -SecretValue (ConvertTo-SecureString -String $Request.body.refreshtoken -AsPlainText -Force)
                Set-Item -Path env:RefreshToken -Value $Request.body.refreshtoken -Force
            } else {
                Write-Information "$($env:TenantID) does not match $($Request.body.tenantId) - adding a new secret for the tenant."
                $name = $Request.body.tenantId
                try {
                    $null = Set-CippKeyVaultSecret -VaultName $kv -Name $name -SecretValue (ConvertTo-SecureString -String $Request.body.refreshtoken -AsPlainText -Force)
                    Set-Item -Path env:$name -Value $Request.body.refreshtoken -Force
                } catch {
                    Write-Information "Failed to set secret $name in KeyVault. $($_.Exception.Message)"
                    throw $_
                }
            }
        }

        # Cached access tokens were minted from the old refresh token; drop them so the new one takes effect now.
        # The partner token backs every GDAP tenant, a direct tenant's token only itself (cached under GUID or domain).
        if ($IsPartnerTenant) {
            $null = Clear-CippTokenCache
        } else {
            $null = Clear-CippTokenCache -TenantFilter $Request.body.tenantId
        }
        $null = Set-CIPPCredentialVersion

        if ($IsPartnerTenant) {
            try {
                $Queue = New-CippQueueEntry -Name 'Update Permissions - Partner Tenant' -TotalTasks 1
                $TenantBatch = @([PSCustomObject]@{
                        defaultDomainName = 'PartnerTenant'
                        customerId        = $env:TenantID
                        displayName       = '*Partner Tenant'
                        FunctionName      = 'UpdatePermissionsQueue'
                        QueueId           = $Queue.RowKey
                    })
                $InputObject = [PSCustomObject]@{
                    OrchestratorName = 'UpdatePermissionsOrchestrator'
                    Batch            = @($TenantBatch)
                }
                $null = Start-CIPPOrchestrator -InputObject $InputObject
                Write-Information 'Started permissions update orchestrator for Partner Tenant'
            } catch {
                Write-Warning "Failed to start permissions orchestrator: $($_.Exception.Message)"
            }
        }

        if ($request.body.tenantId -eq $env:TenantID) {
            $TenantName = 'your partner tenant'
        } else {
            $TenantName = $request.body.tenantId
        }
        $Result = "Successfully updated the credentials for $($TenantName). You may continue to the next step, or add additional tenants if required."
        Write-LogMessage -headers $Headers -API $APIName -tenant $Request.body.tenantId -message $Result -Sev 'Info'
        $Results = @{
            'resultText' = $Result
            'state'      = 'success'
        }

        return ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::OK
                Body       = $Results
            })
    } catch {
        $ErrorMessage = Get-CippException -Exception $_
        $Result = "Failed to update refresh token credentials. $($_.InvocationInfo.ScriptLineNumber): $($ErrorMessage.NormalizedError)"
        Write-LogMessage -headers $Headers -API $APIName -tenant $Request.body.tenantId -message $Result -Sev 'Error' -LogData $ErrorMessage
        $Results = [pscustomobject]@{
            'Results' = @{
                resultText = "Failed. $($_.InvocationInfo.ScriptLineNumber): $($_.Exception.message)"
                state      = 'failed'
            }
        }

        return ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::InternalServerError
                Body       = $Results
            })

    }
}
