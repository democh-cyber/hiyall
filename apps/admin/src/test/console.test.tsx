import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router'
import { describe, expect, it, vi } from 'vitest'
import { App } from '../App'
import { member, mockApi, operator, row, session, theCase } from './mockApi'

function renderAt(path: string) {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <App />
    </MemoryRouter>,
  )
}

const signedIn = (role: 'viewer' | 'moderator' | 'admin') => ({ 'GET /me': () => ({ data: session(role) }) })

describe('sign in', () => {
  it('takes the password first, then the code, and sends them in one request', async () => {
    const user = userEvent.setup()
    const { calls } = mockApi({
      'GET /me': () => ({ status: 401, error: { code: 'UNAUTHENTICATED', message: 'Sign in to continue' } }),
      'POST /login': () => ({ data: session('moderator') }),
      'GET /reports*': () => ({ data: { items: [], nextCursor: null, hasMore: false } }),
    })
    renderAt('/')
    await user.type(await screen.findByLabelText('Email'), 'sam@hiyall.test')
    await user.type(screen.getByLabelText('Password'), 'correct horse battery')
    expect(screen.queryByLabelText('Authenticator code')).not.toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Continue' }))
    await user.type(screen.getByLabelText('Authenticator code'), '123456')
    await user.click(screen.getByRole('button', { name: 'Sign in' }))
    await screen.findByRole('heading', { name: 'Reports' })
    const login = calls.find((c) => c.path === '/login')!
    expect(login.body).toEqual({ email: 'sam@hiyall.test', password: 'correct horse battery', code: '123456' })
    expect(screen.getByText('Sam · moderator')).toBeInTheDocument()
  })

  it('shows one generic error and returns to the password step', async () => {
    const user = userEvent.setup()
    mockApi({
      'GET /me': () => ({ status: 401, error: { code: 'UNAUTHENTICATED', message: 'x' } }),
      'POST /login': () => ({ status: 401, error: { code: 'SIGN_IN_FAILED', message: 'Sign-in failed' } }),
    })
    renderAt('/')
    await user.type(await screen.findByLabelText('Email'), 'a@b.test')
    await user.type(screen.getByLabelText('Password'), 'whatever password')
    await user.click(screen.getByRole('button', { name: 'Continue' }))
    await user.type(screen.getByLabelText('Authenticator code'), '000000')
    await user.click(screen.getByRole('button', { name: 'Sign in' }))
    expect(await screen.findByRole('alert')).toHaveTextContent('Sign-in failed. Check your details and try again.')
    expect(screen.getByLabelText('Password')).toHaveValue('')
  })
})

describe('queue', () => {
  it('lists reports with minor and severity flags, filters, and pages with the cursor', async () => {
    const user = userEvent.setup()
    const { calls } = mockApi({
      ...signedIn('viewer'),
      'GET /reports*': (c) => c.path.includes('cursor=next1')
        ? { data: { items: [row({ reportId: '019a0000-0000-7000-8000-00000000000b', reasonCode: 'spam' })], nextCursor: null, hasMore: false } }
        : { data: { items: [row({ reportId: '019a0000-0000-7000-8000-00000000000a', minor: true, severity: 'high', evidenceCount: 2 })], nextCursor: 'next1', hasMore: true } },
    })
    renderAt('/')
    const table = await screen.findByRole('table')
    expect(within(table).getByText('minor')).toBeInTheDocument()
    expect(within(table).getByText('high')).toBeInTheDocument()
    expect(within(table).getByText('2 shared')).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Load more' }))
    await waitFor(() => expect(screen.getAllByRole('row')).toHaveLength(3))
    expect(calls.at(-1)!.path).toContain('cursor=next1')
    expect(screen.queryByRole('button', { name: 'Load more' })).not.toBeInTheDocument()

    await user.selectOptions(screen.getByLabelText('Severity'), 'high')
    await waitFor(() => expect(calls.at(-1)!.path).toContain('severity=high'))
    await user.click(screen.getByLabelText('Involves a minor'))
    await waitFor(() => expect(calls.at(-1)!.path).toContain('minor=true'))
  })

  it('moves between rows with j and k', async () => {
    const user = userEvent.setup()
    mockApi({
      ...signedIn('viewer'),
      'GET /reports*': () => ({ data: { items: [row({ reportId: '019a0000-0000-7000-8000-00000000000a' }), row({ reportId: '019a0000-0000-7000-8000-00000000000b' })], nextCursor: null, hasMore: false } }),
    })
    renderAt('/')
    await screen.findByRole('table')
    await user.keyboard('j')
    expect(screen.getByRole('link', { name: '0000000a' })).toHaveFocus()
    await user.keyboard('j')
    expect(screen.getByRole('link', { name: '0000000b' })).toHaveFocus()
    await user.keyboard('k')
    expect(screen.getByRole('link', { name: '0000000a' })).toHaveFocus()
  })
})

