import { useEffect, useMemo, useRef } from 'react'
import { useWatch } from 'react-hook-form'
import { Grid } from '@mui/material'
import CippFormComponent from './CippFormComponent'
import { ApiGetCall } from '../../api/ApiCall'
import { cloudBackupOptionValue } from '../../utils/cloud-backup'

const RESTORABLE_STATUSES = ['Succeeded', 'PartialSuccess']

const runLabel = (run) => {
  const started = run.StartedAt
    ? new Date(run.StartedAt).toLocaleString()
    : 'Unknown time'
  const partial = run.Status === 'PartialSuccess' ? ' (partial)' : ''
  return `${started} - ${run.Tenant}${partial}`
}

export const CippCloudBackupRunPicker = ({
  formControl,
  prefix = '',
  initialRunId,
  onRunChange,
  runLabelText = 'Backup',
}) => {
  const policyField = `${prefix}PolicyId`
  const runField = `${prefix}RunId`
  const policyId = cloudBackupOptionValue(
    useWatch({ control: formControl.control, name: policyField })
  )
  const runId = cloudBackupOptionValue(
    useWatch({ control: formControl.control, name: runField })
  )

  const policies = ApiGetCall({
    url: '/api/ListCloudBackupPolicies',
    queryKey: 'ListCloudBackupPolicies-picker',
  })
  const runs = ApiGetCall({
    url: '/api/ListCloudBackupRuns',
    data: { PolicyId: policyId },
    queryKey: `ListCloudBackupRuns-picker-${policyId}`,
    waiting: !!policyId,
  })

  const policyOptions = useMemo(
    () =>
      (Array.isArray(policies.data) ? policies.data : []).map((policy) => ({
        label: policy.Name,
        value: policy.Id,
      })),
    [policies.data]
  )
  const runList = useMemo(
    () =>
      (Array.isArray(runs.data) ? runs.data : []).filter((run) =>
        RESTORABLE_STATUSES.includes(run.Status)
      ),
    [runs.data]
  )
  const runOptions = runList.map((run) => ({
    label: runLabel(run),
    value: run.Id,
  }))
  const run = runList.find((item) => item.Id === runId)
  const initialRunApplied = useRef(false)

  useEffect(() => {
    if (!initialRunId || policyId) return
    const initialPolicy = policyOptions.find(
      (option) => option.value === initialRunId.slice(0, 36)
    )
    if (initialPolicy) formControl.setValue(policyField, initialPolicy)
  }, [initialRunId, policyId, policyOptions, policyField, formControl])

  useEffect(() => {
    if (!runs.isSuccess || !policyId) return
    if (!runId && initialRunId && !initialRunApplied.current) {
      const initialRun = runList.find((item) => item.Id === initialRunId)
      if (initialRun) {
        initialRunApplied.current = true
        formControl.setValue(runField, {
          label: runLabel(initialRun),
          value: initialRun.Id,
        })
      }
    } else if (runId && !run) {
      formControl.setValue(runField, null)
    }
  }, [
    runs.isSuccess,
    runList,
    policyId,
    runId,
    run,
    initialRunId,
    runField,
    formControl,
  ])

  useEffect(() => {
    onRunChange?.(run ?? null)
  }, [run, onRunChange])

  return (
    <Grid container spacing={2}>
      <Grid size={{ xs: 12, md: 6 }}>
        <CippFormComponent
          type="select"
          label="Policy"
          name={policyField}
          formControl={formControl}
          options={policyOptions}
          isFetching={policies.isFetching}
          placeholder="Choose a backup policy"
        />
      </Grid>
      <Grid size={{ xs: 12, md: 6 }}>
        <CippFormComponent
          type="select"
          label={runLabelText}
          name={runField}
          formControl={formControl}
          options={runOptions}
          isFetching={runs.isFetching}
          disabled={!policyId}
          placeholder="Choose a backup"
        />
      </Grid>
    </Grid>
  )
}
