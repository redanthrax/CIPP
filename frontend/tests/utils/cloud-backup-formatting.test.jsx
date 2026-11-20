import {
  getCippFormatting,
  isCippDateColumn,
} from '../../src/utils/get-cipp-formatting'
import { getCippTranslation } from '../../src/utils/get-cipp-translation'

describe('shared columns keep their formatting', () => {
  it('renders Status values Running and Succeeded as plain default chips', () => {
    for (const value of ['Running', 'Succeeded', 'PartialSuccess']) {
      expect(getCippFormatting(value, 'Status', 'text')).toBe(value)
      const chip = getCippFormatting(value, 'Status')
      expect(chip.props.label).toBe(value)
      expect(chip.props.color).toBe('default')
    }
  })

  it('leaves StartedAt, CompletedAt and Bytes values as they are', () => {
    const date = '2026-11-19T02:00:00Z'
    expect(getCippFormatting(date, 'StartedAt', 'text')).toBe(date)
    expect(getCippFormatting(date, 'StartedAt').props.children).toBe(date)
    expect(getCippFormatting(date, 'CompletedAt', 'text')).toBe(date)
    expect(isCippDateColumn('StartedAt')).toBe(false)
    expect(isCippDateColumn('CompletedAt')).toBe(false)
    expect(getCippFormatting(2621440, 'Bytes', 'text')).toBe('2621440')
    expect(getCippFormatting(1073741824, 'LatestBytes', 'text')).toBe(
      '1073741824'
    )
  })

  it('leaves the headers of shared keys untranslated', () => {
    expect(getCippTranslation('Bytes')).toBe('Bytes')
    expect(getCippTranslation('RetentionDays')).toBe('Retention Days')
    expect(getCippTranslation('LastRunAt')).toBe('Last Run At')
    expect(getCippTranslation('PolicyCount')).toBe('Policy Count')
  })
})

describe('Cloud Backup columns', () => {
  it('colours backup results', () => {
    const colors = {
      Succeeded: 'success',
      Passed: 'success',
      PartialSuccess: 'warning',
      Skipped: 'warning',
      Running: 'info',
      Failed: 'error',
      Queued: 'default',
      Completed: 'default',
    }
    for (const [value, color] of Object.entries(colors)) {
      expect(getCippFormatting(value, 'CloudBackupStatus').props.color).toBe(
        color
      )
    }
    expect(
      getCippFormatting('PartialSuccess', 'CloudBackupStatus', 'text')
    ).toBe('Partial success')
    expect(getCippFormatting('Failed', 'CloudBackupLastTest', 'text')).toBe(
      'Failed'
    )
    expect(
      getCippFormatting('Succeeded', 'CloudBackupLastResult').props.color
    ).toBe('success')
  })

  it('formats sizes and dates', () => {
    expect(getCippFormatting(2621440, 'CloudBackupSize', 'text')).toBe('2.5 MB')
    expect(getCippFormatting(null, 'CloudBackupSize', 'text')).toBe('—')
    expect(isCippDateColumn('CloudBackupStartedAt')).toBe(true)
    expect(isCippDateColumn('CloudBackupLastRun')).toBe(true)
    expect(getCippTranslation('CloudBackupSize')).toBe('Size')
    expect(getCippTranslation('CloudBackupStartedAt')).toBe('Started At')
  })
})
