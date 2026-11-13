function Get-CIPPOneDriveCopyUser {
    <#
    .SYNOPSIS
        Resolves a user and their OneDrive for a OneDrive-to-OneDrive copy.
    .DESCRIPTION
        Looks the user up in the given tenant (so a user from another tenant is never found), then
        their OneDrive, its root and its quota. Refusals (unknown user, no OneDrive, recipient without
        a OneDrive licence) throw ArgumentException so the endpoint answers 400; anything else, such as
        throttling or an outage, is let through untyped.
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TenantFilter,

        # UPN or object id.
        [Parameter(Mandatory = $true)]
        [string]$UserId,

        # A recipient also needs an enabled SharePoint/OneDrive service plan; a leaver does not,
        # because their OneDrive stays readable for a while after the licence is gone.
        [ValidateSet('Leaver', 'Recipient')]
        [string]$Kind = 'Recipient'
    )

    $NotFoundPattern = 'ResourceNotFound|itemNotFound|does not exist|not found|404|mysite'
    $Label = if ($Kind -eq 'Leaver') { 'Leaver' } else { 'Recipient' }
    $Id = ([string]$UserId).Trim()

    $IsGuid = $Id -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    $IsUpn = $Id -match '^[^\s/\\?#%@]+@[^\s/\\?#%@]+$'
    if (-not ($IsGuid -or $IsUpn)) {
        throw [System.ArgumentException]::new("$Label '$Id' is not a user principal name or object id.")
    }
    $Escaped = [System.Uri]::EscapeDataString($Id)

    try {
        $User = New-GraphGetRequest -uri "https://graph.microsoft.com/v1.0/users/$Escaped`?`$select=id,userPrincipalName,displayName,assignedPlans" -tenantid $TenantFilter -asapp $true
    } catch {
        if ($_.Exception.Message -match $NotFoundPattern) {
            throw [System.ArgumentException]::new("$Label '$Id' was not found in tenant $TenantFilter.")
        }
        throw
    }
    if (-not $User.id) {
        throw [System.ArgumentException]::new("$Label '$Id' was not found in tenant $TenantFilter.")
    }
    $Upn = [string]$User.userPrincipalName

    $HasOneDrivePlan = @($User.assignedPlans | Where-Object { $_.service -eq 'SharePoint' -and $_.capabilityStatus -eq 'Enabled' }).Count -gt 0
    if ($Kind -eq 'Recipient' -and -not $HasOneDrivePlan) {
        throw [System.ArgumentException]::new("Recipient $Upn has no licence that includes OneDrive.")
    }

    try {
        $Drive = New-GraphGetRequest -uri "https://graph.microsoft.com/v1.0/users/$($User.id)/drive?`$select=id,webUrl,driveType,quota" -tenantid $TenantFilter -asapp $true
    } catch {
        if ($_.Exception.Message -match $NotFoundPattern) {
            throw [System.ArgumentException]::new("$Label $Upn has no OneDrive (it was never provisioned, or it has been deleted).")
        }
        throw
    }
    if (-not $Drive.id -or [string]::IsNullOrWhiteSpace($Drive.webUrl)) {
        throw [System.ArgumentException]::new("$Label $Upn has no OneDrive (it was never provisioned, or it has been deleted).")
    }
    if ($Drive.driveType -and $Drive.driveType -ne 'business') {
        throw [System.ArgumentException]::new("$Label $Upn's drive is not a OneDrive for work or school.")
    }

    $Root = New-GraphGetRequest -uri "https://graph.microsoft.com/v1.0/drives/$($Drive.id)/root?`$select=id,size,sharepointIds" -tenantid $TenantFilter -asapp $true
    $SiteUrl = [string]$Root.sharepointIds.siteUrl
    if ([string]::IsNullOrWhiteSpace($SiteUrl)) {
        # The library lives directly under the personal site: https://host/personal/<user>/Documents
        $SiteUrl = $Drive.webUrl.TrimEnd('/') -replace '/[^/]+$', ''
    }

    $QuotaRemaining = if ($null -ne $Drive.quota.remaining) { [int64]$Drive.quota.remaining } else { $null }

    [PSCustomObject]@{
        UserId            = [string]$User.id
        UserPrincipalName = $Upn
        DisplayName       = [string]$User.displayName
        HasOneDrivePlan   = $HasOneDrivePlan
        DriveId           = [string]$Drive.id
        DriveWebUrl       = $Drive.webUrl.TrimEnd('/')
        DriveHost         = ([System.Uri]$Drive.webUrl).Host
        SiteUrl           = $SiteUrl.TrimEnd('/')
        RootId            = [string]$Root.id
        QuotaRemaining    = $QuotaRemaining
        QuotaTotal        = if ($null -ne $Drive.quota.total) { [int64]$Drive.quota.total } else { $null }
    }
}
