import React from 'react'
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import router from 'next/router'
import { renderWithProviders } from '../test-utils'
import { api, getResult } from '../mocks/api-call'

vi.mock('../../src/api/ApiCall', async () =>
  (await import('../mocks/api-call')).apiCallMock()
)
const table = vi.hoisted(() => ({ props: null, dataTable: null }))
vi.mock('../../src/components/CippComponents/CippTablePage.jsx', () => ({
  CippTablePage: (props) => {
    table.props = props
    return <div>{props.tableFilter}</div>
  },
}))
vi.mock('../../src/components/CippTable/CippDataTable', () => ({
  CippDataTable: (props) => {
    table.dataTable = props
    return null
  },
}))

import RunsPage from '../../src/pages/cloud-backup/runs/index.jsx'
import OverviewPage from '../../src/pages/cloud-backup/overview/index.jsx'

const policies = getResult({
  data: [
    { Id: 'pol-1', Name: 'Nightly config' },
    { Id: 'pol-2', Name: 'Hourly CA' },
  ],
})
const emptyGet = getResult()

beforeEach(() => {
  vi.clearAllMocks()
  api.get = (opts) =>
    opts.url === '/api/ListCloudBackupPolicies' ? policies : emptyGet
})

afterEach(() => {
  router.query = {}
})

describe('Cloud Backup runs', () => {
  it('lists every policy run by default, without the selected tenant', () => {
    renderWithProviders(<RunsPage />)

    expect(table.props.apiUrl).toBe('/api/ListCloudBackupRuns')
    expect(table.props.apiData).toEqual({
      tenantFilter: undefined,
      tenantGroup: undefined,
      PolicyId: undefined,
    })
    expect(table.props.queryKey).toBe('ListCloudBackupRuns-all')
    expect(table.props.simpleColumns).toContain('CloudBackupStatus')
    expect(table.props.simpleColumns).toContain('CloudBackupSize')
    expect(
      table.props.dataMap({
        Id: 'run-1',
        Status: 'Succeeded',
        StartedAt: '2026-11-19T02:00:00Z',
        Bytes: 10,
      })
    ).toMatchObject({
      Id: 'run-1',
      Status: 'Succeeded',
      CloudBackupStatus: 'Succeeded',
      CloudBackupStartedAt: '2026-11-19T02:00:00Z',
      CloudBackupSize: 10,
    })
  })

  it('filters to the policy picked above the table', async () => {
    const user = userEvent.setup()
    renderWithProviders(<RunsPage />)

    await user.click(
      screen.getByRole('combobox', { name: 'Show runs for policy' })
    )
    await user.click(await screen.findByRole('option', { name: 'Hourly CA' }))

    await waitFor(() => expect(table.props.apiData.PolicyId).toBe('pol-2'))
    expect(table.props.queryKey).toBe('ListCloudBackupRuns-pol-2')
  })

  it('opens filtered when linked from a policy', async () => {
    router.query = { PolicyId: 'pol-1' }
    renderWithProviders(<RunsPage />)

    await waitFor(() => expect(table.props.apiData.PolicyId).toBe('pol-1'))
  })

  it('shows the per-area results and warnings of a run', () => {
    renderWithProviders(<RunsPage />)
    renderWithProviders(
      table.props.offCanvas.children({
        PolicyName: 'Nightly config',
        Tenant: 'contoso.com',
        Status: 'PartialSuccess',
        StartedAt: '2026-11-19T02:00:00Z',
        CompletedAt: '2026-11-19T02:03:05Z',
        DurationSeconds: 185,
        Items: 412,
        Bytes: 2621440,
        Location: 'pol-1/cid-contoso/config/20261119T020000Z/',
        Areas: JSON.stringify([
          {
            Area: 'ConditionalAccess',
            Items: 12,
            Bytes: 10240,
            Status: 'Succeeded',
          },
          {
            Area: 'Exchange',
            Items: 0,
            Bytes: 0,
            Status: 'Failed',
            Error: 'The tenant has no Exchange Online licence',
          },
        ]),
        Warnings: [
          'SafeLinksPolicy skipped: no Defender for Office 365 licence',
        ],
      })
    )

    expect(screen.getByText('Partial success')).toBeInTheDocument()
    expect(screen.getByText('2.5 MB')).toBeInTheDocument()
    expect(screen.getByText('3 min 5 s')).toBeInTheDocument()
    expect(screen.getByText('Conditional Access')).toBeInTheDocument()
    expect(screen.getByText('10.0 KB')).toBeInTheDocument()
    expect(
      screen.getByText('The tenant has no Exchange Online licence')
    ).toBeInTheDocument()
    expect(
      screen.getByText(
        'SafeLinksPolicy skipped: no Defender for Office 365 licence'
      )
    ).toBeInTheDocument()
  })

  it('links a finished run to compare and restore', () => {
    renderWithProviders(<RunsPage />)
    const [compare, restore] = table.props.actions

    expect(compare.link).toBe('/cloud-backup/compare?RunId=[Id]')
    expect(restore.link).toBe('/cloud-backup/restore?RunId=[Id]')
    expect(restore.condition({ Status: 'PartialSuccess' })).toBe(true)
    expect(restore.condition({ Status: 'Failed' })).toBe(false)
    expect(compare.condition({ Status: 'Running' })).toBe(false)
  })

  it('reports a run that is still going', () => {
    renderWithProviders(<RunsPage />)
    expect(
      table.props.dataMap({ Status: 'Running', DurationSeconds: null }).Duration
    ).toBe('Still running')
  })
})

