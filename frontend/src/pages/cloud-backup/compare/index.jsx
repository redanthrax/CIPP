import { useEffect, useMemo, useState } from 'react'
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
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableRow,
} from '@mui/material'
import { Layout as DashboardLayout } from '../../../layouts/index'
import { CippHead } from '../../../components/CippComponents/CippHead'
import { CippDataTable } from '../../../components/CippTable/CippDataTable'
import { CippPropertyListCard } from '../../../components/CippCards/CippPropertyListCard'
import CippFormComponent from '../../../components/CippComponents/CippFormComponent'
import { CippApiResults } from '../../../components/CippComponents/CippApiResults'
import { CippCloudBackupRunPicker } from '../../../components/CippComponents/CippCloudBackupRunPicker'
import { CippCloudBackupDifferences } from '../../../components/CippComponents/CippCloudBackupDifferences'
import { CippCloudBackupJobStatus } from '../../../components/CippComponents/CippCloudBackupJobStatus'
import { ApiPostCall } from '../../../api/ApiCall'
import { useCloudBackupJob } from '../../../hooks/use-cloud-backup-job'
import { getCippFormatting } from '../../../utils/get-cipp-formatting'
import { CippIcons } from '../../../utils/icon-registry'
import {
  CLOUD_BACKUP_AREAS,
  cloudBackupAreaLabel,
  cloudBackupChangeLabel,
  cloudBackupOptionValue,
  parseCloudBackupList,
  parseCloudBackupObject,
} from '../../../utils/cloud-backup'

const COMPARE_TARGETS = [
  { label: 'Current tenant configuration', value: 'Live' },
  { label: 'Another backup', value: 'Run' },
]

const otherSideName = (job) =>
  job?.CompareToRunId ? 'other backup' : 'current'

const CompareItemDetails = ({ row, otherSide }) => (
  <Stack spacing={2}>
    <CippPropertyListCard
      cardSx={{ p: 0, m: -2 }}
      title="Compared Item"
      propertyItems={[
        { label: 'Name', value: row.Name },
        { label: 'Area', value: row.Area },
        { label: 'Section', value: row.Section },
        { label: 'Difference', value: row.Change },
      ]}
    />
    <Card>
      <CardHeader title="Setting differences" />
      <CardContent>
        <CippCloudBackupDifferences
          differences={row.DifferenceList}
          otherSideLabel={otherSide === 'current' ? 'Current' : 'Other backup'}
        />
      </CardContent>
    </Card>
  </Stack>
)

