export const CLOUD_BACKUP_AREAS = [
  { label: 'Conditional Access', value: 'ConditionalAccess' },
  { label: 'Intune', value: 'Intune' },
  { label: 'Exchange Online', value: 'Exchange' },
  { label: 'SharePoint', value: 'SharePoint' },
]

export const CLOUD_BACKUP_SCHEDULES = [
  { label: 'Every hour', value: '1h' },
  { label: 'Every 4 hours', value: '4h' },
  { label: 'Every 12 hours', value: '12h' },
  { label: 'Every day', value: '1d' },
  { label: 'Every week', value: '7d' },
]

export const CLOUD_BACKUP_PROVIDERS = [
  { label: 'Azure Blob Storage', value: 'AzureBlob' },
  { label: 'Amazon S3 or S3-compatible storage', value: 'S3' },
]

export const CLOUD_BACKUP_SECRET_SENTINEL = 'SentToKeyVault'

const labelFor = (options, value) =>
  options.find((option) => option.value === value)?.label ?? value

export const cloudBackupAreaLabel = (value) =>
  labelFor(CLOUD_BACKUP_AREAS, value)

export const cloudBackupScheduleLabel = (value) =>
  labelFor(CLOUD_BACKUP_SCHEDULES, value)

export const cloudBackupProviderLabel = (value) =>
  labelFor(CLOUD_BACKUP_PROVIDERS, value)

const optionValue = (item) =>
  item && typeof item === 'object' ? item.value : item

export const formatCloudBackupPolicy = (values, action) => ({
  Action: action,
  Id: values.Id,
  Name: values.Name,
  Enabled: Boolean(values.Enabled),
  DestinationId: optionValue(values.DestinationId),
  Tenants: values.Tenants ?? [],
  ConfigAreas: (values.ConfigAreas ?? []).map(optionValue),
  ConfigSchedule: optionValue(values.ConfigSchedule),
  RetentionDays: Number(values.RetentionDays),
  Encryption: Boolean(values.Encryption),
})

const AZURE_FIELDS = [
  'StorageAccount',
  'Container',
  'SubscriptionId',
  'ResourceGroup',
  'AzureTenantId',
  'ClientId',
  'ClientSecret',
]
const S3_FIELDS = [
  'Endpoint',
  'Region',
  'Bucket',
  'AccessKeyId',
  'SecretAccessKey',
]

export const formatCloudBackupDestination = (values, action) => {
  const provider = optionValue(values.Provider)
  const fields = provider === 'AzureBlob' ? AZURE_FIELDS : S3_FIELDS
  const body = {
    Action: action,
    Id: values.Id,
    Name: values.Name,
    Provider: provider,
  }
  fields.forEach((field) => {
    body[field] =
      typeof values[field] === 'string' ? values[field].trim() : values[field]
  })
  if (provider === 'S3') {
    body.ForcePathStyle = Boolean(values.ForcePathStyle)
  }
  return body
}

export const parseCloudBackupList = (value) => {
  if (Array.isArray(value)) return value
  if (typeof value === 'string' && value.trim().startsWith('[')) {
    try {
      const parsed = JSON.parse(value)
      return Array.isArray(parsed) ? parsed : []
    } catch {
      return []
    }
  }
  return []
}

export const CLOUD_BACKUP_RESTORABLE_AREAS = CLOUD_BACKUP_AREAS.filter(
  (area) => area.value !== 'SharePoint'
)

export const CLOUD_BACKUP_CONFLICT_ACTIONS = [
  { label: 'Skip items that already exist', value: 'Skip' },
  { label: 'Overwrite items that already exist', value: 'Overwrite' },
  {
    label: 'Create a copy named "(restored date)" next to the existing item',
    value: 'Copy',
  },
]

export const CLOUD_BACKUP_CA_STATES = [
  { label: 'Keep the state from the backup', value: 'AsBackedUp' },
  { label: 'Report-only', value: 'ReportOnly' },
  { label: 'Off', value: 'Disabled' },
]

const RESTORE_ACTION_LABELS = {
  Create: 'Create',
  Update: 'Overwrite',
  CreateCopy: 'Create a copy',
  Skip: 'Skip',
  NotRestorable: 'Cannot be restored',
}

export const cloudBackupRestoreActionLabel = (value) =>
  RESTORE_ACTION_LABELS[value] ?? value

export const cloudBackupChangeLabel = (value, otherSide = 'current') => {
  if (value === 'Added') return `Only in ${otherSide}`
  if (value === 'Removed') return 'Only in backup'
  return value
}

const JOB_TYPE_LABELS = {
  Compare: 'Compare',
  RestorePreview: 'Restore preview',
  Restore: 'Restore',
}

export const cloudBackupJobTypeLabel = (value) =>
  JOB_TYPE_LABELS[value] ?? value

export const isCloudBackupJobActive = (status) =>
  status === 'Queued' || status === 'Running'

export const parseCloudBackupObject = (value) => {
  if (value && typeof value === 'object') return value
  if (typeof value === 'string' && value.trim().startsWith('{')) {
    try {
      return JSON.parse(value)
    } catch {
      return {}
    }
  }
  return {}
}

const countPhrase = (count, phrase) => (count ? `${count} ${phrase}` : null)

export const cloudBackupJobSummary = (type, summary) => {
  const counts = parseCloudBackupObject(summary)
  let parts
  if (type === 'Compare') {
    const total = { Added: 0, Removed: 0, Changed: 0 }
    Object.values(counts).forEach((area) => {
      Object.keys(total).forEach((key) => {
        total[key] += Number(area?.[key] ?? 0)
      })
    })
    parts = [
      countPhrase(total.Changed, 'changed'),
      countPhrase(total.Added, 'only in current'),
      countPhrase(total.Removed, 'only in backup'),
    ]
    return parts.filter(Boolean).join(', ') || 'No differences'
  }
  if (type === 'Restore') {
    parts = [
      countPhrase(counts.Succeeded, 'restored'),
      countPhrase(counts.Failed, 'failed'),
      countPhrase(counts.Skip, 'skipped'),
      countPhrase(counts.NotRestorable, 'cannot be restored'),
    ]
  } else {
    parts = [
      countPhrase(counts.Create, 'to create'),
      countPhrase(counts.Update, 'to overwrite'),
      countPhrase(counts.CreateCopy, 'to copy'),
      countPhrase(counts.Skip, 'skipped'),
      countPhrase(counts.NotRestorable, 'cannot be restored'),
    ]
  }
  return parts.filter(Boolean).join(', ') || 'Nothing to restore'
}

export const formatCloudBackupValue = (value) => {
  if (value === null || value === undefined || value === '') return '-'
  if (Array.isArray(value) && value.length === 0) return '-'
  if (typeof value === 'object') return JSON.stringify(value)
  return String(value)
}

export const cloudBackupOptionValue = optionValue

export const toCloudBackupRunRow = (row) => ({
  ...row,
  CloudBackupStatus: row.Status,
  CloudBackupStartedAt: row.StartedAt,
  CloudBackupCompletedAt: row.CompletedAt,
  CloudBackupSize: row.Bytes,
})
