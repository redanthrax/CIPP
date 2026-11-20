import { useForm } from 'react-hook-form'
import CippFormPage from '../../../components/CippFormPages/CippFormPage'
import { Layout as DashboardLayout } from '../../../layouts/index'
import { CippCloudBackupDestinationForm } from '../../../components/CippFormPages/CippCloudBackupDestinationForm'
import { formatCloudBackupDestination } from '../../../utils/cloud-backup'

const Page = () => {
  const formControl = useForm({
    mode: 'onChange',
    defaultValues: { Provider: 'AzureBlob', ForcePathStyle: false },
  })

  return (
    <CippFormPage
      formControl={formControl}
      title="Backup Destination"
      backButtonTitle="Destinations"
      backUrl="/cloud-backup/destinations"
      postUrl="/api/ExecCloudBackupDestination"
      queryKey={['ListCloudBackupDestinations*', 'ListCloudBackupOverview']}
      customDataformatter={(values) =>
        formatCloudBackupDestination(values, 'Add')
      }
    >
      <CippCloudBackupDestinationForm formControl={formControl} />
    </CippFormPage>
  )
}

Page.getLayout = (page) => (
  <DashboardLayout usesTenant={false}>{page}</DashboardLayout>
)

export default Page
