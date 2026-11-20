import { useEffect } from 'react'
import { useRouter } from 'next/router'
import { useForm, useWatch } from 'react-hook-form'
import {
  Alert,
  Card,
  CardContent,
  CardHeader,
  Stack,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableRow,
} from '@mui/material'
import { CippTablePage } from '../../../components/CippComponents/CippTablePage.jsx'
import { Layout as DashboardLayout } from '../../../layouts/index'
import { CippPropertyListCard } from '../../../components/CippCards/CippPropertyListCard'
import CippFormComponent from '../../../components/CippComponents/CippFormComponent'
import { ApiGetCall } from '../../../api/ApiCall'
import { getCippFormatting } from '../../../utils/get-cipp-formatting'
import { formatBytes } from '../../../utils/instance-diagnostics'
import { CippIcons } from '../../../utils/icon-registry'
import {
  cloudBackupAreaLabel,
  parseCloudBackupList,
  toCloudBackupRunRow,
} from '../../../utils/cloud-backup'

const formatDuration = (seconds) => {
  const total = Number(seconds)
  if (!Number.isFinite(total) || total < 0) return 'Still running'
  if (total < 60) return `${Math.round(total)} seconds`
  const minutes = Math.floor(total / 60)
  const rest = Math.round(total % 60)
  return rest ? `${minutes} min ${rest} s` : `${minutes} min`
}

const toDisplayRow = (row) => ({
  ...toCloudBackupRunRow(row),
  Duration: row.CompletedAt
    ? formatDuration(row.DurationSeconds)
    : 'Still running',
})

const hasBackup = (row) =>
  row.Status === 'Succeeded' || row.Status === 'PartialSuccess'

const runActions = [
  {
    label: 'Compare with live',
    icon: <CippIcons.CompareArrows />,
    link: '/cloud-backup/compare?RunId=[Id]',
    condition: hasBackup,
  },
  {
    label: 'Browse and restore',
    icon: <CippIcons.Restore />,
    link: '/cloud-backup/restore?RunId=[Id]',
    condition: hasBackup,
  },
]

const RunDetails = ({ row }) => {
  const areas = parseCloudBackupList(row.Areas)
  const warnings = parseCloudBackupList(row.Warnings)
  return (
    <Stack spacing={2}>
      <CippPropertyListCard
        cardSx={{ p: 0, m: -2 }}
        title="Backup Run"
        propertyItems={[
          { label: 'Policy', value: row.PolicyName },
          { label: 'Tenant', value: row.Tenant },
          {
            label: 'Result',
            value: getCippFormatting(row.Status, 'CloudBackupStatus'),
          },
          {
            label: 'Started',
            value: getCippFormatting(row.StartedAt, 'CloudBackupStartedAt'),
          },
          {
            label: 'Finished',
            value: row.CompletedAt
              ? getCippFormatting(row.CompletedAt, 'CloudBackupCompletedAt')
              : 'Still running',
          },
          { label: 'Duration', value: toDisplayRow(row).Duration },
          { label: 'Items backed up', value: String(row.Items ?? 0) },
          { label: 'Size', value: formatBytes(row.Bytes) },
          { label: 'Stored at', value: row.Location },
        ]}
      />
      <Card>
        <CardHeader title="Per area" />
        <CardContent sx={{ p: 0, overflowX: 'auto' }}>
          {areas.length === 0 ? (
            <Alert severity="info" sx={{ m: 2 }}>
              No areas have finished yet.
            </Alert>
          ) : (
            <Table size="small">
              <TableHead>
                <TableRow>
                  <TableCell>Area</TableCell>
                  <TableCell>Result</TableCell>
                  <TableCell align="right">Items</TableCell>
                  <TableCell align="right">Size</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                {areas.map((area) => (
                  <TableRow key={area.Area}>
                    <TableCell>
                      {cloudBackupAreaLabel(area.Area)}
                      {area.Error && (
                        <Alert severity="error" sx={{ mt: 1 }}>
                          {area.Error}
                        </Alert>
                      )}
                    </TableCell>
                    <TableCell>
                      {getCippFormatting(
                        area.Status ?? 'Unknown',
                        'CloudBackupStatus'
                      )}
                    </TableCell>
                    <TableCell align="right">{area.Items ?? 0}</TableCell>
                    <TableCell align="right">
                      {formatBytes(area.Bytes)}
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>
      {warnings.map((warning, index) => (
        <Alert severity="warning" key={index}>
          {warning}
        </Alert>
      ))}
    </Stack>
  )
}

const Page = () => {
  const router = useRouter()
  const formControl = useForm({ defaultValues: { PolicyId: null } })
  const policyId = useWatch({ control: formControl.control, name: 'PolicyId' })

  useEffect(() => {
    if (router.query.PolicyId) {
      formControl.setValue('PolicyId', router.query.PolicyId)
    }
  }, [router.query.PolicyId, formControl])

  const policies = ApiGetCall({
    url: '/api/ListCloudBackupPolicies',
    queryKey: 'ListCloudBackupPolicies-picker',
  })
  const policyOptions = (Array.isArray(policies.data) ? policies.data : []).map(
    (policy) => ({
      label: policy.Name,
      value: policy.Id,
    })
  )

  const filter = (
    <Card>
      <CardContent>
        <CippFormComponent
          type="select"
          label="Show runs for policy"
          name="PolicyId"
          formControl={formControl}
          options={policyOptions}
          isFetching={policies.isFetching}
          placeholder="All policies"
        />
      </CardContent>
    </Card>
  )

  return (
    <CippTablePage
      title="Backup Runs"
      apiUrl="/api/ListCloudBackupRuns"
      apiData={{
        tenantFilter: undefined,
        tenantGroup: undefined,
        PolicyId: policyId || undefined,
      }}
      queryKey={`ListCloudBackupRuns-${policyId || 'all'}`}
      tenantInTitle={false}
      tableFilter={filter}
      dataMap={toDisplayRow}
      actions={runActions}
      offCanvas={{
        title: 'Backup Run Details',
        children: (row) => <RunDetails row={row} />,
      }}
      offCanvasOnRowClick={true}
      simpleColumns={[
        'CloudBackupStartedAt',
        'PolicyName',
        'Tenant',
        'CloudBackupStatus',
        'Items',
        'CloudBackupSize',
        'Duration',
      ]}
    />
  )
}

Page.getLayout = (page) => (
  <DashboardLayout usesTenant={false}>{page}</DashboardLayout>
)

export default Page
