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
const ui = vi.hoisted(() => ({ tables: {}, dialog: null }))
vi.mock('../../src/components/CippTable/CippDataTable', () => ({
  CippDataTable: (props) => {
    ui.tables[props.title] = props
    return <div data-testid={`table-${props.title}`} />
  },
}))
vi.mock('../../src/components/CippComponents/CippApiDialog', () => ({
  CippApiDialog: (props) => {
    ui.dialog = props
    return props.createDialog.open ? (
      <div role="dialog">
        <h2>{props.title}</h2>
        {props.api.confirmText}
      </div>
    ) : null
  },
}))
vi.mock('../../src/components/CippComponents/CippFormTenantSelector', () => ({
  CippFormTenantSelector: ({ formControl, name }) => (
    <button
      type="button"
      onClick={() =>
        formControl.setValue(name, {
          label: 'Fabrikam (fabrikam.com)',
          value: 'cid-fabrikam',
        })
      }
    >
      Pick Fabrikam
    </button>
  ),
}))

import RestorePage from '../../src/pages/cloud-backup/restore/index.jsx'

const RUN_ID = '11111111-1111-1111-1111-111111111111_0001'
const run = {
  Id: RUN_ID,
  PolicyId: '11111111-1111-1111-1111-111111111111',
  Tenant: 'contoso.com',
  TenantId: 'cid-contoso',
  Status: 'Succeeded',
  StartedAt: '2026-11-19T02:00:00Z',
}
const snapshotRows = [
  {
    Area: 'ConditionalAccess',
    Section: 'policies',
    SectionLabel: 'Policies',
    Key: 'ca-1',
    Name: 'Require MFA',
    Item: { id: 'ca-1', displayName: 'Require MFA' },
  },
  {
    Area: 'Intune',
    Section: 'deviceConfigurations',
    SectionLabel: 'Device configurations',
    Key: 'dc-1',
    Name: 'Wi-Fi',
    Item: { id: 'dc-1' },
  },
  {
    Area: 'SharePoint',
    Section: 'tenantSettings',
    SectionLabel: 'Tenant settings',
    Key: 'tenantSettings',
    Name: 'tenantSettings',
    Item: {},
  },
]
const completedPreview = {
  Id: 'job-1',
  Type: 'RestorePreview',
  Status: 'Completed',
  TargetTenant: 'contoso.com',
  Summary: { Create: 1, Update: 2, CreateCopy: 0, Skip: 4, NotRestorable: 1 },
  Result: [
    {
      Area: 'ConditionalAccess',
      Section: 'policies',
      SectionLabel: 'Policies',
      Key: 'ca-1',
      Name: 'Require MFA',
      Action: 'Update',
      Status: 'Planned',
      Unmapped: ["Group 'Sales' not found in the target"],
      Differences: [
        { Path: 'state', Reference: 'enabled', Difference: 'disabled' },
      ],
    },
  ],
}

const results = {
  policies: getResult({
    data: [{ Id: run.PolicyId, Name: 'Nightly config' }],
  }),
  runs: getResult({ data: [run] }),
  snapshot: getResult({ data: snapshotRows }),
  empty: getResult(),
}
let me
let jobs

const setPermissions = (permissions) => {
  me = getResult({
    data: { clientPrincipal: { userRoles: ['editor'] }, permissions },
  })
}

beforeEach(() => {
  vi.clearAllMocks()
  ui.tables = {}
  ui.dialog = null
  setPermissions(['CIPP.CloudBackup.Read', 'CIPP.CloudBackupRestore.ReadWrite'])
  jobs = {}
  api.post = postResult()
  api.get = (opts) => {
    if (opts.url === '/api/me') return me
    if (opts.url === '/api/ListCloudBackupPolicies') return results.policies
    if (opts.url === '/api/ListCloudBackupRuns')
      return opts.data?.PolicyId ? results.runs : results.empty
    if (opts.url === '/api/ListCloudBackupSnapshot')
      return opts.waiting ? results.snapshot : results.empty
    if (opts.url === '/api/ListCloudBackupJobs')
      return jobs[opts.data?.Id] ?? results.empty
    return results.empty
  }
  router.query = { RunId: RUN_ID }
})

afterEach(() => {
  router.query = {}
})

