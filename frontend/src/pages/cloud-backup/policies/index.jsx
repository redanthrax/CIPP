import { Button } from '@mui/material'
import Link from 'next/link'
import { CippIcons } from '../../../utils/icon-registry'
import { CippTablePage } from '../../../components/CippComponents/CippTablePage.jsx'
import { Layout as DashboardLayout } from '../../../layouts/index'
import { CippPropertyListCard } from '../../../components/CippCards/CippPropertyListCard'
import { getCippFormatting } from '../../../utils/get-cipp-formatting'
import {
  cloudBackupAreaLabel,
  cloudBackupScheduleLabel,
} from '../../../utils/cloud-backup'

const RELATED_KEYS = ['ListCloudBackupPolicies*', 'ListCloudBackupOverview']

const toDisplayRow = (row) => ({
  ...row,
  Areas: (row.ConfigAreas ?? []).map(cloudBackupAreaLabel).join(', '),
  Schedule: cloudBackupScheduleLabel(row.ConfigSchedule),
  CloudBackupDestinationName: row.DestinationName,
  CloudBackupTenantSummary: row.TenantSummary,
  CloudBackupLastResult: row.LastRunStatus,
  CloudBackupLastRun: row.LastRunAt,
})

const cloudBackupPolicyActions = [
  {
    label: 'Edit Policy',
    pinned: true,
    icon: <CippIcons.Edit />,
    link: '/cloud-backup/policies/edit?id=[Id]',
  },
  {
    label: 'Run Backup Now',
    type: 'POST',
    url: '/api/ExecCloudBackupRun',
    icon: <CippIcons.PlayArrow />,
    data: { PolicyId: 'Id' },
    confirmText:
      'Back up every tenant in [Name] now? The schedule is not changed. Progress shows on the Runs page.',
    relatedQueryKeys: [...RELATED_KEYS, 'ListCloudBackupRuns*'],
  },
  {
    label: 'View Runs',
    icon: <CippIcons.History />,
    link: '/cloud-backup/runs?PolicyId=[Id]',
  },
  {
    label: 'Rotate Encryption Key',
    type: 'POST',
    url: '/api/ExecCloudBackupPolicy',
    icon: <CippIcons.VpnKey />,
    data: { Action: '!RotateKey', Id: 'Id' },
    confirmText:
      'Create a new encryption key for [Name]? New backups use the new key. Older backups stay readable with the previous keys, which are kept.',
    condition: (row) => row.Encryption === true,
    relatedQueryKeys: RELATED_KEYS,
  },
  {
    label: 'Delete Policy',
    type: 'POST',
    url: '/api/ExecCloudBackupPolicy',
    icon: <CippIcons.Delete />,
    data: { Action: '!Delete', Id: 'Id' },
    confirmText:
      'Delete [Name]? Scheduled backups stop and the retention rule is removed from the destination. Backups already stored are not deleted.',
    relatedQueryKeys: RELATED_KEYS,
  },
]

const Page = () => {
  const offCanvas = {
    children: (row) => (
      <CippPropertyListCard
        cardSx={{ p: 0, m: -2 }}
        title="Policy Details"
        actionItems={cloudBackupPolicyActions}
        data={row}
        propertyItems={[
          { label: 'Status', value: row.Enabled ? 'Enabled' : 'Disabled' },
          {
            label: 'Destination',
            value: row.DestinationName ?? 'Destination not found',
          },
          { label: 'Tenants', value: row.TenantSummary },
          { label: 'What is backed up', value: toDisplayRow(row).Areas },
          {
            label: 'Schedule',
            value: cloudBackupScheduleLabel(row.ConfigSchedule),
          },
          {
            label: 'Next run',
            value: row.ConfigNextRun
              ? getCippFormatting(row.ConfigNextRun, 'CloudBackupNextRun')
              : 'Not scheduled',
          },
          { label: 'Keep backups for', value: `${row.RetentionDays} days` },
          {
            label: 'Encryption',
            value: row.Encryption
              ? `On (${row.KeyCount ?? 0} ${row.KeyCount === 1 ? 'key' : 'keys'})`
              : 'Off',
          },
          {
            label: 'Last run',
            value: row.LastRunAt
              ? getCippFormatting(row.LastRunAt, 'CloudBackupLastRun')
              : 'Never',
          },
          {
            label: 'Last run result',
            value: row.LastRunStatus
              ? getCippFormatting(row.LastRunStatus, 'CloudBackupLastResult')
              : 'Not run yet',
          },
        ]}
      />
    ),
  }

  return (
    <CippTablePage
      title="Backup Policies"
      apiUrl="/api/ListCloudBackupPolicies"
      apiData={{ tenantFilter: undefined, tenantGroup: undefined }}
      queryKey="ListCloudBackupPolicies"
      tenantInTitle={false}
      actions={cloudBackupPolicyActions}
      offCanvas={offCanvas}
      offCanvasOnRowClick={true}
      dataMap={toDisplayRow}
      cardButton={
        <Button
          component={Link}
          href="/cloud-backup/policies/add"
          startIcon={<CippIcons.AddBox />}
        >
          Add Policy
        </Button>
      }
      simpleColumns={[
        'Name',
        'Enabled',
        'CloudBackupDestinationName',
        'CloudBackupTenantSummary',
        'Schedule',
        'CloudBackupLastResult',
        'CloudBackupLastRun',
      ]}
    />
  )
}

Page.getLayout = (page) => (
  <DashboardLayout usesTenant={false}>{page}</DashboardLayout>
)

export default Page
