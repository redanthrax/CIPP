function Invoke-EditTenantCloudEnvironment {
    <#
    .FUNCTIONALITY
        Entrypoint,AnyTenant
    .ROLE
        Tenant.Config.ReadWrite
    .DESCRIPTION
        Manually sets the Microsoft cloud a tenant lives in (Commercial, USGovHigh or USGovDoD), overriding the value detected when the tenant was added. Use this for DoD tenants, which detection may report as USGovHigh.
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $APIName = $Request.Params.CIPPEndpoint
    $Headers = $Request.Headers

    $AllowedValues = @('Commercial', 'USGovHigh', 'USGovDoD')

    $customerId = $Request.Body.customerId
    # The cloud to set: Commercial, USGovHigh or USGovDoD - a plain string or the { label, value } object an autocomplete field sends.
    $RequestedValue = $Request.Body.cloudEnvironment.value ?? $Request.Body.cloudEnvironment

    if ([string]::IsNullOrWhiteSpace($customerId)) {
        return ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::BadRequest
                Body       = @{ Results = 'Missing required parameter: customerId' }
            })
    }

    # Normalise to the canonical casing so the stored value can be compared exactly later on.
    $CloudEnvironment = $AllowedValues | Where-Object { $_ -eq "$RequestedValue" } | Select-Object -First 1
    if (-not $CloudEnvironment) {
        return ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::BadRequest
                Body       = @{ Results = "Invalid cloudEnvironment '$RequestedValue'. Allowed values: $($AllowedValues -join ', ')" }
            })
    }

    # AnyTenant: Get-Tenants is narrowed to the caller's allowed tenants; no match means
    # unknown or out-of-scope, either way nothing may be written
    $Tenant = Get-Tenants -TenantFilter $customerId | Select-Object -First 1
    if (-not $Tenant) {
        return ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::Forbidden
                Body       = @{ Results = "Tenant '$customerId' not found or access denied" }
            })
    }

    try {
        $TenantsTable = Get-CippTable -tablename 'Tenants'
        $Entity = Get-CIPPAzDataTableEntity @TenantsTable -Filter "PartitionKey eq 'Tenants' and RowKey eq '$(ConvertTo-CIPPODataFilterValue -Value $Tenant.customerId)'"
        if (-not $Entity) { throw "Tenant row for $($Tenant.customerId) not found" }

        $Previous = if ($Entity.cloudEnvironment) { $Entity.cloudEnvironment } else { 'Commercial' }
        $Entity | Add-Member -NotePropertyName 'cloudEnvironment' -NotePropertyValue $CloudEnvironment -Force
        Add-CIPPAzDataTableEntity @TenantsTable -Entity $Entity -Force | Out-Null

        $Message = "Changed cloud environment for $($Tenant.displayName) from $Previous to $CloudEnvironment"
        Write-LogMessage -headers $Headers -API $APIName -tenant $Tenant.defaultDomainName -TenantId $Tenant.customerId -message $Message -Sev 'Info'
        $StatusCode = [HttpStatusCode]::OK
        $Body = @{ Results = $Message }
    } catch {
        $ErrorMessage = Get-CippException -Exception $_
        Write-LogMessage -headers $Headers -API $APIName -tenant $Tenant.defaultDomainName -TenantId $Tenant.customerId -message "Failed to set cloud environment: $($ErrorMessage.NormalizedError)" -Sev 'Error' -LogData $ErrorMessage
        $StatusCode = [HttpStatusCode]::InternalServerError
        $Body = @{ Results = "Failed to set cloud environment: $($ErrorMessage.NormalizedError)" }
    }

    return ([HttpResponseContext]@{
            StatusCode = $StatusCode
            Body       = $Body
        })
}
