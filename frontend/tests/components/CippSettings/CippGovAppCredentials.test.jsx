import React from 'react'
import { screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { renderWithTheme } from '../../test-utils'
import { CippGovAppCredentials, toPem } from '../../../src/components/CippSettings/CippGovAppCredentials'

vi.mock('../../../src/api/ApiCall', async () => (await import('../../mocks/api-call')).apiCallMock())
import { api, getResult, postResult } from '../../mocks/api-call'

vi.mock('../../../src/components/CippComponents/CippApiResults', () => ({ CippApiResults: () => null }))
vi.mock('../../../src/components/CippComponents/CippCopyToClipboard', () => ({
  CippCopyToClipBoard: ({ text }) => <span>{text}</span>,
}))

const GOV_APP_ID = '0a0a0a0a-1111-2222-3333-444444444444'

// redanthrax/CIPP#2: Azure Government app credentials on the Credentials page.
describe('CippGovAppCredentials', () => {
  let post

  beforeEach(() => {
    post = postResult()
    api.post = post
  })

  it('shows not configured', () => {
    api.get = getResult({ data: { Results: { configured: false, hasSecret: false, certificate: { configured: false }, authority: 'https://login.microsoftonline.us/organizations', redirectUri: 'https://cipp.example/authredirect' } } })
    renderWithTheme(<CippGovAppCredentials />)
    expect(screen.getByText('Not configured')).toBeInTheDocument()
    expect(screen.getByText('https://cipp.example/authredirect')).toBeInTheDocument()
    expect(screen.getByText('https://login.microsoftonline.us/organizations')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Save' })).toBeDisabled()
  })

  it('saves the application id and secret through ExecGovAppCredentials', async () => {
    api.get = getResult({ data: { Results: { configured: false, hasSecret: false, certificate: { configured: false } } } })
    renderWithTheme(<CippGovAppCredentials />)

    await userEvent.type(screen.getByLabelText('Application (client) ID'), GOV_APP_ID)
    await userEvent.type(screen.getByLabelText('Client secret'), 's3cret')
    await userEvent.click(screen.getByRole('button', { name: 'Save' }))

    expect(post.mutate).toHaveBeenCalledWith({
      url: '/api/ExecGovAppCredentials',
      data: { Action: 'Save', applicationId: GOV_APP_ID, applicationSecret: 's3cret' },
    })
  })

  it('does not send a secret when the field is left empty', async () => {
    api.get = getResult({ data: { Results: { configured: true, applicationId: GOV_APP_ID, hasSecret: true, certificate: { configured: false } } } })
    renderWithTheme(<CippGovAppCredentials />)

    await userEvent.click(screen.getByRole('button', { name: 'Save' }))

    expect(post.mutate).toHaveBeenCalledWith({
      url: '/api/ExecGovAppCredentials',
      data: { Action: 'Save', applicationId: GOV_APP_ID },
    })
    expect(screen.getByText('Configured')).toBeInTheDocument()
    expect(screen.getByText('Stored')).toBeInTheDocument()
  })

  it('generates a certificate and offers the public part for download', async () => {
    api.get = getResult({ data: { Results: { configured: true, applicationId: GOV_APP_ID, hasSecret: false, certificate: { configured: true, thumbprint: 'ABC', notAfter: '2027-01-01', publicCertificate: 'TUlJQg==' } } } })
    renderWithTheme(<CippGovAppCredentials />)

    expect(screen.getByRole('button', { name: 'Download certificate' })).toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: 'Generate new certificate' }))
    expect(post.mutate).toHaveBeenCalledWith({ url: '/api/ExecGovAppCredentials', data: { Action: 'GenerateCertificate' } })
  })

  it('wraps the certificate as PEM', () => {
    expect(toPem('QUJD')).toBe('-----BEGIN CERTIFICATE-----\nQUJD\n-----END CERTIFICATE-----\n')
  })
})
