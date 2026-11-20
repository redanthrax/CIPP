import { useEffect, useMemo, useState } from 'react'
import Link from 'next/link'
import { useRouter } from 'next/router'
import { useForm, useWatch } from 'react-hook-form'
import {
  Alert,
  Box,
  Button,
  Card,
  CardContent,
  CardHeader,
  Container,
  Stack,
  Typography,
} from '@mui/material'
import { Layout as DashboardLayout } from '../../../layouts/index'
import { CippHead } from '../../../components/CippComponents/CippHead'
import { CippDataTable } from '../../../components/CippTable/CippDataTable'
import { CippPropertyListCard } from '../../../components/CippCards/CippPropertyListCard'
import CippFormComponent from '../../../components/CippComponents/CippFormComponent'
import { CippFormTenantSelector } from '../../../components/CippComponents/CippFormTenantSelector'
import { CippApiDialog } from '../../../components/CippComponents/CippApiDialog'
import { CippApiResults } from '../../../components/CippComponents/CippApiResults'
import { CippCodeBlock } from '../../../components/CippComponents/CippCodeBlock'
import { CippCloudBackupRunPicker } from '../../../components/CippComponents/CippCloudBackupRunPicker'
import { CippCloudBackupDifferences } from '../../../components/CippComponents/CippCloudBackupDifferences'
import { CippCloudBackupJobStatus } from '../../../components/CippComponents/CippCloudBackupJobStatus'
import { ApiGetCall, ApiPostCall } from '../../../api/ApiCall'
import { useDialog } from '../../../hooks/use-dialog'
import { usePermissions } from '../../../hooks/use-permissions'
import { useCloudBackupJob } from '../../../hooks/use-cloud-backup-job'
import { getCippFormatting } from '../../../utils/get-cipp-formatting'
import { CippIcons } from '../../../utils/icon-registry'
import {
  CLOUD_BACKUP_CA_STATES,
  CLOUD_BACKUP_CONFLICT_ACTIONS,
  CLOUD_BACKUP_RESTORABLE_AREAS,
  cloudBackupAreaLabel,
  cloudBackupJobSummary,
  cloudBackupJobTypeLabel,
  cloudBackupOptionValue,
  cloudBackupRestoreActionLabel,
  parseCloudBackupList,
  parseCloudBackupObject,
} from '../../../utils/cloud-backup'

const RESTORE_PERMISSION = ['CIPP.CloudBackupRestore.ReadWrite']

const toItemRow = (row) => ({
  Name: row.Name ?? row.Key,
  Area: cloudBackupAreaLabel(row.Area),
  Section: row.SectionLabel ?? row.Section,
  AreaId: row.Area,
  SectionId: row.Section,
  Key: row.Key,
  Item: row.Item,
})

const toRestoreRow = (row) => {
  const unmapped = parseCloudBackupList(row.Unmapped)
  const differences = parseCloudBackupList(row.Differences)
  return {
    Name: row.Name ?? row.Key,
    Area: cloudBackupAreaLabel(row.Area),
    Section: row.SectionLabel ?? row.Section,
    Action: cloudBackupRestoreActionLabel(row.Action),
    CloudBackupStatus: row.Status,
    Message: row.Message ?? '',
    Changes: differences.length,
    NotFoundInTarget: unmapped.length,
    UnmappedList: unmapped,
    DifferenceList: differences,
  }
}

const areaFilters = (rows) =>
  [...new Set(rows.map((row) => row.Area))].map((area) => ({
    filterName: area,
    value: [{ id: 'Area', value: area }],
    type: 'column',
  }))

const BackupItemDetails = ({ row }) => (
  <Stack spacing={2}>
    <CippPropertyListCard
      cardSx={{ p: 0, m: -2 }}
      title="Backup Item"
      propertyItems={[
        { label: 'Name', value: row.Name },
        { label: 'Area', value: row.Area },
        { label: 'Section', value: row.Section },
      ]}
    />
    <CippCodeBlock code={JSON.stringify(row.Item ?? {}, null, 2)} />
  </Stack>
)

