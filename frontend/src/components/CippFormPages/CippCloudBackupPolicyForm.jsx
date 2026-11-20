import { Alert, Button } from '@mui/material'
import { Grid } from '@mui/system'
import Link from 'next/link'
import CippFormComponent from '../CippComponents/CippFormComponent'
import { CippFormTenantSelector } from '../CippComponents/CippFormTenantSelector'
import { ApiGetCall } from '../../api/ApiCall'
import {
  CLOUD_BACKUP_AREAS,
  CLOUD_BACKUP_SCHEDULES,
} from '../../utils/cloud-backup'

export const CippCloudBackupPolicyForm = ({ formControl }) => {
  const destinations = ApiGetCall({
    url: '/api/ListCloudBackupDestinations',
    queryKey: 'ListCloudBackupDestinations-picker',
  })
  const destinationRows = Array.isArray(destinations.data)
    ? destinations.data
    : []
  const destinationOptions = destinationRows.map((destination) => ({
    label: destination.Location
      ? `${destination.Name} (${destination.Location})`
      : destination.Name,
    value: destination.Id,
  }))
  const noDestinations = destinations.isSuccess && destinationRows.length === 0

  return (
    <Grid container spacing={2}>
      <CippFormComponent type="hidden" name="Id" formControl={formControl} />
      <Grid size={{ md: 8, xs: 12 }}>
        <CippFormComponent
          type="textField"
          label="Policy name"
          name="Name"
          required
          formControl={formControl}
          validators={{ required: 'Give the policy a name' }}
          fullWidth
        />
      </Grid>
      <Grid size={{ md: 4, xs: 12 }}>
        <CippFormComponent
          type="switch"
          label="Enabled"
          name="Enabled"
          formControl={formControl}
          helperText="Disabled policies keep their settings but don't run on schedule."
        />
      </Grid>
      <Grid size={{ xs: 12 }}>
        {noDestinations ? (
          <Alert
            severity="warning"
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
            Add a destination first. A policy needs somewhere to store its
            backups.
          </Alert>
        ) : (
          <CippFormComponent
            type="select"
            label="Destination"
            name="DestinationId"
            required
            formControl={formControl}
            options={destinationOptions}
            isFetching={destinations.isFetching}
            validators={{ required: 'Choose where backups are stored' }}
          />
        )}
      </Grid>
      <Grid size={{ xs: 12 }}>
        <CippFormTenantSelector
          formControl={formControl}
          name="Tenants"
          label="Tenants"
          allTenants={true}
          includeGroups={true}
          required={true}
        />
      </Grid>
      <Grid size={{ xs: 12 }}>
        <CippFormComponent
          type="autoComplete"
          label="What to back up"
          name="ConfigAreas"
          multiple
          creatable={false}
          options={CLOUD_BACKUP_AREAS}
          formControl={formControl}
          validators={{
            validate: (value) =>
              (Array.isArray(value) && value.length > 0) ||
              'Choose at least one area to back up',
          }}
          helperText="Configuration settings only. Mailbox, OneDrive and SharePoint content are not included."
        />
      </Grid>
      <Grid size={{ md: 6, xs: 12 }}>
        <CippFormComponent
          type="select"
          label="Schedule"
          name="ConfigSchedule"
          required
          options={CLOUD_BACKUP_SCHEDULES}
          formControl={formControl}
          validators={{ required: 'Choose how often to back up' }}
        />
      </Grid>
      <Grid size={{ md: 6, xs: 12 }}>
        <CippFormComponent
          type="number"
          label="Keep backups for (days)"
          name="RetentionDays"
          formControl={formControl}
          validators={{
            required: 'Enter how many days to keep backups',
            min: { value: 7, message: 'Keep backups for at least 7 days' },
            max: {
              value: 3650,
              message: 'Keep backups for at most 3650 days (10 years)',
            },
          }}
          helperText="The destination's lifecycle rule deletes backups older than this."
          fullWidth
        />
      </Grid>
      <Grid size={{ xs: 12 }}>
        <CippFormComponent
          type="switch"
          label="Encrypt backups"
          name="Encryption"
          formControl={formControl}
          helperText="Backups are encrypted before upload with a key kept in CIPP's Key Vault. If that key is lost, encrypted backups can't be read. Secret values in custom Intune profiles are only backed up when this is on."
        />
      </Grid>
    </Grid>
  )
}

export default CippCloudBackupPolicyForm
