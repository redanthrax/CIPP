# Restore & Compare History

Every comparison, restore preview and restore is listed here, newest first. You only see jobs for tenants you have access to. Jobs are kept for 30 days.

## Table Details

| Column | Description |
| --- | --- |
| Requested At | When the job was started. |
| Job | **Compare**, **Restore preview** or **Restore**. |
| Status | **Queued**, **Running**, **Completed** or **Failed**. |
| Source Tenant | The tenant the backup came from. |
| Target Tenant | The tenant restored to, or compared with. |
| Requested By | The CIPP user who started the job. |
| Result | A short count of the outcome, for example "4 restored, 1 failed". |

Click a job to see its details, then **View Results** to reopen the full results on the [Compare](compare.md) or [Restore](restore.md) page. A saved preview can't be used to restore: open the backup and run a new preview.

{% include "../../../.gitbook/includes/feature-request.md" %}
