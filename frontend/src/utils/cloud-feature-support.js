// Features a tenant's Microsoft cloud does not support (redanthrax/CIPP#4). The matrix in
// src/data/cloudFeatureSupport.json is the same file the backend reads (backend/Config), kept identical
// by backend/Tests/Static/CloudFeatureSupportSync.Tests.ps1. Commercial is never listed, so every
// helper here is a no-op for Commercial tenants, for AllTenants and when the cloud is unknown.
import matrix from '../data/cloudFeatureSupport.json'
import { getCloudEnvironment } from './cloud-environments'

const SECTIONS = [
  'pages',
  'actions',
  'standards',
  'baselineStandards',
  'alerts',
  'tests',
  'cacheTypes',
  'timers',
]

const keyOf = (entry) => entry.name ?? entry.path ?? entry.url

const index = Object.fromEntries(
  SECTIONS.map((section) => [
    section,
    new Map((matrix[section] ?? []).map((entry) => [keyOf(entry), entry])),
  ])
)

// The clouds a feature is not supported in; [] when the matrix does not list it.
export const getUnsupportedClouds = (type, name) =>
  index[type]?.get(name)?.unsupportedClouds ?? []

// The matrix entry with its source's reason and evidence, or undefined.
export const getCloudSupportEntry = (type, name) => {
  const entry = index[type]?.get(name)
  if (!entry) return undefined
  return { ...entry, ...(matrix.sources?.[entry.source] ?? {}) }
}

// True unless `cloud` is a government cloud the feature is listed as unsupported in.
export const isCloudSupported = (type, name, cloud) =>
  !cloud ||
  cloud === 'Commercial' ||
  !getUnsupportedClouds(type, name).includes(cloud)

// A page and the pages under it share its entry: /teams-share/teams/business-voice also covers
// /teams-share/teams/business-voice/<anything>, but not /teams-share/teams/business-voice-x.
export const getUnsupportedPage = (pathname, cloud) => {
  if (!pathname || !cloud || cloud === 'Commercial') return undefined
  const path = pathname.length > 1 ? pathname.replace(/\/+$/, '') : pathname
  for (const [pagePath, entry] of index.pages) {
    if (
      (path === pagePath || path.startsWith(`${pagePath}/`)) &&
      entry.unsupportedClouds.includes(cloud)
    ) {
      return getCloudSupportEntry('pages', pagePath)
    }
  }
  return undefined
}

// Copies the matrix's page entries onto nav items as `unsupportedClouds`, which filterMenuItems
// reads. Items the matrix does not list are returned as they are (same object).
export const withCloudSupport = (items) =>
  items.map((item) => {
    let next = item
    if (item.items?.length) {
      const children = withCloudSupport(item.items)
      if (children.some((child, i) => child !== item.items[i]))
        next = { ...next, items: children }
    }
    const clouds = item.path ? getUnsupportedClouds('pages', item.path) : []
    if (clouds.length > 0) {
      next = {
        ...next,
        unsupportedClouds: [
          ...new Set([...(item.unsupportedClouds ?? []), ...clouds]),
        ],
      }
    }
    return next
  })

// Row/bulk actions whose API the tenant's cloud does not support are left out. Returns the same
// array when nothing is removed, so Commercial callers see no change at all.
export const filterCloudSupportedActions = (actions, cloud) => {
  if (!Array.isArray(actions) || !cloud || cloud === 'Commercial')
    return actions
  const filtered = actions.filter((action) => {
    const url =
      typeof action?.url === 'string' ? action.url.split('?')[0] : undefined
    return !url || isCloudSupported('actions', url, cloud)
  })
  return filtered.length === actions.length ? actions : filtered
}

// The government clouds present in a tenant list (the ListTenants response), e.g. ['USGovHigh'].
export const getGovernmentClouds = (tenants) =>
  Array.isArray(tenants)
    ? [
        ...new Set(
          tenants
            .map((tenant) => getCloudEnvironment(tenant?.cloudEnvironment))
            .filter((cloud) => cloud?.isGovernment)
            .map((cloud) => cloud.value)
        ),
      ]
    : []

// Finds a tenant in the ListTenants response the way the tenant selector does.
export const findTenantCloud = (tenants, tenant) => {
  if (!Array.isArray(tenants) || !tenant || tenant === 'AllTenants')
    return undefined
  const match =
    tenants.find(({ defaultDomainName }) => defaultDomainName === tenant) ||
    tenants.find(({ customerId }) => customerId === tenant) ||
    tenants.find(({ initialDomainName }) => initialDomainName === tenant)
  return getCloudEnvironment(match?.cloudEnvironment)?.value
}

export const cloudLabel = (cloud) => getCloudEnvironment(cloud)?.label ?? cloud
