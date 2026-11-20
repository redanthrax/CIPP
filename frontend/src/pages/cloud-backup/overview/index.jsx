import { useMemo } from 'react'
import { Alert, Button, Container, Stack } from '@mui/material'
import Link from 'next/link'
import { Layout as DashboardLayout } from '../../../layouts/index'
import { CippHead } from '../../../components/CippComponents/CippHead'
import { CippInfoBar } from '../../../components/CippCards/CippInfoBar'
import { CippDataTable } from '../../../components/CippTable/CippDataTable'
import { ApiGetCall } from '../../../api/ApiCall'
import { CippIcons } from '../../../utils/icon-registry'
import { formatBytes } from '../../../utils/instance-diagnostics'
import { toCloudBackupRunRow } from '../../../utils/cloud-backup'

const Page = () => {
  const overview = ApiGetCall({
    url: '/api/ListCloudBackupOverview',
    queryKey: 'ListCloudBackupOverview',
  })
  const data = overview.data ?? {}
  const latestRuns = useMemo(
    () =>
      Array.isArray(data.LatestRuns)
        ? data.LatestRuns.map(toCloudBackupRunRow)
        : [],
    [data.LatestRuns]
  )

  const stats = [
    {
      name: 'Policies',
      data: data.Policies ?? 0,
      icon: <CippIcons.Policy />,
      link: '/cloud-backup/policies',
    },
    {
      name: 'Enabled policies',
      data: data.EnabledPolicies ?? 0,
      icon: <CippIcons.CheckCircle />,
      link: '/cloud-backup/policies',
    },
    {
      name: 'Destinations',
      data: data.Destinations ?? 0,
      icon: <CippIcons.Storage />,
      link: '/cloud-backup/destinations',
    },
    {
      name: 'Tenants covered',
      data: data.TenantsCovered ?? 0,
      icon: <CippIcons.Groups />,
    },
    {
      name: 'Failures (24 hours)',
      data: data.Failures24h ?? 0,
      icon: <CippIcons.Error />,
      color: data.Failures24h > 0 ? 'error' : 'primary',
      link: '/cloud-backup/runs',
    },
    {
      name: 'Latest backups size',
      data: formatBytes(data.LatestBytes),
      icon: <CippIcons.Backup />,
    },
  ]

  return (
    <>
      <CippHead title="Cloud Backup" />
      <Container maxWidth={false}>
        <Stack spacing={2}>
          {overview.isSuccess && !data.Destinations && (
            <Alert
              severity="info"
              action={
                <Button
                  component={Link}
                  href="/cloud-backup/destinations/add"
                  color="inherit"
                  size="small"
                >
                  Add destination
                </Button>
              }
            >
              Start by adding a destination: the Azure storage account or S3
              bucket where backups are stored.
            </Alert>
          )}
          {overview.isSuccess && !!data.Destinations && !data.Policies && (
            <Alert
              severity="info"
              action={
                <Button
                  component={Link}
                  href="/cloud-backup/policies/add"
                  color="inherit"
                  size="small"
                >
                  Add policy
                </Button>
              }
            >
              Add a backup policy to choose which tenants and settings are
              backed up, and how often.
            </Alert>
          )}
          {overview.isError && (
            <Alert severity="error">
              The backup overview could not be loaded. Refresh the page to try
              again.
            </Alert>
          )}
          <CippInfoBar data={stats} isFetching={overview.isFetching} />
          <CippDataTable
            title="Latest backup per tenant"
            data={latestRuns}
            isFetching={overview.isFetching}
            refreshFunction={overview.refetch}
            queryKey="ListCloudBackupOverview-latest"
            simpleColumns={[
              'Tenant',
              'PolicyName',
              'CloudBackupStatus',
              'CloudBackupCompletedAt',
              'Items',
              'CloudBackupSize',
            ]}
          />
        </Stack>
      </Container>
    </>
  )
}

Page.getLayout = (page) => (
  <DashboardLayout usesTenant={false}>{page}</DashboardLayout>
)

export default Page
