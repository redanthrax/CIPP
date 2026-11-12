# GCC High / DoD feature support

Some CIPP features call services that a government (GCC High or DoD) tenant cannot use. The request helpers refuse those calls for a government tenant before anything is sent ([endpoint routing](gcchigh-endpoint-audit.md), redanthrax/CIPP#3). This page describes how CIPP hides or skips those features so that the refusals do not show up as failing pages and repeated errors (redanthrax/CIPP#4).

None of this changes anything for a Commercial tenant. Every check returns early for Commercial, for AllTenants and when the tenant's cloud is unknown.

## The support matrix

The matrix lives in one file, `frontend/src/data/cloudFeatureSupport.json`. The backend reads an identical copy at `backend/Config/cloudFeatureSupport.json`. Edit the frontend copy and copy it over the backend one. `backend/Tests/Static/CloudFeatureSupportSync.Tests.ps1` fails if the copies differ.

Each section lists features by key, with the clouds they are unsupported in and a `source`:

| Section | Key | Used by |
| --- | --- | --- |
| `pages` | page path (also covers the pages under it) | Navigation, direct URL block |
| `actions` | API URL of a row/header action | `CippDataTable`, `HeaderedTabbedLayout` |
| `standards` | classic standard name | `Push-CIPPStandardsList`, `Push-CIPPStandard`, standards picker |
| `baselineStandards` | baseline definition name | `Invoke-CIPPBaselineStandard`, baseline picker |
| `alerts` | alert name (`Get-CIPPAlert<name>`) | `Push-ExecScheduledCommand` |
| `tests` | test id (`Invoke-CippTest<id>`) | `Invoke-CIPPTestCollection` |
| `cacheTypes` | cache type (`Set-CIPPDBCache<type>`) | `Invoke-CIPPDBCacheCollection`, `Push-ExecCIPPDBCache` |
| `timers` | timer step | `Start-AuditLogSearchCreationV2` |

`sources` gives each source's reason and evidence: a refusal from #3, or a Microsoft Graph page whose national cloud table says "global only". Only features backed by a refusal or a document are listed. A feature that only needs a licence is not listed, because `Test-CIPPStandardLicense` and the tenant capabilities already handle licences. Features that might be unsupported but are not proven are listed under `unverified` and are not gated.

`baselineStandards` and `tests` are derived lists. A baseline standard is listed when its executor, a `"compliance": true` step or its `read.cacheType` is unsupported. A test is listed when every cache type it reads is unsupported. The static test re-derives both lists and fails when a new definition is not in the matrix.

## Frontend

* **Selected tenant's cloud.** `useTenantCloudEnvironment()` reads `cloudEnvironment` from the tenant list the tenant selector already cached (query key `TenantSelector`). It reads the query cache directly (`useSyncExternalStore` on the cache's subscribe) and registers no query observer, so it does not fetch anything, never attaches an observer without a `queryFn` to the selector's query and re-renders only when that list changes. Until that list is cached, the cloud is unknown and nothing is gated.
* **Navigation.** `config.jsx` passes the menu through `withCloudSupport`, which adds `unsupportedClouds` to the pages the matrix lists. `filterMenuItems` hides a page when `unsupportedClouds` includes the `cloudEnvironment` option. You can also set `unsupportedClouds` on a nav item by hand.
* **Direct URL.** `Layout` shows "Not available for GCC High tenants" with the matrix reason instead of rendering the page. The page's own API calls never run.
* **Actions.** `CippDataTable` and `HeaderedTabbedLayout` drop actions whose `url` is listed.
* **Standards and baselines pickers.** A listed standard keeps its place in the picker and shows a "Not supported in GCC High" chip with a tooltip. Templates apply to many tenants, so the standard is still applied to commercial tenants. The chip only appears when the tenant list contains a tenant in that cloud.

## Backend

`Test-CIPPCloudFeatureSupport -TenantFilter <t> -Type <section> -Name <key>` returns `$false` only for a government tenant and a listed feature. It reads the tenant's cloud with `Get-CIPPTenantRequestCloud`, the same rule the request helpers route by. It returns `$true` when the cloud cannot be resolved, so the job runs exactly as before. It never logs. If the backend copy of the matrix is missing or is not valid JSON, `Get-CIPPCloudFeatureSupport` logs one error per process and gates nothing, so jobs run as before and the #3 refusals still stop unsupported calls; it never throws, and it never reads the file for a Commercial tenant. Each caller first checks that the tenant's cloud is not Commercial, so Commercial tenants never reach the matrix.

| Job | Government tenant |
| --- | --- |
| Classic standards | Removed from the run in `Push-CIPPStandardsList`, which sets the compare field to "Not supported for USGovHigh tenants." and writes one log line per tenant per run. `Push-CIPPStandard` also skips listed standards, without logging. |
| Baselines | The engine writes a `Skipped-Cloud` row with the reason before the licence check, and one log line per skipped standard per run, like a disabled standard. `Start-CIPPBaselineOrchestrator` is unchanged and does no cloud lookup. |
| Alerts | Recorded as `Skipped` in the alert run history, the task moves to its next slot, and one log line is written per run. |
| Tests | Removed from the suite, with one log line per tenant and suite run. |
| Cache collection | Removed from the collection, with one log line per tenant and collection run. |
| Audit log searches | Government tenants are left out of the 15-minute planner's fan-out, with one log line a day. |

## AllTenants

When gov and commercial tenants are mixed, a feature that fans out over tenants skips the government tenants and still runs for every commercial tenant. AllTenants standards, AllTenants alerts, the nightly cache and test runs, baselines and the audit log planner all work this way, because each of them checks the tenant it is running for.

In the UI, AllTenants has no single cloud, so nothing is hidden and no page is blocked. A government tenant's rows in an AllTenants report come back with the backend's refusal for that tenant, as they did before this change.

## Testing

* Pester: `Static/CloudFeatureSupportSync`, `GraphHelper/Test-CIPPCloudFeatureSupport`, and the `*.CloudSupport` / `BaselineEngineCloudSupport` tests. Each one checks that a Commercial tenant takes the unchanged path and that a government tenant is skipped with one log line.
* Vitest: `tests/utils/cloud-feature-support.test.js`, the `cloudEnvironment` cases in `tests/utils/filter-menu-items.test.js`, and `tests/components/CippComponents/CippCloudSupportChip.test.jsx`.
