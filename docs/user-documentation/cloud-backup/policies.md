# Policies

A backup policy decides which tenants are backed up, which areas are included, how often backups run, where they go and how long they are kept.

## Policy settings

| Setting | Description |
| --- | --- |
| Policy name | A name for the policy. |
| Enabled | Disabled policies keep their settings but don't run on schedule. |
| Destination | Where backups are stored. Add a [destination](destinations.md) first if there isn't one. |
| Tenants | Pick individual tenants, tenant groups, or All Tenants. Groups and All Tenants include tenants added later. |
| What to back up | One or more of Conditional Access, Intune, Exchange Online and SharePoint. |
| Schedule | Every hour, 4 hours, 12 hours, day or week. |
| Keep backups for (days) | Between 7 and 3650 days. The default is 90. |
| Encrypt backups | Encrypts each backup before it leaves CIPP. |

## Retention

When you save a policy, CIPP adds a lifecycle rule to the destination for that policy's backups. The storage provider then deletes backups older than the number of days you set, without CIPP having to be online. Other lifecycle rules on the storage account or bucket are left alone. Deleting a policy removes its rule, but backups already stored stay until you delete them.

## Encryption

With encryption on, each backup is encrypted with a key that is kept in CIPP's Key Vault, not in the destination. Anyone with access to the storage alone can't read the backups.

Secret values in custom (OMA-URI) Intune profiles are only backed up when encryption is on. Without encryption they are stored as `(encrypted)` and the run shows a warning naming those profiles.

{% hint style="warning" %}
If the keys in CIPP's Key Vault are lost, encrypted backups can't be read. Make sure the Key Vault is part of your own backup and recovery plan.
{% endhint %}

**Rotate Encryption Key** creates a new key for future backups. Previous keys are kept, so older backups stay readable.

## Table Actions

| Action | Description |
| --- | --- |
| Edit Policy | Changes the policy's settings. |
| Run Backup Now | Backs up every tenant in the policy straight away. The schedule is not changed. |
| View Runs | Opens the runs page filtered to this policy. |
| Rotate Encryption Key | Creates a new encryption key. Only shown when encryption is on. |
| Delete Policy | Stops the policy and removes its retention rule. Stored backups and encryption keys are kept. |

{% include "../../../.gitbook/includes/feature-request.md" %}