const renderLoaded = async () => {
  renderWithProviders(<RestorePage />)
  await waitFor(() =>
    expect(ui.tables['Backup contents']?.data).toHaveLength(3)
  )
}

const startPreview = async (user, jobId = 'job-1') => {
  await user.click(screen.getByRole('button', { name: 'Preview restore' }))
  const [payload, options] = api.post.mutate.mock.calls.at(-1)
  act(() => options.onSuccess({ data: { JobId: jobId } }))
  return payload
}

describe('Cloud Backup restore', () => {
  it('opens the backup linked from the runs page and lists its items', async () => {
    await renderLoaded()

    expect(ApiGetCall).toHaveBeenCalledWith(
      expect.objectContaining({
        url: '/api/ListCloudBackupSnapshot',
        data: { RunId: RUN_ID },
      })
    )
    const table = ui.tables['Backup contents']
    expect(table.data[0]).toMatchObject({
      Name: 'Require MFA',
      Area: 'Conditional Access',
      Section: 'Policies',
    })
    expect(table.offCanvasOnRowClick).toBe(true)
    expect(table.offCanvas.title).toBe('Backup Item Details')
    expect(typeof table.onChange).toBe('function')
  })

  it('defaults to skipping existing items and keeping the backed-up CA state', async () => {
    await renderLoaded()

    expect(
      screen.getByRole('radio', { name: 'Skip items that already exist' })
    ).toBeChecked()
    expect(
      screen.getByRole('radio', { name: 'Keep the state from the backup' })
    ).toBeChecked()
    expect(
      screen.queryByText(/restoring to a different tenant/)
    ).not.toBeInTheDocument()
  })

  it('switches the CA state to report-only and warns for another tenant', async () => {
    const user = userEvent.setup()
    await renderLoaded()

    await user.click(screen.getByRole('button', { name: 'Pick Fabrikam' }))

    await waitFor(() =>
      expect(screen.getByRole('radio', { name: 'Report-only' })).toBeChecked()
    )
    expect(
      screen.getByText(/restoring to a different tenant/)
    ).toBeInTheDocument()
  })

  it('previews only the selected items in the chosen areas', async () => {
    const user = userEvent.setup()
    await renderLoaded()

    const [caRow, , spoRow] = ui.tables['Backup contents'].data
    act(() => ui.tables['Backup contents'].onChange([caRow, spoRow]))
    const payload = await startPreview(user)

    expect(payload).toEqual({
      url: '/api/ExecCloudBackupRestore',
      data: {
        RunId: RUN_ID,
        TargetTenant: 'cid-contoso',
        Areas: ['ConditionalAccess', 'Intune'],
        Items: [
          { Area: 'ConditionalAccess', Section: 'policies', Key: 'ca-1' },
        ],
        ConflictAction: 'Skip',
        CAState: 'AsBackedUp',
        Mode: 'Preview',
      },
    })
  })

  it('polls the preview while it runs and offers no restore yet', async () => {
    const user = userEvent.setup()
    jobs['job-1'] = getResult({ data: { Id: 'job-1', Status: 'Running' } })
    await renderLoaded()

    await startPreview(user)

    expect(
      await screen.findByText(/Comparing the backup with the target tenant/)
    ).toBeInTheDocument()
    const jobCall = ApiGetCall.mock.calls
      .map(([opts]) => opts)
      .find((opts) => opts.data?.Id === 'job-1')
    expect(
      jobCall.refetchInterval({ state: { data: { Status: 'Running' } } })
    ).toBe(3000)
    expect(
      jobCall.refetchInterval({ state: { data: { Status: 'Queued' } } })
    ).toBe(3000)
    expect(
      jobCall.refetchInterval({ state: { data: { Status: 'Completed' } } })
    ).toBe(false)
    expect(
      jobCall.refetchInterval({ state: { data: { Status: 'Failed' } } })
    ).toBe(false)
    expect(
      screen.queryByRole('button', { name: /^Restore \d/ })
    ).not.toBeInTheDocument()
  })

  it('shows the preview and confirms the restore with the target and counts', async () => {
    const user = userEvent.setup()
    jobs['job-1'] = getResult({ data: completedPreview })
    await renderLoaded()

    const preview = await startPreview(user)
    const previewTable = await waitFor(() => {
      expect(ui.tables['Restore preview']).toBeDefined()
      return ui.tables['Restore preview']
    })
    expect(previewTable.data[0]).toMatchObject({
      Name: 'Require MFA',
      Action: 'Overwrite',
      Changes: 1,
      NotFoundInTarget: 1,
    })
    expect(previewTable.offCanvasOnRowClick).toBe(true)

    await user.click(screen.getByRole('button', { name: 'Restore 3 items' }))
    const dialog = screen.getByRole('dialog')
    expect(dialog).toHaveTextContent('Restore to contoso.com')
    expect(dialog).toHaveTextContent(
      '1 new, 2 overwritten and 0 created as copies'
    )
    expect(dialog).toHaveTextContent('4 skipped and 1 cannot be restored')
    expect(dialog).not.toHaveTextContent('a different tenant')

    expect(ui.dialog.api.customDataformatter()).toEqual({
      ...preview.data,
      Mode: 'Apply',
      PreviewJobId: 'job-1',
    })

    jobs['job-2'] = getResult({
      data: {
        Id: 'job-2',
        Type: 'Restore',
        Status: 'Completed',
        Summary: { Succeeded: 3, Failed: 0, Skip: 4 },
        Result: [{ ...completedPreview.Result[0], Status: 'Succeeded' }],
      },
    })
    act(() =>
      ui.dialog.dialogAfterEffect({ Results: 'Queued', JobId: 'job-2' })
    )

    await waitFor(() => expect(ui.tables['Restore results']).toBeDefined())
    expect(ui.tables['Restore results'].simpleColumns).toContain(
      'CloudBackupStatus'
    )
    expect(screen.getByText('3 restored, 4 skipped')).toBeInTheDocument()
  })

  it('warns in the confirmation when restoring to another tenant', async () => {
    const user = userEvent.setup()
    jobs['job-1'] = getResult({
      data: { ...completedPreview, TargetTenant: 'fabrikam.com' },
    })
    await renderLoaded()
    await user.click(screen.getByRole('button', { name: 'Pick Fabrikam' }))

    await startPreview(user)
    await user.click(
      await screen.findByRole('button', { name: 'Restore 3 items' })
    )

    const dialog = screen.getByRole('dialog')
    expect(dialog).toHaveTextContent('Restore to fabrikam.com')
    expect(dialog).toHaveTextContent(
      'This backup is from contoso.com, a different tenant'
    )
  })

  it('asks for a new preview when the options change after it', async () => {
    const user = userEvent.setup()
    jobs['job-1'] = getResult({ data: completedPreview })
    await renderLoaded()
    await startPreview(user)
    await screen.findByRole('button', { name: 'Restore 3 items' })

    await user.click(
      screen.getByRole('radio', { name: 'Overwrite items that already exist' })
    )

    expect(screen.getByText(/changed after this preview/)).toBeInTheDocument()
    expect(
      screen.queryByRole('button', { name: 'Restore 3 items' })
    ).not.toBeInTheDocument()
  })

  it('lets users without the restore permission browse only', async () => {
    setPermissions(['CIPP.CloudBackup.Read'])
    await renderLoaded()

    expect(
      screen.getByText(/restoring needs the Cloud Backup restore permission/)
    ).toBeInTheDocument()
    expect(
      screen.queryByRole('button', { name: 'Preview restore' })
    ).not.toBeInTheDocument()
  })

  it('reopens a saved restore from the history page', async () => {
    router.query = { JobId: 'job-2' }
    jobs['job-2'] = getResult({
      data: {
        Id: 'job-2',
        Type: 'Restore',
        Status: 'Completed',
        SourceTenant: 'contoso.com',
        TargetTenant: 'contoso.com',
        Summary: { Succeeded: 1, Failed: 1 },
        Result: [
          {
            ...completedPreview.Result[0],
            Status: 'Failed',
            Message: 'Forbidden',
          },
        ],
      },
    })
    renderWithProviders(<RestorePage />)

    expect(await screen.findByText('1 restored, 1 failed')).toBeInTheDocument()
    expect(ui.tables['Restore results'].data[0]).toMatchObject({
      CloudBackupStatus: 'Failed',
      Message: 'Forbidden',
    })
  })
})
