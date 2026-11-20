function Grant-CIPPCloudBackupPermission {
    <#
    .SYNOPSIS
        Grants the CIPP app the Microsoft Graph application permissions that cloud backup workloads need in one tenant.
    .DESCRIPTION
        Returns { Status = Granted | Failed; Message; CheckedAt }. Never throws.
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TenantFilter,

        [Parameter(Mandatory = $true)]
        [string[]]$Workloads
    )

    # App role ids from https://learn.microsoft.com/en-us/graph/permissions-reference
    $RolesByWorkload = @{
        exchange   = @(
            'e2a3a72e-5f79-4c64-b1b1-878b674786c9'
            '99280d24-a782-4793-93cc-0888549957f6'
            '7d9f353d-a7bd-4fbb-822a-26d5dd39a3ce'
            '76577085-e73d-4f1d-b26a-85fb33892327'
            '798ee544-9d2d-430c-a058-570e29e34338'
            '089fe4d0-434a-44c5-8827-41ba8a0b17f5'
        )
        onedrive   = @('75359482-378d-4052-8f01-80520e7db3cd', '9492366f-7969-46a4-8d15-ed1a20078fff')
        sharepoint = @('75359482-378d-4052-8f01-80520e7db3cd', '9492366f-7969-46a4-8d15-ed1a20078fff')
        teams      = @(
            '6b7d71aa-70aa-4810-a8d9-5d9fb2830017'
            '7b2449af-6ccd-4f4d-9f78-e550c193f0d1'
            '2280dda6-0bfd-44ee-a2f4-cb867cfc4c1e'
            '59a6b24b-4225-4393-8165-ebaec5f55d7a'
        )
    }

    $CheckedAt = [datetime]::UtcNow.ToString('o')
    try {
        if ($TenantFilter -eq $env:TenantID -or [bool](Get-CIPPPartnerTenant -PartnerTenantId $TenantFilter)) {
            return [pscustomobject]@{
                Status    = 'Failed'
                Message   = 'Cloud backup cannot grant permissions in a partner tenant. Add them under CIPP > Settings > Permissions instead.'
                CheckedAt = $CheckedAt
            }
        }

        $RoleIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($Workload in $Workloads) { foreach ($RoleId in @($RolesByWorkload["$Workload".ToLowerInvariant()])) { if ($RoleId) { [void]$RoleIds.Add($RoleId) } } }
        if ($RoleIds.Count -eq 0) {
            return [pscustomobject]@{ Status = 'Granted'; Message = 'No permissions needed'; CheckedAt = $CheckedAt }
        }

        $ResourceAccess = [System.Collections.Generic.List[object]]::new()
        foreach ($RoleId in $RoleIds) { $ResourceAccess.Add(@{ id = $RoleId; type = 'Role' }) }
        $RequiredResourceAccess = @(@{ resourceAppId = '00000003-0000-0000-c000-000000000000'; resourceAccess = $ResourceAccess })

        $Output = @(Add-CIPPApplicationPermission -RequiredResourceAccess $RequiredResourceAccess -ApplicationId $env:ApplicationID -TenantFilter $TenantFilter)
        $Failures = @(foreach ($Line in $Output) { if ("$Line" -like 'Failed*') { "$Line" } })
        if ($Failures.Count -gt 0) {
            return [pscustomobject]@{ Status = 'Failed'; Message = $Failures -join '; '; CheckedAt = $CheckedAt }
        }
        [pscustomobject]@{ Status = 'Granted'; Message = $null; CheckedAt = $CheckedAt }
    } catch {
        [pscustomobject]@{ Status = 'Failed'; Message = (Get-CippException -Exception $_).NormalizedError; CheckedAt = $CheckedAt }
    }
}
