import React from 'react'
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import router from 'next/router'
import { renderWithProviders } from '../test-utils'
import { api, getResult, postResult } from '../mocks/api-call'

vi.mock('../../src/api/ApiCall', async () =>
  (await import('../mocks/api-call')).apiCallMock()
)
const table = vi.hoisted(() => ({ props: null }))
vi.mock('../../src/components/CippComponents/CippTablePage.jsx', () => ({
  CippTablePage: (props) => {
    table.props = props
    return <div>{props.cardButton}</div>
  },
}))

import ListPage from '../../src/pages/cloud-backup/policies/index.jsx'
import AddPage from '../../src/pages/cloud-backup/policies/add.jsx'
import EditPage from '../../src/pages/cloud-backup/policies/edit.jsx'

const destinations = getResult({
  data: [{ Id: 'dest-1', Name: 'Azure prod', Location: 'cippbackups/config' }],
})
const noDestinations = getResult({ data: [] })
const tenants = getResult({
  data: [
    {
      defaultDomainName: 'AllTenants',
      displayName: '*All Tenants',
      customerId: 'AllTenants',
    },
    {
      defaultDomainName: 'contoso.com',
      displayName: 'Contoso',
      customerId: 'cid-contoso',
    },
  ],
})
const groups = getResult({
  data: { Results: [{ Id: 'grp-1', Name: 'Gold customers' }] },
})
const emptyGet = getResult()
const existingPolicy = getResult({
  data: [
    {
      Id: 'pol-1',
      Name: 'Nightly config',
      Enabled: true,
      DestinationId: 'dest-1',
      Tenants: [{ label: 'Gold customers', value: 'grp-1', type: 'Group' }],
      ConfigAreas: ['Intune', 'Exchange'],
      ConfigSchedule: '12h',
      RetentionDays: 30,
      Encryption: true,
    },
  ],
})

const routeGets = (destinationResult) => (opts) => {
  if (opts.url === '/api/ListCloudBackupDestinations') return destinationResult
  if (opts.url?.startsWith('/api/ListTenants')) return tenants
  if (opts.url === '/api/ListTenantGroups') return groups
  if (opts.url === '/api/ListCloudBackupPolicies') return existingPolicy
  return emptyGet
}

let post
beforeEach(() => {
  vi.clearAllMocks()
  post = postResult()
  api.post = () => post
  api.get = routeGets(destinations)
})

afterEach(() => {
  router.query = {}
})

const pickOption = async (user, combobox, option) => {
  await user.click(screen.getByRole('combobox', { name: combobox }))
  await user.click(await screen.findByRole('option', { name: option }))
}

describe('Cloud Backup policy form', () => {
  it('asks for a destination first when none exist', async () => {
    api.get = routeGets(noDestinations)
    renderWithProviders(<AddPage />)

    expect(
      await screen.findByText(/Add a destination first/)
    ).toBeInTheDocument()
    expect(
      screen.getByRole('link', { name: 'Add destination' })
    ).toHaveAttribute('href', '/cloud-backup/destinations/add')
    expect(
      screen.queryByRole('combobox', { name: 'Destination' })
    ).not.toBeInTheDocument()
  })

  it('defaults to a daily schedule kept for 90 days', async () => {
    renderWithProviders(<AddPage />)

    expect(
      await screen.findByRole('spinbutton', { name: /Keep backups for/ })
    ).toHaveValue(90)
    expect(screen.getByRole('combobox', { name: 'Schedule' })).toHaveValue(
      'Every day'
    )
    expect(screen.getByRole('switch', { name: 'Enabled' })).toBeChecked()
    expect(
      screen.getByRole('switch', { name: 'Encrypt backups' })
    ).not.toBeChecked()
  })

  it.each([
    ['5', 'Keep backups for at least 7 days'],
    ['4000', 'Keep backups for at most 3650 days (10 years)'],
    ['', 'Enter how many days to keep backups'],
  ])('rejects a retention of "%s" days', async (days, message) => {
    const user = userEvent.setup()
    renderWithProviders(<AddPage />)

    const retention = await screen.findByRole('spinbutton', {
      name: /Keep backups for/,
    })
    await user.clear(retention)
    if (days) await user.type(retention, days)

    expect(await screen.findByText(message)).toBeInTheDocument()
  })

  it('keeps Submit disabled until the required fields are filled', async () => {
    const user = userEvent.setup()
    renderWithProviders(<AddPage />)

    await user.type(
      await screen.findByRole('textbox', { name: 'Policy name' }),
      'Nightly'
    )
    expect(screen.getByRole('button', { name: 'Submit' })).toBeDisabled()
  })

  it('posts the Add action with plain values and the selector tenants', async () => {
    const user = userEvent.setup()
    renderWithProviders(<AddPage />)

    await user.type(
      await screen.findByRole('textbox', { name: 'Policy name' }),
      'Nightly'
    )
    await pickOption(user, 'Destination', 'Azure prod (cippbackups/config)')
    await pickOption(user, 'Tenants', 'Contoso (contoso.com)')
    await pickOption(user, 'What to back up', 'Conditional Access')
    await user.click(await screen.findByRole('option', { name: 'Intune' }))

    const submit = screen.getByRole('button', { name: 'Submit' })
    await waitFor(() => expect(submit).toBeEnabled())
    await user.click(submit)

    await waitFor(() => expect(post.mutate).toHaveBeenCalledTimes(1))
    const { url, data } = post.mutate.mock.calls[0][0]
    expect(url).toBe('/api/ExecCloudBackupPolicy')
    expect(data).toMatchObject({
      Action: 'Add',
      Name: 'Nightly',
      Enabled: true,
      DestinationId: 'dest-1',
      ConfigAreas: ['ConditionalAccess', 'Intune'],
      ConfigSchedule: '1d',
      RetentionDays: 90,
      Encryption: false,
    })
    expect(data.Tenants).toEqual([
      expect.objectContaining({
        label: 'Contoso (contoso.com)',
        value: 'contoso.com',
        type: 'Tenant',
      }),
    ])
  })

  it('loads an existing policy and posts the Edit action', async () => {
    const user = userEvent.setup()
    router.query = { id: 'pol-1' }
    renderWithProviders(<EditPage />)

    expect(
      await screen.findByDisplayValue('Nightly config')
    ).toBeInTheDocument()
    expect(
      screen.getByRole('spinbutton', { name: /Keep backups for/ })
    ).toHaveValue(30)
    expect(screen.getByText('Gold customers')).toBeInTheDocument()

    await user.clear(screen.getByRole('textbox', { name: 'Policy name' }))
    await user.type(
      screen.getByRole('textbox', { name: 'Policy name' }),
      'Twice daily'
    )
    const submit = screen.getByRole('button', { name: 'Submit' })
    await waitFor(() => expect(submit).toBeEnabled())
    await user.click(submit)

    await waitFor(() => expect(post.mutate).toHaveBeenCalledTimes(1))
    expect(post.mutate.mock.calls[0][0].data).toMatchObject({
      Action: 'Edit',
      Id: 'pol-1',
      Name: 'Twice daily',
      DestinationId: 'dest-1',
      Tenants: [{ label: 'Gold customers', value: 'grp-1', type: 'Group' }],
      ConfigAreas: ['Intune', 'Exchange'],
      ConfigSchedule: '12h',
      RetentionDays: 30,
      Encryption: true,
    })
  })
})