describe('case', () => {
  const id = '019a0000-0000-7000-8000-000000000001'

  it('shows only what was shared, and images by id, size and hash', async () => {
    mockApi({ ...signedIn('viewer'), [`GET /reports/${id}`]: () => ({ data: theCase() }) })
    renderAt(`/reports/${id}`)
    expect(await screen.findByText('the shared message text')).toBeInTheDocument()
    expect(screen.getByText('involves a minor')).toBeInTheDocument()
    expect(screen.getByText('b-1', { selector: 'code' })).toBeInTheDocument()
    expect(screen.getByText('2.0 KiB')).toBeInTheDocument()
    expect(screen.getByText('q6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6s=')).toBeInTheDocument()
    expect(screen.getByText(/Encrypted and not viewable here/)).toBeInTheDocument()
    // A viewer can read but not act.
    expect(screen.queryByRole('button', { name: 'Dismiss' })).not.toBeInTheDocument()
    expect(screen.getByText('Your role can read cases but not act on them.')).toBeInTheDocument()
  })

  it('needs a reason of at least 10 characters before a warning can be sent', async () => {
    const user = userEvent.setup()
    const { calls } = mockApi({
      ...signedIn('moderator'),
      [`GET /reports/${id}`]: () => ({ data: theCase() }),
      [`POST /reports/${id}/resolve`]: () => ({ data: { reportId: id, action: 'warn' } }),
    })
    renderAt(`/reports/${id}`)
    await user.click(await screen.findByRole('button', { name: 'Warn' }))
    const dialog = screen.getByRole('dialog', { name: 'Warn the member' })
    const submit = within(dialog).getByRole('button', { name: 'Record warning' })
    expect(submit).toBeDisabled()
    await user.type(within(dialog).getByLabelText(/Reason/), 'too short')
    expect(submit).toBeDisabled()
    await user.type(within(dialog).getByLabelText(/Reason/), ' and now long enough')
    expect(submit).toBeEnabled()
    await user.click(submit)
    await waitFor(() => expect(calls.some((c) => c.method === 'POST')).toBe(true))
    const post = calls.find((c) => c.method === 'POST')!
    expect(post.body).toEqual({ action: 'warn', reason: 'too short and now long enough' })
    expect(post.headers['X-CSRF-Token']).toBe('csrf-123')
    expect(await screen.findByText('Marked as warned.')).toBeInTheDocument()
  })

  it('makes suspend a two step action: a reason, then an explicit confirmation', async () => {
    const user = userEvent.setup()
    const { calls } = mockApi({
      ...signedIn('moderator'),
      [`GET /reports/${id}`]: () => ({ data: theCase() }),
      [`POST /reports/${id}/resolve`]: () => ({ data: { reportId: id, action: 'suspend' } }),
    })
    renderAt(`/reports/${id}`)
    await user.click(await screen.findByRole('button', { name: 'Suspend member…' }))
    const dialog = screen.getByRole('dialog', { name: 'Suspend the member' })
    await user.type(within(dialog).getByLabelText(/Reason/), 'credible threat against another member')
    const submit = within(dialog).getByRole('button', { name: 'Suspend member' })
    expect(submit).toBeDisabled()
    await user.click(within(dialog).getByLabelText(/I confirm I am suspending @bob/))
    expect(submit).toBeEnabled()
    await user.click(submit)
    await waitFor(() => expect(calls.some((c) => c.method === 'POST')).toBe(true))
    expect(calls.find((c) => c.method === 'POST')!.body).toEqual({ action: 'suspend', reason: 'credible threat against another member', confirm: true })
  })

  it('closes the dialog with Escape and sends nothing', async () => {
    const user = userEvent.setup()
    const { calls } = mockApi({ ...signedIn('moderator'), [`GET /reports/${id}`]: () => ({ data: theCase() }) })
    renderAt(`/reports/${id}`)
    await user.click(await screen.findByRole('button', { name: 'Dismiss' }))
    expect(screen.getByRole('dialog')).toBeInTheDocument()
    await user.keyboard('{Escape}')
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    expect(calls.some((c) => c.method === 'POST')).toBe(false)
  })

  it('shows a server refusal inside the dialog', async () => {
    const user = userEvent.setup()
    mockApi({
      ...signedIn('moderator'),
      [`GET /reports/${id}`]: () => ({ data: theCase() }),
      [`POST /reports/${id}/resolve`]: () => ({ status: 409, error: { code: 'REPORT_CLOSED', message: 'This report is already resolved' } }),
    })
    renderAt(`/reports/${id}`)
    await user.click(await screen.findByRole('button', { name: 'Dismiss' }))
    await user.type(screen.getByLabelText(/Reason/), 'not a violation of the rules')
    await user.click(screen.getByRole('button', { name: 'Dismiss report' }))
    expect(await within(screen.getByRole('dialog')).findByRole('alert')).toHaveTextContent('This report is already resolved')
  })

  it('offers no actions on a report that is already resolved', async () => {
    mockApi({ ...signedIn('moderator'), [`GET /reports/${id}`]: () => ({ data: theCase({ status: 'dismissed', resolutionCode: 'dismiss' }) }) })
    renderAt(`/reports/${id}`)
    await screen.findByText('the shared message text')
    expect(screen.queryByRole('button', { name: 'Warn' })).not.toBeInTheDocument()
  })
})

