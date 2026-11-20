# Destinations

A destination is the Azure storage account or S3 bucket where Cloud Backup writes backups. Destinations are shared by all policies, and only users with access to CIPP's application settings can manage them.

## Adding a destination

Choose a storage provider and fill in its details. Secrets (the client secret or secret access key) are stored in CIPP's Key Vault and are never shown again. When editing a destination, leave the secret as is to keep it, or type a new one to replace it.

When you save, CIPP tests the destination straight away and shows any check that failed.

### Azure Blob Storage

CIPP signs in to the storage account with an app registration (service principal) you create in your own Entra tenant.

| Field | Description |
| --- | --- |
| Storage account name | The storage account's name. |
| Container | The blob container backups are written to. Create it before adding the destination. |
| Subscription ID and Resource group | Where the storage account lives. CIPP needs these to manage the retention rule. |
| Directory (tenant) ID | The Entra tenant that owns the app registration. |
| Application (client) ID and Client secret | The app registration's credentials. |

Give the app registration these roles on the storage account:

* **Storage Blob Data Contributor**, to write, read and delete backups.
* **Storage Account Contributor**, to set the lifecycle management rule that deletes old backups.

### Amazon S3 and S3-compatible storage

| Field | Description |
| --- | --- |
| Endpoint URL | Leave blank for Amazon S3. For S3-compatible storage (for example Wasabi, Backblaze B2 or MinIO), enter the provider's endpoint. |
| Region | The bucket's region. Leave blank to use us-east-1. |
| Bucket | The bucket backups are written to. Create it before adding the destination. |
| Access key ID and Secret access key | The credentials CIPP uses. |
| Use path-style addresses | Turn on if your provider doesn't support the bucket name in the host name. |

The access key needs these permissions on the bucket: `s3:PutObject`, `s3:GetObject`, `s3:DeleteObject`, `s3:ListBucket`, `s3:GetLifecycleConfiguration`, `s3:PutLifecycleConfiguration` and `s3:GetBucketVersioning`.

## Table Actions

| Action | Description |
| --- | --- |
| Test Connection | Writes, reads and deletes a small test file, and checks CIPP can read the retention rules. The result is shown in the destination's details. |
| Edit Destination | Changes the destination's details or replaces its secret. The provider can't be changed. |
| Delete Destination | Removes the destination and its stored secret. Backups already stored are not deleted. A destination used by a policy can't be deleted. |

{% include "../../../.gitbook/includes/feature-request.md" %}