describe('Cloud Backup policies list', () => {
  const action = (label) =>
    table.props.actions.find((item) => item.label === label)

  it('lists policies without the selected tenant', () => {
    renderWithProviders(<ListPage />)

    expect(table.props.apiUrl).toBe('/api/ListCloudBackupPolicies')
    expect(table.props.queryKey).toBe('ListCloudBackupPolicies')
    expect(table.props.apiData).toEqual({
      tenantFilter: undefined,
      tenantGroup: undefined,
    })
    expect(screen.getByRole('link', { name: 'Add Policy' })).toHaveAttribute(
      'href',
      '/cloud-backup/policies/add'
    )
  })

  it('runs a policy now and refreshes the runs', () => {
    renderWithProviders(<ListPage />)

    const runNow = action('Run Backup Now')
    expect(runNow).toMatchObject({
      type: 'POST',
      url: '/api/ExecCloudBackupRun',
      data: { PolicyId: 'Id' },
    })
    expect(runNow.relatedQueryKeys).toContain('ListCloudBackupRuns*')
  })

  it('offers key rotation only for encrypted policies', () => {
    renderWithProviders(<ListPage />)

    const rotate = action('Rotate Encryption Key')
    expect(rotate.data).toEqual({ Action: '!RotateKey', Id: 'Id' })
    expect(rotate.condition({ Encryption: true })).toBe(true)
    expect(rotate.condition({ Encryption: false })).toBe(false)
  })

  it('deletes with a literal Delete action', () => {
    renderWithProviders(<ListPage />)

    expect(action('Delete Policy').data).toEqual({
      Action: '!Delete',
      Id: 'Id',
    })
    expect(action('Edit Policy').link).toBe(
      '/cloud-backup/policies/edit?id=[Id]'
    )
  })

  it('shows readable schedule and areas in the table rows', () => {
    renderWithProviders(<ListPage />)

    const row = table.props.dataMap({
      ConfigSchedule: '4h',
      ConfigAreas: ['ConditionalAccess', 'SharePoint'],
    })
    expect(row.Schedule).toBe('Every 4 hours')
    expect(row.Areas).toBe('Conditional Access, SharePoint')
  })

  it('describes the policy in the details drawer', () => {
    renderWithProviders(<ListPage />)
    const { getByText } = within(
      renderWithProviders(
        table.props.offCanvas.children({
          Id: 'pol-1',
          Name: 'Nightly config',
          Enabled: true,
          DestinationName: 'Azure prod',
          TenantSummary: 'All Tenants',
          ConfigAreas: ['Intune'],
          ConfigSchedule: '7d',
          RetentionDays: 365,
          Encryption: true,
          KeyCount: 2,
        })
      ).container
    )

    expect(getByText('Every week')).toBeInTheDocument()
    expect(getByText('365 days')).toBeInTheDocument()
    expect(getByText('On (2 keys)')).toBeInTheDocument()
    expect(getByText('Not run yet')).toBeInTheDocument()
  })
})