const CompareResults = ({ job }) => {
  const otherSide = otherSideName(job)
  const summary = parseCloudBackupObject(job.Summary)
  const rows = useMemo(
    () =>
      parseCloudBackupList(job.Result).map((row) => {
        const differences = parseCloudBackupList(row.Differences)
        return {
          Name: row.Name ?? row.Key,
          Area: cloudBackupAreaLabel(row.Area),
          Section: row.SectionLabel ?? row.Section,
          Change: cloudBackupChangeLabel(row.Change, otherSide),
          Changes: differences.length,
          DifferenceList: differences,
        }
      }),
    [job.Result, otherSide]
  )
  const areas = Object.keys(summary)

  return (
    <Stack spacing={2}>
      <Card>
        <CardHeader title="Summary per area" />
        <CardContent sx={{ p: 0, overflowX: 'auto' }}>
          {areas.length === 0 ? (
            <Alert severity="info" sx={{ m: 2 }}>
              Nothing was compared.
            </Alert>
          ) : (
            <Table size="small">
              <TableHead>
                <TableRow>
                  <TableCell>Area</TableCell>
                  <TableCell align="right">Changed</TableCell>
                  <TableCell align="right">{`Only in ${otherSide}`}</TableCell>
                  <TableCell align="right">Only in backup</TableCell>
                  <TableCell align="right">Same</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                {areas.map((area) => (
                  <TableRow key={area}>
                    <TableCell>{cloudBackupAreaLabel(area)}</TableCell>
                    <TableCell align="right">
                      {summary[area]?.Changed ?? 0}
                    </TableCell>
                    <TableCell align="right">
                      {summary[area]?.Added ?? 0}
                    </TableCell>
                    <TableCell align="right">
                      {summary[area]?.Removed ?? 0}
                    </TableCell>
                    <TableCell align="right">
                      {summary[area]?.Unchanged ?? 0}
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>
      <CippDataTable
        title="Differences"
        queryKey={`CloudBackupCompareResults-${job.Id}`}
        data={rows}
        simpleColumns={['Name', 'Area', 'Section', 'Change', 'Changes']}
        offCanvas={{
          title: 'Difference Details',
          children: (row) => (
            <CompareItemDetails row={row} otherSide={otherSide} />
          ),
        }}
        offCanvasOnRowClick={true}
      />
    </Stack>
  )
}

const JobView = ({ jobId }) => {
  const jobState = useCloudBackupJob(jobId)
  const { job } = jobState
  return (
    <Stack spacing={2}>
      <CippPropertyListCard
        title="Comparison"
        isFetching={!job && jobState.request.isFetching}
        propertyItems={[
          { label: 'Tenant', value: job?.SourceTenant },
          {
            label: 'Compared with',
            value: job?.CompareToRunId
              ? 'Another backup'
              : 'Current tenant configuration',
          },
          {
            label: 'Status',
            value: job?.Status
              ? getCippFormatting(job.Status, 'CloudBackupStatus')
              : '',
          },
          { label: 'Requested by', value: job?.RequestedBy },
          {
            label: 'Started',
            value: job?.StartedAt
              ? getCippFormatting(job.StartedAt, 'CloudBackupStartedAt')
              : 'Not started',
          },
        ]}
      />
      <CippCloudBackupJobStatus
        jobState={jobState}
        runningText="This comparison is still running."
      />
      {job?.Status === 'Completed' && <CompareResults job={job} />}
    </Stack>
  )
}

const CompareWizard = ({ initialRunId }) => {
  const formControl = useForm({
    mode: 'onChange',
    defaultValues: {
      PolicyId: null,
      RunId: null,
      CompareTo: 'Live',
      OtherPolicyId: null,
      OtherRunId: null,
      Areas: [],
    },
  })
  const [run, setRun] = useState(null)
  const [otherRun, setOtherRun] = useState(null)
  const [jobId, setJobId] = useState(null)
  const comparePost = ApiPostCall({ relatedQueryKeys: ['ListCloudBackupJobs'] })
  const jobState = useCloudBackupJob(jobId)

  const [compareTo, areas] = useWatch({
    control: formControl.control,
    name: ['CompareTo', 'Areas'],
  })
  const areaValues = (areas ?? []).map(cloudBackupOptionValue)
  const areaOptions = useMemo(() => {
    const inRun = parseCloudBackupList(run?.Areas).map((area) => area.Area)
    return CLOUD_BACKUP_AREAS.filter((area) => inRun.includes(area.value))
  }, [run])

  useEffect(() => {
    formControl.setValue('Areas', areaOptions)
    setJobId(null)
  }, [areaOptions, formControl])

  const compareToValue = compareTo === 'Run' ? otherRun?.Id : 'Live'
  const canStart =
    !!run &&
    !!compareToValue &&
    compareToValue !== run.Id &&
    areaValues.length > 0 &&
    !comparePost.isPending &&
    !jobState.isActive

  const startCompare = () => {
    comparePost.mutate(
      {
        url: '/api/ExecCloudBackupCompare',
        data: { RunId: run.Id, CompareTo: compareToValue, Areas: areaValues },
      },
      {
        onSuccess: (response) => {
          if (response?.data?.JobId) setJobId(response.data.JobId)
        },
      }
    )
  }

  return (
    <Stack spacing={2}>
      <Card>
        <CardHeader title="Compare a backup" />
        <CardContent>
          <Stack spacing={3}>
            <CippCloudBackupRunPicker
              formControl={formControl}
              initialRunId={initialRunId}
              onRunChange={setRun}
            />
            <CippFormComponent
              type="radio"
              label="Compare with"
              name="CompareTo"
              formControl={formControl}
              options={COMPARE_TARGETS}
            />
            {compareTo === 'Run' && (
              <CippCloudBackupRunPicker
                formControl={formControl}
                prefix="Other"
                runLabelText="Other backup"
                onRunChange={setOtherRun}
              />
            )}
            {compareTo === 'Run' &&
              otherRun &&
              run &&
              otherRun.TenantId !== run.TenantId && (
                <Alert severity="info">
                  The backups are from different tenants, so items are matched
                  by name.
                </Alert>
              )}
            <CippFormComponent
              type="autoComplete"
              label="Areas to compare"
              name="Areas"
              formControl={formControl}
              options={areaOptions}
              multiple={true}
              creatable={false}
            />
            <Box>
              <Button
                variant="contained"
                onClick={startCompare}
                disabled={!canStart}
                startIcon={<CippIcons.CompareArrows />}
              >
                Compare
              </Button>
            </Box>
            <CippApiResults apiObject={comparePost} errorsOnly />
          </Stack>
        </CardContent>
      </Card>
      {jobId && (
        <>
          <CippCloudBackupJobStatus
            jobState={jobState}
            runningText="Comparing. This page updates by itself."
          />
          {jobState.job?.Status === 'Completed' && (
            <CompareResults job={jobState.job} />
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
      <CippHead title="Compare" noTenant />
      <Container maxWidth={false}>
        {JobId ? (
          <JobView jobId={JobId} />
        ) : (
          <CompareWizard initialRunId={RunId} />
        )}
      </Container>
    </>
  )
}

Page.getLayout = (page) => (
  <DashboardLayout usesTenant={false}>{page}</DashboardLayout>
)

export default Page
