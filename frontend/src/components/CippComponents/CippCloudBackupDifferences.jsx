import {
  Alert,
  Box,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableRow,
} from '@mui/material'
import { formatCloudBackupValue } from '../../utils/cloud-backup'

export const CippCloudBackupDifferences = ({
  differences,
  otherSideLabel = 'Current',
}) => {
  const rows = Array.isArray(differences) ? differences : []
  if (rows.length === 0) {
    return (
      <Alert severity="info">
        No setting differences. The item exists on one side only, or matches.
      </Alert>
    )
  }
  return (
    <Box sx={{ overflowX: 'auto' }}>
      <Table size="small">
        <TableHead>
          <TableRow>
            <TableCell>Setting</TableCell>
            <TableCell>In backup</TableCell>
            <TableCell>{otherSideLabel}</TableCell>
          </TableRow>
        </TableHead>
        <TableBody>
          {rows.map((difference, index) => (
            <TableRow key={`${difference.Path}-${index}`}>
              <TableCell sx={{ wordBreak: 'break-word' }}>
                {difference.Path}
              </TableCell>
              <TableCell sx={{ wordBreak: 'break-word' }}>
                {formatCloudBackupValue(difference.Reference)}
              </TableCell>
              <TableCell sx={{ wordBreak: 'break-word' }}>
                {formatCloudBackupValue(difference.Difference)}
              </TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
    </Box>
  )
}
