import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { screen } from '@testing-library/react'
import { renderWithProviders } from '../test-utils'
import { api, getResult } from '../mocks/api-call'

vi.mock('../../src/api/ApiCall', async () =>
  (await import('../mocks/api-call')).apiCallMock()
)
const table = vi.hoisted(() => ({ props: null }))
vi.mock('../../src/components/CippComponents/CippTablePage.jsx', () => ({
  CippTablePage: (props) => {
    table.props = props
    return null
  },
}))

import JobsPage from '../../src/pages/cloud-backup/jobs/index.jsx'
import { nativeMenuItems } from '../../src/layouts/config'

beforeEach(() => {
  vi.clearAllMocks()
  api.get = getResult()
})

const compareJob = {
  Id: 'job-c',
  Type: 'Compare',
  Status: 'Completed',
  SourceTenant: 'contoso.com',
  CreatedAt: '2026-11-19T02:00:00Z',
  Summary: '{"Intune":{"Added":0,"Removed":2,"Changed":1,"Unchanged":9}}',
}
const restoreJob = {
  Id: 'job-r',
  Type: 'Restore',
  Status: 'Completed',
  SourceTenant: 'contoso.com',
  TargetTenant: 'fabrikam.com',
  RequestedBy: 'tech@msp.example',
  Summary: { Succeeded: 4, Failed: 1, Skip: 2 },
}

describe('Cloud Backup restore and compare history', () => {
  it('lists every job without the selected tenant and opens details on row click', () => {
    renderWithProviders(<JobsPage />)

    expect(table.props.apiUrl).toBe('/api/ListCloudBackupJobs')
    expect(table.props.apiData).toEqual({
      tenantFilter: undefined,
      tenantGroup: undefined,
    })
    expect(table.props.offCanvasOnRowClick).toBe(true)
    expect(table.props.offCanvas.title).toBe('Job Details')
    expect(table.props.simpleColumns).toEqual([
      'RequestedAt',
      'Job',
      'CloudBackupStatus',
      'SourceTenant',
      'TargetTenant',
      'RequestedBy',
      'Result',
    ])
  })

  it('summarises each job in plain words', () => {
    renderWithProviders(<JobsPage />)
    const { dataMap } = table.props

    expect(dataMap(compareJob)).toMatchObject({
      Job: 'Compare',
      RequestedAt: compareJob.CreatedAt,
      Result: '1 changed, 2 only in backup',
    })
    expect(dataMap(restoreJob).Result).toBe('4 restored, 1 failed, 2 skipped')
    expect(
      dataMap({ ...restoreJob, Type: 'RestorePreview', Summary: { Create: 3 } })
    ).toMatchObject({ Job: 'Restore preview', Result: '3 to create' })
  })

  it('links each job to the page that shows its results', () => {
    renderWithProviders(<JobsPage />)
    const [compareLink, restoreLink] = table.props.actions

    expect(compareLink.link).toBe('/cloud-backup/compare?JobId=[Id]')
    expect(compareLink.condition(compareJob)).toBe(true)
    expect(compareLink.condition(restoreJob)).toBe(false)
    expect(restoreLink.link).toBe('/cloud-backup/restore?JobId=[Id]')
    expect(restoreLink.condition(restoreJob)).toBe(true)
  })

  it('shows where a restore went in the details drawer', () => {
    renderWithProviders(<JobsPage />)
    renderWithProviders(
      table.props.offCanvas.children(table.props.dataMap(restoreJob))
    )

    expect(screen.getByText('fabrikam.com')).toBeInTheDocument()
    expect(screen.getByText('tech@msp.example')).toBeInTheDocument()
    expect(screen.getAllByText('View Results')).toHaveLength(1)
  })

  it('adds the new pages to the Cloud Backup menu', () => {
    const cloudBackup = nativeMenuItems.find(
      (item) => item.title === 'Cloud Backup'
    )
    const pages = Object.fromEntries(
      cloudBackup.items.map((item) => [item.path, item])
    )

    for (const path of [
      '/cloud-backup/compare',
      '/cloud-backup/restore',
      '/cloud-backup/jobs',
    ]) {
      expect(pages[path].permissions).toEqual(['CIPP.CloudBackup.*'])
      expect(pages[path].scope).toBe('global')
    }
  })
})
