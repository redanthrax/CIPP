# GCC High and DoD Direct Tenants

CIPP can sign in to a GCC High or DoD tenant as a **direct tenant** (the per-tenant authentication in the Tenant Onboarding wizard). These tenants live in Azure Government, which has its own sign-in authority (`login.microsoftonline.us`) and Microsoft Graph hosts (`graph.microsoft.us` for GCC High, `dod-graph.microsoft.us` for DoD). An app registered in the commercial cloud, such as CIPP-SAM, cannot be consented in them, so CIPP uses a second app that you register in Azure Government.

{% hint style="info" %}
GCC (Moderate) tenants run on the commercial cloud. Add them as **Commercial / GCC**; they do not need the Azure Government app.
{% endhint %}

{% hint style="warning" %}
This covers signing in and getting Microsoft Graph tokens. Until the remaining government cloud work lands, most CIPP pages still call commercial endpoints and will not return data for a government tenant, and the automatic permission push is skipped for them.
{% endhint %}

## 1. Register the Azure Government app

1. Sign in to the Azure Government portal (`https://portal.azure.us`) with an account in a GCC High or DoD tenant you control, and open **Microsoft Entra ID > App registrations > New registration**.
2. Name it (for example `CIPP-Gov`) and choose **Accounts in any organizational directory (Multitenant)**.
3. Under **Redirect URI**, choose **Web** and enter `https://<your CIPP address>/authredirect`. The Credentials page in CIPP shows the exact value.
4. Under **API permissions**, add these **delegated** Microsoft Graph permissions: `DelegatedPermissionGrant.ReadWrite.All`, `Directory.ReadWrite.All` and `AppRoleAssignment.ReadWrite.All`. Add any further permissions you want CIPP to use in government tenants; the tenant administrator consents to them when adding the tenant.
5. Under **Certificates & secrets**, add the credential CIPP will use (step 2): the certificate CIPP generates, or a client secret. If certificate authentication is turned on for your CIPP instance, only the certificate is used.

## 2. Enter the app in CIPP

Go to **CIPP > Advanced > Authentication > Credentials**. In the **Azure Government app (GCC High / DoD)** card:

1. Enter the **Application (client) ID** and select **Save**. Generating a certificate does not save the ID, and the card warns you while an ID is unsaved.
2. Add a credential:
   * **Certificate:** select **Generate certificate**, then **Download certificate**, and upload the `.cer` file to the app registration. CIPP keeps the private key in Key Vault. Compare the thumbprint shown in the card with the one in the app registration.
   * **Client secret:** enter it and select **Save**. It is stored in Key Vault next to the CIPP-SAM secret and is never shown again.

The **Signs in with** row shows which credential CIPP will use. It uses the certificate when certificate authentication is turned on for the instance, or when no client secret is stored, and the client secret otherwise. When certificate authentication is on, the client secret field is disabled because a secret would not be used.

The **Redirect URI** row shows the exact value to register: your CIPP address followed by `/authredirect`.

Changing these values needs the `CIPP.AppSettings.ReadWrite` permission **and** unrestricted tenant access (all tenants), the same as adding a tenant. Viewing the card's status only needs `CIPP.AppSettings.ReadWrite`.

{% hint style="warning" %}
**Generate new certificate** replaces the stored certificate immediately. If the instance signs in with the certificate, government tenants fail until you upload the new `.cer` to the app registration.
{% endhint %}

## 3. Add the tenant

In the Tenant Onboarding wizard, under per-tenant authentication, choose **GCC High** or **DoD** as the tenant cloud and select **Connect to Tenant**. Sign in with an administrator of the government tenant and consent. CIPP checks that the sign-in token belongs to the chosen cloud and that the tenant's public discovery data agrees before it adds the tenant.

If the Azure Government app is not configured, government tenants fail with "Azure Government app not configured". CIPP never uses the CIPP-SAM credentials for them.

## Partner tenant cloud

GDAP does not work across clouds, so your partner tenant, every GDAP tenant and CIPP-SAM are always in the same cloud. CIPP assumes that is the commercial cloud. If your partner tenant is in GCC High or DoD, set the Function App application setting `CIPP_PARTNER_CLOUD` to `USGovHigh` or `USGovDoD` (exact case) and restart the app. Leave it unset, or set it to `Commercial`, otherwise. Any other value stops CIPP from requesting tokens until it is corrected.

Tenants that already have a cloud stored keep it. To change one, use **Set Cloud Environment** on the tenants page (Tenant Administration > Tenants).
