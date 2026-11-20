import React from 'react'
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { act, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import router from 'next/router'
import { renderWithProviders } from '../test-utils'
import { api, getResult, postResult } from '../mocks/api-call'
import { ApiGetCall } from '../../src/api/ApiCall'

vi.mock('../../src/api/ApiCall', async () =>
  (await import('../mocks/api-call')).apiCallMock()
)
const ui = vi.hoisted(() => ({ tables: {} }))
vi.mock('../../src/components/CippTable/CippDataTable', () => ({
  CippDataTable: (props) => {
    ui.tables[props.title] = props
    return null
  },
}))

import ComparePage from '../../src/pages/cloud-backup/compare/index.jsx'

const POLICY_ID = '22222222-2222-2222-2222-222222222222'
const RUN_ID = `${POLICY_ID}_0002`
const OLDER_RUN_ID = `${POLICY_ID}_0009`
const run = {
  Id: RUN_ID,
  PolicyId: POLICY_ID,
  Tenant: 'contoso.com',
  TenantId: 'cid-contoso',
  Status: 'PartialSuccess',
  StartedAt: '2026-11-19T02:00:00Z',
  Areas: [
    { Area: 'ConditionalAccess', Status: 'Succeeded' },
    { Area: 'SharePoint', Status: 'Succeeded' },
  ],
}
const olderRun = {
  ...run,
  Id: OLDER_RUN_ID,
  Status: 'Succeeded',
  StartedAt: '2026-11-12T02:00:00Z',
}
const failedRun = { ...run, Id: `${POLICY_ID}_0005`, Status: 'Failed' }
const completedCompare = {
  Id: 'job-c',
  Type: 'Compare',
  Status: 'Completed',
  SourceTenant: 'contoso.com',
  Summary: {
    ConditionalAccess: { Added: 1, Removed: 0, Changed: 2, Unchanged: 7 },
  },
  Result: [
    {
      Area: 'ConditionalAccess',
      Section: 'policies',
      SectionLabel: 'Policies',
      Key: 'ca-1',
      Name: 'Require MFA',
      Change: 'Changed',
      Differences: [
        {
          Path: 'conditions.users.includeGroups',
          Reference: ['g1'],
          Difference: ['g2'],
        },
        {
          Path: 'assignments[1].target.filterType',
          Reference: 'include',
          Difference: null,
        },
        {
          Path: 'grantControls',
          Reference: { operator: 'OR' },
          Difference: [],
        },
        { Path: 'state', Reference: true, Difference: 42 },
      ],
    },
    {
      Area: 'ConditionalAccess',
      Section: 'policies',
      SectionLabel: 'Policies',
      Key: 'ca-9',
      Name: 'Block legacy auth',
      Change: 'Added',
      Differences: [],
    },
  ],
}

const results = {
  policies: getResult({ data: [{ Id: POLICY_ID, Name: 'Nightly config' }] }),
  runs: getResult({ data: [run, olderRun, failedRun] }),
  empty: getResult(),
}
let jobs

beforeEach(() => {
  vi.clearAllMocks()
  ui.tables = {}
  jobs = {}
  api.post = postResult()
  api.get = (opts) => {
    if (opts.url === '/api/ListCloudBackupPolicies') return results.policies
    if (opts.url === '/api/ListCloudBackupRuns')
      return opts.data?.PolicyId ? results.runs : results.empty
    if (opts.url === '/api/ListCloudBackupJobs')
      return jobs[opts.data?.Id] ?? results.empty
    return results.empty
  }
  router.query = { RunId: RUN_ID }
})

afterEach(() => {
  router.query = {}
})

const Harness = () => {
  const [, setTick] = React.useState(0)
  return (
    <>
      <button type="button" onClick={() => setTick((tick) => tick + 1)}>
        Re-render
      </button>
      <ComparePage />
    </>
  )
}

const compareButton = () => screen.getByRole('button', { name: 'Compare' })

describe('Cloud Backup compare', () => {
  it('compares the linked backup with the current configuration by default', async () => {
    const user = userEvent.setup()
    renderWithProviders(<ComparePage />)

    await waitFor(() => expect(compareButton()).toBeEnabled())
    expect(
      screen.getByRole('radio', { name: 'Current tenant configuration' })
    ).toBeChecked()
    await user.click(compareButton())

    expect(api.post.mutate.mock.calls[0][0]).toEqual({
      url: '/api/ExecCloudBackupCompare',
      data: {
        RunId: RUN_ID,
        CompareTo: 'Live',
        Areas: ['ConditionalAccess', 'SharePoint'],
      },
    })
  })

  it('compares with another backup picked from the list', async () => {
    const user = userEvent.setup()
    renderWithProviders(<ComparePage />)
    await waitFor(() => expect(compareButton()).toBeEnabled())

    await user.click(screen.getByRole('radio', { name: 'Another backup' }))
    expect(compareButton()).toBeDisabled()
    await user.click(screen.getAllByRole('combobox', { name: 'Policy' })[1])
    await user.click(
      await screen.findByRole('option', { name: 'Nightly config' })
    )
    await user.click(screen.getByRole('combobox', { name: 'Other backup' }))
    const options = await screen.findAllByRole('option')
    expect(options).toHaveLength(2)
    await user.click(
      options.find((option) => !option.textContent.includes('(partial)'))
    )

    await waitFor(() => expect(compareButton()).toBeEnabled())
    await user.click(compareButton())
    expect(api.post.mutate.mock.calls[0][0].data.CompareTo).toBe(OLDER_RUN_ID)
  })

  it('polls the comparison and then shows the summary and changed items', async () => {
    const user = userEvent.setup()
    jobs['job-c'] = getResult({ data: { Id: 'job-c', Status: 'Queued' } })
    renderWithProviders(<Harness />)
    await waitFor(() => expect(compareButton()).toBeEnabled())
    await user.click(compareButton())
    act(() =>
      api.post.mutate.mock.calls[0][1].onSuccess({ data: { JobId: 'job-c' } })
    )

    expect(await screen.findByText(/Waiting to start/)).toBeInTheDocument()
    const jobCall = ApiGetCall.mock.calls
      .map(([opts]) => opts)
      .find((opts) => opts.data?.Id === 'job-c')
    expect(jobCall.queryKey).toBe('ListCloudBackupJobs-job-job-c')
    expect(
      jobCall.refetchInterval({ state: { data: { Status: 'Queued' } } })
    ).toBe(3000)

    jobs['job-c'] = getResult({ data: completedCompare })
    await user.click(screen.getByRole('button', { name: 'Re-render' }))

    expect(await screen.findByText('Summary per area')).toBeInTheDocument()
    expect(screen.getByText('7')).toBeInTheDocument()
    const table = ui.tables.Differences
    expect(table.offCanvasOnRowClick).toBe(true)
    expect(table.data.map((row) => row.Change)).toEqual([
      'Changed',
      'Only in current',
    ])

    renderWithProviders(table.offCanvas.children(table.data[0]))
    expect(
      screen.getByText('conditions.users.includeGroups')
    ).toBeInTheDocument()
    expect(screen.getByText('["g1"]')).toBeInTheDocument()
    expect(screen.getByText('["g2"]')).toBeInTheDocument()
    expect(
      screen.getByText('assignments[1].target.filterType')
    ).toBeInTheDocument()
    expect(screen.getByText('{"operator":"OR"}')).toBeInTheDocument()
    expect(screen.getAllByText('-')).toHaveLength(2)
    expect(screen.getByText('true')).toBeInTheDocument()
    expect(screen.getByText('42')).toBeInTheDocument()
  })

  it('reports a failed comparison in plain words', async () => {
    router.query = { JobId: 'job-f' }
    jobs['job-f'] = getResult({
      data: {
        Id: 'job-f',
        Type: 'Compare',
        Status: 'Failed',
        Error: 'The destination could not be reached',
      },
    })
    renderWithProviders(<ComparePage />)

    expect(
      await screen.findByText(
        'The job failed: The destination could not be reached'
      )
    ).toBeInTheDocument()
  })

  it('reopens a saved comparison with another backup', async () => {
    router.query = { JobId: 'job-c' }
    jobs['job-c'] = getResult({
      data: { ...completedCompare, CompareToRunId: OLDER_RUN_ID },
    })
    renderWithProviders(<ComparePage />)

    expect(await screen.findByText('Another backup')).toBeInTheDocument()
    expect(ui.tables.Differences.data[1].Change).toBe('Only in other backup')
  })
})