const RestoreItemDetails = ({ row }) => (
  <Stack spacing={2}>
    <CippPropertyListCard
      cardSx={{ p: 0, m: -2 }}
      title="Restore Item"
      propertyItems={[
        { label: 'Name', value: row.Name },
        { label: 'Area', value: row.Area },
        { label: 'Section', value: row.Section },
        { label: 'What happens', value: row.Action },
        {
          label: 'Result',
          value:
            row.CloudBackupStatus === 'Planned'
              ? 'Not restored yet'
              : getCippFormatting(row.CloudBackupStatus, 'CloudBackupStatus'),
        },
        { label: 'Details', value: row.Message || 'None' },
      ]}
    />
    {row.UnmappedList.length > 0 && (
      <Alert severity="warning">
        <Typography variant="body2" sx={{ mb: 1 }}>
          Not found in the target tenant, so left out of this item:
        </Typography>
        <Box component="ul" sx={{ m: 0, pl: 2.5 }}>
          {row.UnmappedList.map((entry, index) => (
            <li key={index}>{entry}</li>
          ))}
        </Box>
      </Alert>
    )}
    <Card>
      <CardHeader title="Differences from the target tenant" />
      <CardContent>
        <CippCloudBackupDifferences
          differences={row.DifferenceList}
          otherSideLabel="Current"
        />
      </CardContent>
    </Card>
  </Stack>
)

const RestoreResultsTable = ({ job, title, applied }) => {
  const rows = useMemo(
    () => parseCloudBackupList(job?.Result).map(toRestoreRow),
    [job?.Result]
  )
  return (
    <CippDataTable
      title={title}
      queryKey={`CloudBackupRestoreResults-${job?.Id}`}
      data={rows}
      simpleColumns={
        applied
          ? [
              'Name',
              'Area',
              'Section',
              'Action',
              'CloudBackupStatus',
              'Message',
            ]
          : ['Name', 'Area', 'Section', 'Action', 'Changes', 'NotFoundInTarget']
      }
      filters={areaFilters(rows)}
      offCanvas={{
        title: 'Restore Item Details',
        children: (row) => <RestoreItemDetails row={row} />,
      }}
      offCanvasOnRowClick={true}
    />
  )
}

const JobView = ({ jobId }) => {
  const jobState = useCloudBackupJob(jobId)
  const { job } = jobState
  const applied = job?.Type === 'Restore'
  return (
    <Stack spacing={2}>
      <CippPropertyListCard
        title={applied ? 'Restore' : 'Restore Preview'}
        isFetching={!job && jobState.request.isFetching}
        propertyItems={[
          { label: 'Type', value: cloudBackupJobTypeLabel(job?.Type) },
          {
            label: 'Status',
            value: job?.Status
              ? getCippFormatting(job.Status, 'CloudBackupStatus')
              : '',
          },
          { label: 'Backup of', value: job?.SourceTenant },
          { label: 'Restored to', value: job?.TargetTenant },
          { label: 'Requested by', value: job?.RequestedBy },
          {
            label: 'Started',
            value: job?.StartedAt
              ? getCippFormatting(job.StartedAt, 'CloudBackupStartedAt')
              : 'Not started',
          },
          {
            label: 'Summary',
            value: job ? cloudBackupJobSummary(job.Type, job.Summary) : '',
          },
        ]}
      />
      <CippCloudBackupJobStatus
        jobState={jobState}
        runningText="This job is still running."
      />
      {job?.Status === 'Completed' && (
        <>
          {!applied && (
            <Alert
              severity="info"
              action={
                <Button
                  component={Link}
                  href={`/cloud-backup/restore?RunId=${job.RunId}`}
                  color="inherit"
                  size="small"
                >
                  Open backup
                </Button>
              }
            >
              This is a saved preview. To restore, open the backup and run a new
              preview.
            </Alert>
          )}
          <RestoreResultsTable
            job={job}
            applied={applied}
            title={applied ? 'Restore results' : 'Restore preview'}
          />
        </>
      )}
    </Stack>
  )
}

