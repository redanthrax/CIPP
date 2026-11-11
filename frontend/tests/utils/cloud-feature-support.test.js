import { describe, it, expect } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'
import matrix from '../../src/data/cloudFeatureSupport.json'
import {
  filterCloudSupportedActions,
  findTenantCloud,
  getCloudSupportEntry,
  getGovernmentClouds,
  getUnsupportedClouds,
  getUnsupportedPage,
  isCloudSupported,
  withCloudSupport,
} from '../../src/utils/cloud-feature-support'

// redanthrax/CIPP#4: the support matrix and the helpers the UI gates on.
describe('cloudFeatureSupport.json', () => {
  it('is identical to the backend copy', () => {
    const frontend = fs.readFileSync(
      path.resolve(__dirname, '../../src/data/cloudFeatureSupport.json'),
      'utf8'
    )
    const backend = fs.readFileSync(
      path.resolve(
        __dirname,
        '../../../backend/Config/cloudFeatureSupport.json'
      ),
      'utf8'
    )
    expect(backend.replace(/\r\n/g, '\n')).toEqual(
      frontend.replace(/\r\n/g, '\n')
    )
  })

  it('never lists Commercial', () => {
    for (const section of [
      'pages',
      'actions',
      'standards',
      'baselineStandards',
      'alerts',
      'tests',
      'cacheTypes',
      'timers',
    ]) {
      for (const entry of matrix[section]) {
        expect(entry.unsupportedClouds).not.toContain('Commercial')
        expect(matrix.sources[entry.source]).toBeDefined()
      }
    }
  })
})

describe('isCloudSupported', () => {
  it('supports everything for Commercial and an unknown cloud', () => {
    expect(
      isCloudSupported('standards', 'TeamsGuestAccess', 'Commercial')
    ).toBe(true)
    expect(isCloudSupported('standards', 'TeamsGuestAccess', undefined)).toBe(
      true
    )
  })

  it('refuses listed features in the listed clouds only', () => {
    expect(isCloudSupported('standards', 'TeamsGuestAccess', 'USGovHigh')).toBe(
      false
    )
    expect(isCloudSupported('standards', 'TeamsGuestAccess', 'USGovDoD')).toBe(
      false
    )
    expect(isCloudSupported('standards', 'AuditLog', 'USGovHigh')).toBe(true)
    expect(getUnsupportedClouds('standards', 'AuditLog')).toEqual([])
  })

  it('returns the reason and evidence with an entry', () => {
    const entry = getCloudSupportEntry('actions', '/api/ExecSendPush')
    expect(entry.reason).toMatch(/MFA connector/)
    expect(entry.evidence).toMatch(/redanthrax\/CIPP#3/)
  })
})

describe('getUnsupportedPage', () => {
  it('matches a listed page and the pages under it, not a sibling with the same prefix', () => {
    expect(
      getUnsupportedPage('/security/compliance/dlp', 'USGovHigh')?.path
    ).toEqual('/security/compliance/dlp')
    expect(
      getUnsupportedPage('/security/compliance/dlp/', 'USGovHigh')?.path
    ).toEqual('/security/compliance/dlp')
    expect(
      getUnsupportedPage('/security/compliance/dlp/edit', 'USGovDoD')?.path
    ).toEqual('/security/compliance/dlp')
    expect(
      getUnsupportedPage('/security/compliance/dlp-templates', 'USGovHigh')
    ).toBeUndefined()
  })

  it('blocks nothing for Commercial or an unknown cloud', () => {
    expect(
      getUnsupportedPage('/security/compliance/dlp', 'Commercial')
    ).toBeUndefined()
    expect(
      getUnsupportedPage('/security/compliance/dlp', undefined)
    ).toBeUndefined()
  })
})

describe('withCloudSupport', () => {
  it('adds unsupportedClouds to listed pages and returns other items unchanged', () => {
    const plain = { title: 'Users', path: '/identity/administration/users' }
    const group = {
      title: 'Compliance',
      items: [{ title: 'DLP', path: '/security/compliance/dlp' }],
    }
    const untouched = { title: 'Identity', items: [plain] }
    const [outGroup, outUntouched] = withCloudSupport([group, untouched])
    expect(outGroup.items[0].unsupportedClouds).toEqual([
      'USGovHigh',
      'USGovDoD',
    ])
    expect(outUntouched).toBe(untouched)
    expect(group.items[0].unsupportedClouds).toBeUndefined()
  })
})

describe('filterCloudSupportedActions', () => {
  const actions = [
    { label: 'Send MFA Push', url: '/api/ExecSendPush' },
    { label: 'Reset Password', url: '/api/ExecResetPass' },
    { label: 'Link', link: '/somewhere' },
  ]

  it('returns the same array for Commercial and an unknown cloud', () => {
    expect(filterCloudSupportedActions(actions, 'Commercial')).toBe(actions)
    expect(filterCloudSupportedActions(actions, undefined)).toBe(actions)
    expect(filterCloudSupportedActions(undefined, 'USGovHigh')).toBeUndefined()
  })

  it('leaves out actions whose API the cloud does not support', () => {
    expect(
      filterCloudSupportedActions(actions, 'USGovHigh').map((a) => a.label)
    ).toEqual(['Reset Password', 'Link'])
  })

  it('returns the same array when nothing is removed', () => {
    const safe = actions.slice(1)
    expect(filterCloudSupportedActions(safe, 'USGovDoD')).toBe(safe)
  })
})

describe('tenant clouds', () => {
  const tenants = [
    { defaultDomainName: 'AllTenants', customerId: 'AllTenants' },
    {
      defaultDomainName: 'contoso.com',
      customerId: 'c1',
      initialDomainName: 'contoso.onmicrosoft.com',
      cloudEnvironment: 'Commercial',
    },
    {
      defaultDomainName: 'gov.us',
      customerId: 'g1',
      initialDomainName: 'gov.onmicrosoft.us',
      cloudEnvironment: 'USGovHigh',
    },
    { defaultDomainName: 'legacy.com', customerId: 'l1' },
    {
      defaultDomainName: 'odd.com',
      customerId: 'o1',
      cloudEnvironment: 'usgovhigh',
    },
  ]

  it('finds the selected tenant cloud by domain, id or initial domain', () => {
    expect(findTenantCloud(tenants, 'gov.us')).toEqual('USGovHigh')
    expect(findTenantCloud(tenants, 'g1')).toEqual('USGovHigh')
    expect(findTenantCloud(tenants, 'gov.onmicrosoft.us')).toEqual('USGovHigh')
    expect(findTenantCloud(tenants, 'contoso.com')).toEqual('Commercial')
  })

  it('returns no cloud for AllTenants, an unknown tenant, a tenant without a cloud, a miscased value or no list', () => {
    expect(findTenantCloud(tenants, 'AllTenants')).toBeUndefined()
    expect(findTenantCloud(tenants, 'nope.com')).toBeUndefined()
    expect(findTenantCloud(tenants, 'legacy.com')).toBeUndefined()
    expect(findTenantCloud(tenants, 'odd.com')).toBeUndefined()
    expect(findTenantCloud(undefined, 'gov.us')).toBeUndefined()
  })

  it('lists the government clouds present', () => {
    expect(getGovernmentClouds(tenants)).toEqual(['USGovHigh'])
    expect(getGovernmentClouds(tenants.slice(0, 2))).toEqual([])
    expect(getGovernmentClouds(undefined)).toEqual([])
  })
})
