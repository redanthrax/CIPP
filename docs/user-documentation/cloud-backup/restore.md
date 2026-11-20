# Restore

Restore writes settings from a backup back into a tenant: the same tenant the backup came from, or another tenant you manage. Open it from the **Browse and restore** action on the [runs](runs.md) page, or pick a policy and a backup at the top of the page.

You need the **Cloud Backup restore** permission (`CIPP.CloudBackupRestore.ReadWrite`). Editors don't have it by default. Without it you can still browse a backup and [compare](compare.md) it.

## What can be restored

| Area | What is restored |
| --- | --- |
| Conditional Access | Named locations, custom authentication strengths, authentication contexts, then the policies that use them. |
| Intune | Every policy type in the backup, with scope tags, assignment filters and assignments. Device configurations whose secret values were saved without encryption can't be restored. |
| Exchange Online | Organisation settings, mail flow rules, connectors, domains, anti-spam, anti-phishing, anti-malware and Defender for Office 365 policies and rules, and distribution groups. Built-in default policies are only ever updated. |
| Exchange mailbox settings | Mailbox settings and missing mailbox and recipient permissions. Only to the tenant the backup came from. Permissions are only added, never removed. |
| SharePoint | Not restored. Use [compare](compare.md) to see what changed. |

## Restoring step by step

1. Choose the backup. The table lists everything in it. Click an item to see its saved settings.
2. Select the items to restore, or select none to include everything in the chosen areas.
3. Choose the options:
   * **Restore to tenant**: defaults to the tenant the backup came from.
   * **Areas to restore**.
   * **When an item already exists**: skip it (the default), overwrite it, or create a copy named "*name* (restored *date*)". Copies don't take effect on their own: Intune copies have no assignments, and Conditional Access policies, mail flow rules and connectors are created turned off.
   * **Conditional Access policy state after restore**: keep the state from the backup, report-only, or off. It defaults to keeping the state for the same tenant and to report-only for another tenant.
4. Select **Preview restore**. Nothing is changed yet. The preview lists what would happen to each item, the settings that differ from the tenant now, and anything that can't be matched in the target.
5. Check the preview, then select **Restore** and confirm. The confirmation names the target tenant and how many items are created, overwritten or skipped.

If you change any option or selection after the preview, run the preview again. A preview can be used for one restore, within 60 minutes.

CIPP replaces its [custom variables](../tenant/administration/tenants/global-variables.md) (such as `%tenantname%`) in everything it writes to a tenant, restores included. Restored text that contains one of these tokens is written with the target tenant's value.

## Restoring to another tenant

Policies refer to groups and users by their ID, which is different in every tenant. When the target is another tenant, CIPP looks for:

* groups with exactly the same display name. If two groups share the name, neither is used.
* users with exactly the same user principal name.

Groups and users that a policy applies to are left out when they aren't found, and listed in the preview. A Conditional Access policy that would end up applying to nobody is not created. When an exclusion (for example a break-glass group) isn't found, the policy or assignment isn't restored at all, so it can't end up applying to more people than before. Create the missing group and preview again. Accepted domains are only restored if the domain is already verified in the target. Distribution groups are created without members, and mailbox settings and permissions are not restored.

Every restore is listed on the [Restore & Compare History](jobs.md) page and in the CIPP logs.

{% include "../../../.gitbook/includes/feature-request.md" %}
