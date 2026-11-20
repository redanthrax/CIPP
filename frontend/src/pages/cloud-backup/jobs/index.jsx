import { CippTablePage } from '../../../components/CippComponents/CippTablePage.jsx'
import { Layout as DashboardLayout } from '../../../layouts/index'
import { CippPropertyListCard } from '../../../components/CippCards/CippPropertyListCard'
import { getCippFormatting } from '../../../utils/get-cipp-formatting'
import { CippIcons } from '../../../utils/icon-registry'
import {
  cloudBackupJobSummary,
  cloudBackupJobTypeLabel,
} from '../../../utils/cloud-backup'

const toDisplayRow = (row) => ({
  ...row,
  Job: cloudBackupJobTypeLabel(row.Type),
  CloudBackupStatus: row.Status,
  RequestedAt: row.CreatedAt,
  Result: cloudBackupJobSummary(row.Type, row.Summary),
})

const jobActions = [
  {
    label: 'View Results',
    pinned: true,
    icon: <CippIcons.Visibility />,
    link: '/cloud-backup/compare?JobId=[Id]',
    condition: (row) => row.Type === 'Compare',
  },
  {
    label: 'View Results',
    pinned: true,
    icon: <CippIcons.Visibility />,
    link: '/cloud-backup/restore?JobId=[Id]',
    condition: (row) => row.Type !== 'Compare',
  },
]

const dateOr = (value, cellName, fallback) =>
  value ? getCippFormatting(value, cellName) : fallback

const Page = () => (
  <CippTablePage
    title="Restore & Compare History"
    apiUrl="/api/ListCloudBackupJobs"
    apiData={{ tenantFilter: undefined, tenantGroup: undefined }}
    queryKey="ListCloudBackupJobs"
    tenantInTitle={false}
    dataMap={toDisplayRow}
    actions={jobActions}
    offCanvas={{
      title: 'Job Details',
      children: (row) => (
        <CippPropertyListCard
          cardSx={{ p: 0, m: -2 }}
          title={row.Job}
          actionItems={jobActions.filter((action) => action.condition(row))}
          data={row}
          propertyItems={[
            {
              label: 'Status',
              value: getCippFormatting(row.Status, 'CloudBackupStatus'),
            },
            { label: 'Backup of', value: row.SourceTenant },
            {
              label: row.Type === 'Compare' ? 'Compared with' : 'Restored to',
              value:
                row.Type === 'Compare'
                  ? row.CompareToRunId
                    ? 'Another backup'
                    : 'Current tenant configuration'
                  : row.TargetTenant,
            },
            { label: 'Requested by', value: row.RequestedBy },
            {
              label: 'Requested',
              value: dateOr(row.RequestedAt, 'RequestedAt', 'Unknown'),
            },
            {
              label: 'Finished',
              value: dateOr(
                row.CompletedAt,
                'CloudBackupCompletedAt',
                'Not finished'
              ),
            },
            { label: 'Result', value: row.Result },
            ...(row.Error ? [{ label: 'Error', value: row.Error }] : []),
          ]}
        />
      ),
    }}
    offCanvasOnRowClick={true}
    simpleColumns={[
      'RequestedAt',
      'Job',
      'CloudBackupStatus',
      'SourceTenant',
      'TargetTenant',
      'RequestedBy',
      'Result',
    ]}
    filters={[
      {
        filterName: 'Restores',
        value: [{ id: 'Job', value: 'Restore' }],
        type: 'column',
      },
      {
        filterName: 'Comparisons',
        value: [{ id: 'Job', value: 'Compare' }],
        type: 'column',
      },
      {
        filterName: 'Failed',
        value: [{ id: 'CloudBackupStatus', value: 'Failed' }],
        type: 'column',
      },
    ]}
  />
)

Page.getLayout = (page) => (
  <DashboardLayout usesTenant={false}>{page}</DashboardLayout>
)

export default Page