describe('Cloud Backup overview', () => {
  const overview = (data) => {
    const result = getResult({ data })
    api.get = () => result
  }

  it('shows the totals and the latest run per tenant', () => {
    const latestRuns = [
      {
        PolicyId: 'pol-1',
        PolicyName: 'Nightly config',
        Tenant: 'contoso.com',
        Status: 'Succeeded',
        CompletedAt: '2026-11-19T02:03:05Z',
        Items: 412,
        Bytes: 2621440,
      },
    ]
    overview({
      Policies: 3,
      EnabledPolicies: 2,
      Destinations: 1,
      TenantsCovered: 41,
      Failures24h: 0,
      LatestBytes: 1073741824,
      LatestRuns: latestRuns,
    })
    renderWithProviders(<OverviewPage />)

    expect(screen.getByText('41')).toBeInTheDocument()
    expect(screen.getByText('1.0 GB')).toBeInTheDocument()
    expect(table.dataTable.data).toEqual([
      {
        ...latestRuns[0],
        CloudBackupStatus: 'Succeeded',
        CloudBackupStartedAt: undefined,
        CloudBackupCompletedAt: '2026-11-19T02:03:05Z',
        CloudBackupSize: 2621440,
      },
    ])
    expect(
      screen.queryByText(/Start by adding a destination/)
    ).not.toBeInTheDocument()
  })

  it('points a new install at adding a destination', () => {
    overview({
      Policies: 0,
      EnabledPolicies: 0,
      Destinations: 0,
      LatestRuns: [],
    })
    renderWithProviders(<OverviewPage />)

    expect(
      screen.getByText(/Start by adding a destination/)
    ).toBeInTheDocument()
    expect(
      screen.getByRole('link', { name: 'Add destination' })
    ).toHaveAttribute('href', '/cloud-backup/destinations/add')
  })

  it('points at adding a policy once a destination exists', () => {
    overview({
      Policies: 0,
      EnabledPolicies: 0,
      Destinations: 1,
      LatestRuns: [],
    })
    renderWithProviders(<OverviewPage />)

    expect(screen.getByRole('link', { name: 'Add policy' })).toHaveAttribute(
      'href',
      '/cloud-backup/policies/add'
    )
  })
})
