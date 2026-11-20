# Compare

Compare shows what has changed between a backup and the tenant's current configuration, or between two backups. Nothing in the tenant is changed. Open it from the **Compare with live** action on the [runs](runs.md) page, or pick a policy and a backup at the top of the page.

1. Choose the backup.
2. Choose what to compare it with: **Current tenant configuration**, or **Another backup** (pick its policy and backup).
3. Choose the areas, then select **Compare**. The page updates by itself while the comparison runs.

## Results

The summary lists, for each area, how many items changed, how many exist only in the current configuration (or the other backup), how many exist only in the backup, and how many are the same.

The table lists every item that differs. Click an item to see each setting that differs, with its value in the backup and its current value.

Values that are hidden in the backup, such as secrets, are never reported as a difference. When the two sides are different tenants, items are matched by name.

SharePoint settings can be compared but not [restored](restore.md).

Every comparison is listed on the [Restore & Compare History](jobs.md) page.

{% include "../../../.gitbook/includes/feature-request.md" %}