describe('admin pages', () => {
  it('keeps the audit log and operators away from other roles', async () => {
    mockApi({ ...signedIn('moderator'), 'GET /reports*': () => ({ data: { items: [], nextCursor: null, hasMore: false } }) })
    renderAt('/operators')
    expect(await screen.findByText('Your role does not allow this page.')).toBeInTheDocument()
    expect(screen.queryByRole('link', { name: 'Operators' })).not.toBeInTheDocument()
    expect(screen.queryByRole('link', { name: 'Audit log' })).not.toBeInTheDocument()
  })

  it('changes an operator role with a reason, and cannot disable yourself', async () => {
    const user = userEvent.setup()
    const other = { ...operator('viewer'), operatorId: 'op-2', email: 'kim@hiyall.test', displayName: 'Kim' }
    const { calls } = mockApi({
      ...signedIn('admin'),
      'GET /operators': () => ({ data: { items: [operator('admin'), other] } }),
      'POST /operators/op-2/role': () => ({ data: { operator: { ...other, role: 'moderator' } } }),
    })
    renderAt('/operators')
    await screen.findByText('Kim')
    const rows = screen.getAllByRole('row')
    expect(within(rows[1]).getByRole('button', { name: 'Disable' })).toBeDisabled()
    await user.selectOptions(screen.getByLabelText('Role of kim@hiyall.test'), 'moderator')
    await user.click(screen.getByRole('button', { name: 'Change role' }))
    await user.type(screen.getByLabelText(/Reason/), 'covering the evening queue')
    await user.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Change role' }))
    await waitFor(() => expect(calls.some((c) => c.method === 'POST')).toBe(true))
    expect(calls.find((c) => c.method === 'POST')!.body).toEqual({ role: 'moderator', reason: 'covering the evening queue' })
  })

  it('shows the audit log to an administrator', async () => {
    mockApi({
      ...signedIn('admin'),
      'GET /audit*': () => ({ data: { items: [{ auditId: 5, at: '2026-10-12T10:00:00Z', operatorId: 'op-1', actor: 'sam@hiyall.test', action: 'case_view', targetType: 'report', targetId: 'r-1', reason: '', ip: '10.0.0.0/24', detail: {} }], nextCursor: null, hasMore: false } }),
    })
    renderAt('/audit')
    expect(await screen.findByText('case_view')).toBeInTheDocument()
    expect(screen.getByText('10.0.0.0/24')).toBeInTheDocument()
  })
})

describe('user view', () => {
  it('lets a moderator restore a suspended member with a reason', async () => {
    const user = userEvent.setup()
    const { calls } = mockApi({
      ...signedIn('moderator'),
      'GET /users/u-1': () => ({ data: { user: { ...member({ status: 'suspended' }), activeSessions: 0, reports: [], actions: [] } } }),
      'POST /users/u-1/restore': () => ({ data: { userId: 'u-1', status: 'active' } }),
    })
    renderAt('/users/u-1')
    await user.click(await screen.findByRole('button', { name: 'Restore account…' }))
    await user.type(screen.getByLabelText(/Reason/), 'appeal upheld after review')
    await user.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Restore account' }))
    await waitFor(() => expect(calls.some((c) => c.method === 'POST')).toBe(true))
    expect(calls.find((c) => c.method === 'POST')!.body).toEqual({ reason: 'appeal upheld after review' })
    expect(screen.getByText(/Messages, location, visitors and contact details are not available/)).toBeInTheDocument()
  })

  it('returns to sign-in when the session ends mid-use', async () => {
    mockApi({
      ...signedIn('viewer'),
      'GET /users/u-1': () => ({ status: 401, error: { code: 'UNAUTHENTICATED', message: 'Sign in to continue' } }),
    })
    renderAt('/users/u-1')
    expect(await screen.findByRole('form', { name: 'Sign in' })).toBeInTheDocument()
  })
})

vi.stubGlobal('scrollTo', () => {})
