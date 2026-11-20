function Invoke-ExecCloudBackupRun {
    <#
    .FUNCTIONALITY
        Entrypoint,AnyTenant
    .ROLE
        CIPP.CloudBackup.ReadWrite
    .SYNOPSIS
        Run a cloud backup policy now
    .DESCRIPTION
        Starts a configuration backup for a cloud backup policy straight away, for all of its tenants or only the given tenant. The policy's schedule is not changed.
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $PolicyId = $Request.Body.PolicyId
    # Optional: back up only this tenant (default domain or customerId) of the policy
    $TenantFilter = $Request.Body.tenantFilter.value ?? $Request.Body.tenantFilter

    if (-not ($PolicyId -as [guid])) {
        return ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::BadRequest
                Body       = @{ Results = 'PolicyId must be a policy id (GUID)' }
            })
    }
    if ($TenantFilter -eq 'AllTenants') { $TenantFilter = $null }

    try {
        $Policy = Get-CIPPCloudBackupPolicy -Id $PolicyId
        if (-not $Policy) {
            return ([HttpResponseContext]@{
                    StatusCode = [HttpStatusCode]::NotFound
                    Body       = @{ Results = "Policy $PolicyId was not found" }
                })
        }

        $AllowedTenants = @(Test-CIPPAccess -Request $Request -TenantList)
        if ($AllowedTenants -notcontains 'AllTenants') {
            $InScope = if ($TenantFilter) {
                $Tenant = @(Get-Tenants -TenantFilter $TenantFilter)[0]
                $Tenant -and $AllowedTenants -contains $Tenant.customerId
            } else {
                Test-CIPPCloudBackupPolicyScope -Tenants $Policy.Tenants -AllowedTenants $AllowedTenants
            }
            if (-not $InScope) {
                return ([HttpResponseContext]@{
                        StatusCode = [HttpStatusCode]::Forbidden
                        Body       = @{ Results = 'This policy includes tenants you do not have access to' }
                    })
            }
        }

        $Params = @{ PolicyId = $Policy.Id; Force = $true }
        if ($TenantFilter) { $Params.TenantFilter = $TenantFilter }
        $OrchestratorStatus = Start-CloudBackupOrchestrator @Params

        if ("$OrchestratorStatus" -like '*-Skipped') {
            $Result = "A backup for policy $($Policy.Name) is already running, so this request was skipped"
            $StatusCode = [HttpStatusCode]::OK
        } elseif ($OrchestratorStatus -is [int]) {
            $Result = if ($TenantFilter) { "Policy $($Policy.Name) does not back up $TenantFilter" } else { "Policy $($Policy.Name) has no tenants to back up" }
            $StatusCode = [HttpStatusCode]::BadRequest
        } elseif ($OrchestratorStatus) {
            $Result = "Backup started for policy $($Policy.Name)"
            $StatusCode = [HttpStatusCode]::Accepted
            Write-LogMessage -headers $Request.Headers -API $Request.Params.CIPPEndpoint -tenant $TenantFilter -message "Started cloud backup policy $($Policy.Name)" -sev Info
        } else {
            $Result = "Could not start the backup for policy $($Policy.Name). Check the logs."
            $StatusCode = [HttpStatusCode]::InternalServerError
        }
    } catch {
        $ErrorMessage = Get-CippException -Exception $_
        $Result = "Failed to start cloud backup: $($ErrorMessage.NormalizedError)"
        Write-LogMessage -headers $Request.Headers -API $Request.Params.CIPPEndpoint -message $Result -sev Error -LogData $ErrorMessage
        $StatusCode = Get-CippErrorStatusCode -ErrorRecord $_
    }

    return ([HttpResponseContext]@{
            StatusCode = $StatusCode
            Body       = @{ Results = $Result }
        })
}
