---
icon: cloud-arrow-up
---

# Cloud Backup

Cloud Backup copies your tenants' Microsoft 365 configuration to storage you own, on a schedule you choose. Backups go to an Azure storage account or an Amazon S3 (or S3-compatible) bucket, so they stay available even if a tenant or CIPP itself is lost.

Each backup covers the settings of one tenant, split into areas:

* **Conditional Access**: policies, named locations, authentication strengths and authentication contexts.
* **Intune**: configuration, compliance, app protection, Endpoint Security and update policies, scripts, assignment filters and scope tags, including their assignments.
* **Exchange Online**: organisation settings, mail flow rules, connectors, domains, anti-spam, anti-phishing, anti-malware and Defender for Office 365 policies, mailbox settings and permissions, and distribution groups.
* **SharePoint**: tenant sharing settings and the list of sites with their sharing and storage settings.

Mailbox, OneDrive and SharePoint content is not backed up. You can [compare](compare.md) a backup with the tenant's current configuration or another backup, and [restore](restore.md) Conditional Access, Intune and Exchange Online settings to the same or another tenant. SharePoint settings can be compared but not restored.

## Getting started

1. Add a [destination](destinations.md): the storage account or bucket backups are written to.
2. Add a [policy](policies.md): which tenants and areas to back up, how often, and how long to keep backups.
3. Check the [runs](runs.md) to see each backup's result.
4. [Compare](compare.md) or [restore](restore.md) a backup when you need it.

## Overview

The Cloud Backup overview shows how many policies and destinations you have, how many tenants are covered, how many backups failed in the last 24 hours, and the total size of each tenant's latest backup. The table lists the latest backup for every tenant and policy, with its result.

{% include "../../../.gitbook/includes/feature-request.md" %}