const RestoreConfirmText = ({ targetName, sourceName, sameTenant, counts }) => (
  <Stack spacing={2}>
    <Typography>
      Restore to <strong>{targetName}</strong>: {counts.Create ?? 0} new,{' '}
      {counts.Update ?? 0} overwritten and {counts.CreateCopy ?? 0} created as
      copies. {counts.Skip ?? 0} skipped and {counts.NotRestorable ?? 0} cannot
      be restored.
    </Typography>
    {!sameTenant && (
      <Alert severity="warning">
        This backup is from {sourceName}, a different tenant. Groups and users
        are matched by name, and anything not found is left out.
      </Alert>
    )}
    <Typography variant="body2">
      Changes are made in the tenant straight away. CIPP does not undo them.
    </Typography>
  </Stack>
)

const RestoreWizard = ({ initialRunId }) => {
  const formControl = useForm({
    mode: 'onChange',
    defaultValues: {
      PolicyId: null,
      RunId: null,
      TargetTenant: null,
      Areas: [],
      ConflictAction: 'Skip',
      CAState: 'AsBackedUp',
    },
  })
  const [run, setRun] = useState(null)
  const [selectedRows, setSelectedRows] = useState([])
  const [preview, setPreview] = useState(null)
  const [applyJobId, setApplyJobId] = useState(null)
  const restoreDialog = useDialog()
  const { checkPermissions } = usePermissions()
  const canRestore = checkPermissions(RESTORE_PERMISSION)

  const snapshot = ApiGetCall({
    url: '/api/ListCloudBackupSnapshot',
    data: { RunId: run?.Id },
    queryKey: `ListCloudBackupSnapshot-${run?.Id}`,
    waiting: !!run,
  })
  const itemRows = useMemo(
    () => (Array.isArray(snapshot.data) ? snapshot.data : []).map(toItemRow),
    [snapshot.data]
  )
  const areaOptions = useMemo(
    () =>
      CLOUD_BACKUP_RESTORABLE_AREAS.filter((area) =>
        itemRows.some((row) => row.AreaId === area.value)
      ),
    [itemRows]
  )

  const [targetTenant, areas, conflictAction, caState] = useWatch({
    control: formControl.control,
    name: ['TargetTenant', 'Areas', 'ConflictAction', 'CAState'],
  })
  const targetId = cloudBackupOptionValue(targetTenant)
  const sameTenant = !run || !targetId || targetId === run.TenantId
  const areaValues = (areas ?? []).map(cloudBackupOptionValue)

  useEffect(() => {
    if (!run) return
    formControl.setValue('TargetTenant', {
      label: run.Tenant,
      value: run.TenantId,
    })
    setPreview(null)
    setApplyJobId(null)
  }, [run, formControl])

  useEffect(() => {
    formControl.setValue('Areas', areaOptions)
  }, [areaOptions, formControl])

  useEffect(() => {
    formControl.setValue('CAState', sameTenant ? 'AsBackedUp' : 'ReportOnly')
  }, [sameTenant, run, formControl])

  const selectedItems = selectedRows
    .filter((row) => areaValues.includes(row.AreaId))
    .map((row) => ({ Area: row.AreaId, Section: row.SectionId, Key: row.Key }))

  const requestBody = run
    ? {
        RunId: run.Id,
        TargetTenant: targetId,
        Areas: areaValues,
        ...(selectedItems.length > 0 && { Items: selectedItems }),
        ConflictAction: conflictAction,
        ...(areaValues.includes('ConditionalAccess') && { CAState: caState }),
        Mode: 'Preview',
      }
    : null
  const previewStale =
    !!preview && JSON.stringify(preview.body) !== JSON.stringify(requestBody)

  const previewPost = ApiPostCall({ relatedQueryKeys: ['ListCloudBackupJobs'] })
  const previewJob = useCloudBackupJob(preview?.jobId)
  const applyJob = useCloudBackupJob(applyJobId)

  const startPreview = () => {
    const body = requestBody
    setApplyJobId(null)
    previewPost.mutate(
      { url: '/api/ExecCloudBackupRestore', data: body },
      {
        onSuccess: (response) => {
          const jobId = response?.data?.JobId
          if (jobId) setPreview({ jobId, body })
        },
      }
    )
  }

  const counts = parseCloudBackupObject(previewJob.job?.Summary)
  const restoreCount =
    Number(counts.Create ?? 0) +
    Number(counts.Update ?? 0) +
    Number(counts.CreateCopy ?? 0)
  const previewDone = previewJob.job?.Status === 'Completed'
  const previewTargetName =
    previewJob.job?.TargetTenant ?? targetTenant?.label ?? targetId
  const previewSameTenant = preview?.body?.TargetTenant === run?.TenantId

  return (
    <Stack spacing={2}>
      <Card>
        <CardHeader title="Choose a backup" />
        <CardContent>
          <CippCloudBackupRunPicker
            formControl={formControl}
            initialRunId={initialRunId}
            onRunChange={setRun}
          />
        </CardContent>
      </Card>

      {run && (
        <>
          {snapshot.isError && (
            <Alert severity="error">
              The backup could not be read from the destination. Check that the
              destination is reachable on the Destinations page.
            </Alert>
          )}
          <CippDataTable
            title="Backup contents"
            queryKey={`CloudBackupSnapshotItems-${run.Id}`}
            data={itemRows}
            isFetching={snapshot.isFetching}
            refreshFunction={snapshot.refetch}
            simpleColumns={['Name', 'Area', 'Section']}
            filters={areaFilters(itemRows)}
            onChange={setSelectedRows}
            offCanvas={{
              title: 'Backup Item Details',
              children: (row) => <BackupItemDetails row={row} />,
            }}
            offCanvasOnRowClick={true}
          />

          {!canRestore ? (
            <Alert severity="info">
              You can browse this backup and compare it, but restoring needs the
              Cloud Backup restore permission. Ask a CIPP administrator if you
              need it.
            </Alert>
          ) : (
            <Card>
              <CardHeader title="Restore options" />
              <CardContent>
                <Stack spacing={3}>
                  <CippFormTenantSelector
                    formControl={formControl}
                    name="TargetTenant"
                    type="single"
                    valueField="customerId"
                    label="Restore to tenant"
                  />
                  {!sameTenant && (
                    <Alert severity="warning">
                      You are restoring to a different tenant than the backup
                      came from ({run.Tenant}). Groups and users are matched by
                      name, and anything not found is left out and reported.
                      Mailbox settings and permissions are only restored to the
                      tenant they came from.
                    </Alert>
                  )}
                  <CippFormComponent
                    type="autoComplete"
                    label="Areas to restore"
                    name="Areas"
                    formControl={formControl}
                    options={areaOptions}
                    multiple={true}
                    creatable={false}
                    helperText="SharePoint settings can be compared but not restored."
                  />
                  <Typography variant="body2">
                    {selectedItems.length > 0
                      ? `${selectedItems.length} selected ${selectedItems.length === 1 ? 'item' : 'items'} in these areas will be previewed.`
                      : 'No items selected: everything in these areas will be previewed.'}
                  </Typography>
                  <CippFormComponent
                    type="radio"
                    label="When an item already exists"
                    name="ConflictAction"
                    formControl={formControl}
                    options={CLOUD_BACKUP_CONFLICT_ACTIONS}
                  />
                  {areaValues.includes('ConditionalAccess') && (
                    <CippFormComponent
                      type="radio"
                      label="Conditional Access policy state after restore"
                      name="CAState"
                      formControl={formControl}
                      options={CLOUD_BACKUP_CA_STATES}
                    />
                  )}
                  <Box>
                    <Button
                      variant="contained"
                      onClick={startPreview}
                      disabled={
                        !targetId ||
                        areaValues.length === 0 ||
                        previewPost.isPending ||
                        previewJob.isActive
                      }
                      startIcon={<CippIcons.Visibility />}
                    >
                      Preview restore
                    </Button>
                  </Box>
                  <CippApiResults apiObject={previewPost} errorsOnly />
                </Stack>
              </CardContent>
            </Card>
          )}

          {preview && (
            <Card>
              <CardHeader
                title="Preview"
                subheader="Nothing has been changed yet. Review what a restore would do."
              />
              <CardContent>
                <Stack spacing={2}>
                  <CippCloudBackupJobStatus
                    jobState={previewJob}
                    runningText="Comparing the backup with the target tenant."
                  />
                  {previewDone && (
                    <>
                      <Typography variant="body2">
                        {cloudBackupJobSummary(
                          'RestorePreview',
                          previewJob.job.Summary
                        )}
                      </Typography>
                      <RestoreResultsTable
                        job={previewJob.job}
                        applied={false}
                        title="Restore preview"
                      />
                      {previewStale ? (
                        <Alert severity="warning">
                          The options or selected items changed after this
                          preview. Preview again before restoring.
                        </Alert>
                      ) : (
                        canRestore &&
                        !applyJobId && (
                          <Box>
                            <Button
                              variant="contained"
                              color="warning"
                              onClick={() => restoreDialog.handleOpen()}
                              disabled={restoreCount === 0}
                              startIcon={<CippIcons.Restore />}
                            >
                              {`Restore ${restoreCount} ${restoreCount === 1 ? 'item' : 'items'}`}
                            </Button>
                          </Box>
                        )
                      )}
                    </>
                  )}
                </Stack>
              </CardContent>
            </Card>
          )}

          {applyJobId && (
            <Card>
              <CardHeader title="Restore" />
              <CardContent>
                <Stack spacing={2}>
                  <CippCloudBackupJobStatus
                    jobState={applyJob}
                    runningText="Restoring. This page updates by itself."
                  />
                  {applyJob.job?.Status === 'Completed' && (
                    <>
                      <Typography variant="body2">
                        {cloudBackupJobSummary('Restore', applyJob.job.Summary)}
                      </Typography>
                      <RestoreResultsTable
                        job={applyJob.job}
                        applied={true}
                        title="Restore results"
                      />
                    </>
                  )}
                </Stack>
              </CardContent>
            </Card>
          )}

          {preview && (
            <CippApiDialog
              createDialog={restoreDialog}
              title="Restore configuration"
              relatedQueryKeys={['ListCloudBackupJobs']}
              api={{
                type: 'POST',
                url: '/api/ExecCloudBackupRestore',
                customDataformatter: () => ({
                  ...preview.body,
                  Mode: 'Apply',
                  PreviewJobId: preview.jobId,
                }),
                confirmText: (
                  <RestoreConfirmText
                    targetName={previewTargetName}
                    sourceName={run.Tenant}
                    sameTenant={previewSameTenant}
                    counts={counts}
                  />
                ),
              }}
              dialogAfterEffect={(data) => {
                if (data?.JobId) setApplyJobId(data.JobId)
              }}
            />
          )}
        </>
      )}
    </Stack>
  )
}

const Page = () => {
  const router = useRouter()
  const { JobId, RunId } = router.query
  return (
    <>
      <CippHead title="Restore" noTenant />
      <Container maxWidth={false}>
        {JobId ? (
          <JobView jobId={JobId} />
        ) : (
          <RestoreWizard initialRunId={RunId} />
        )}
      </Container>
    </>
  )
}

Page.getLayout = (page) => (
  <DashboardLayout usesTenant={false}>{page}</DashboardLayout>
)

export default Page
