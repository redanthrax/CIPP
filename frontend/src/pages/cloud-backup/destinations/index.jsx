import { Alert, Button, Stack } from '@mui/material'
import Link from 'next/link'
import { CippIcons } from '../../../utils/icon-registry'
import { CippTablePage } from '../../../components/CippComponents/CippTablePage.jsx'
import { Layout as DashboardLayout } from '../../../layouts/index'
import { CippPropertyListCard } from '../../../components/CippCards/CippPropertyListCard'
import { getCippFormatting } from '../../../utils/get-cipp-formatting'
import { cloudBackupProviderLabel } from '../../../utils/cloud-backup'

const RELATED_KEYS = ['ListCloudBackupDestinations*', 'ListCloudBackupOverview']

const toDisplayRow = (row) => ({
  ...row,
  CloudBackupProviderName: cloudBackupProviderLabel(row.Provider),
  CloudBackupLastTest: row.LastTestStatus,
  CloudBackupLastTested: row.LastTestedAt,
  CloudBackupPolicyCount: row.PolicyCount,
})

const checkResult = (value) =>
  value === true
    ? getCippFormatting('Passed', 'CloudBackupStatus')
    : value === false
      ? getCippFormatting('Failed', 'CloudBackupStatus')
      : 'Not tested'

const actions = [
  {
    label: 'Test Connection',
    type: 'POST',
    url: '/api/ExecCloudBackupDestination',
    icon: <CippIcons.FactCheck />,
    data: { Action: '!Test', Id: 'Id' },
    confirmText:
      'Test [Name]? CIPP writes, reads and deletes a small test file and checks it can manage the retention rule.',
    relatedQueryKeys: RELATED_KEYS,
  },
  {
    label: 'Edit Destination',
    pinned: true,
    icon: <CippIcons.Edit />,
    link: '/cloud-backup/destinations/edit?id=[Id]',
  },
  {
    label: 'Delete Destination',
    type: 'POST',
    url: '/api/ExecCloudBackupDestination',
    icon: <CippIcons.Delete />,
    data: { Action: '!Delete', Id: 'Id' },
    confirmText:
      'Delete [Name]? The stored secret is removed from CIPP. Backups already in the storage account or bucket are not deleted. A destination used by a policy cannot be deleted.',
    relatedQueryKeys: RELATED_KEYS,
  },
]

const Page = () => {
  const offCanvas = {
    children: (row) => {
      const lastTest = row.LastTest ?? {}
      const errors = Array.isArray(lastTest.Errors) ? lastTest.Errors : []
      return (
        <Stack spacing={2}>
          <CippPropertyListCard
            cardSx={{ p: 0, m: -2 }}
            title="Destination Details"
            actionItems={actions}
            data={row}
            propertyItems={[
              {
                label: 'Provider',
                value: cloudBackupProviderLabel(row.Provider),
              },
              { label: 'Location', value: row.Location },
              {
                label: 'Used by policies',
                value: String(row.PolicyCount ?? 0),
              },
              {
                label: 'Secret',
                value: row.SecretSet ? 'Stored in Key Vault' : 'Not set',
              },
            ]}
          />
          <CippPropertyListCard
            title="Last Connection Test"
            propertyItems={
              row.LastTestedAt
                ? [
                    {
                      label: 'Tested',
                      value: getCippFormatting(
                        row.LastTestedAt,
                        'CloudBackupLastTested'
                      ),
                    },
                    {
                      label: 'Write a file',
                      value: checkResult(lastTest.Write),
                    },
                    {
                      label: 'Read it back',
                      value: checkResult(lastTest.Read),
                    },
                    { label: 'Delete it', value: checkResult(lastTest.Delete) },
                    {
                      label: 'Manage retention rule',
                      value: checkResult(lastTest.Lifecycle),
                    },
                    {
                      label: 'Versioning',
                      value: lastTest.Versioning ?? 'Unknown',
                    },
                  ]
                : [
                    {
                      label: 'Tested',
                      value: 'Never. Use Test Connection to check it.',
                    },
                  ]
            }
          />
          {errors.map((error, index) => (
            <Alert severity="error" key={index}>
              {error}
            </Alert>
          ))}
        </Stack>
      )
    },
  }

  return (
    <CippTablePage
      title="Backup Destinations"
      apiUrl="/api/ListCloudBackupDestinations"
      apiData={{ tenantFilter: undefined, tenantGroup: undefined }}
      queryKey="ListCloudBackupDestinations"
      tenantInTitle={false}
      actions={actions}
      offCanvas={offCanvas}
      offCanvasOnRowClick={true}
      dataMap={toDisplayRow}
      cardButton={
        <Button
          component={Link}
          href="/cloud-backup/destinations/add"
          startIcon={<CippIcons.AddBox />}
        >
          Add Destination
        </Button>
      }
      simpleColumns={[
        'Name',
        'CloudBackupProviderName',
        'Location',
        'CloudBackupLastTest',
        'CloudBackupLastTested',
        'CloudBackupPolicyCount',
      ]}
    />
  )
}

Page.getLayout = (page) => (
  <DashboardLayout usesTenant={false}>{page}</DashboardLayout>
)

export default Page
