# Runs

Every backup of a tenant is recorded as a run. The table shows the newest runs first, and you can show the runs for a single policy with the filter above the table.

## Table Details

| Column | Description |
| --- | --- |
| Started At | When the backup started. |
| Policy Name | The policy that ran. |
| Tenant | The tenant that was backed up. |
| Status | **Succeeded**, **Partial success** (some areas failed or reported a warning), **Failed** (nothing could be uploaded), or **Running**. |
| Items | The number of settings and objects backed up. |
| Size | The size of the files uploaded to the destination. |
| Duration | How long the backup took. |

Open a run to see the result for each area, any error or warning, and where the files were stored in the destination. A warning usually means part of an area couldn't be read, for example Defender for Office 365 policies on a tenant without that licence.

From a successful run, **Compare with live** opens the [compare](compare.md) page and **Browse and restore** opens the [restore](restore.md) page for that backup.

Run history is kept for as long as the policy keeps its backups.

{% include "../../../.gitbook/includes/feature-request.md" %}
