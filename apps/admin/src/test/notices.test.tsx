import { fireEvent, render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router'
import { describe, expect, it } from 'vitest'
import { App } from '../App'
import { mockApi, session } from './mockApi'

function renderAt(path: string) {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <App />
    </MemoryRouter>,
  )
}

const signedIn = (role: 'viewer' | 'moderator' | 'admin') => ({ 'GET /me': () => ({ data: session(role) }) })

const notice = (over: Record<string, unknown> = {}) => ({
  noticeId: '019a0000-0000-7000-8000-0000000000a1', category: 'safety', title: 'Stay safe online', body: 'Never share **your address**.\n\nRead [our tips](https://hiyall.app/safety).',
  audience: 'all', locale: '', pinned: true, publishedAt: '2026-10-10T09:00:00Z', expiresAt: null, unpublishedAt: null, createdBy: 'Sam',
  updatedAt: '2026-10-10T09:00:00Z', status: 'live', ...over,
})

const page = (items: unknown[], nextCursor: string | null = null) => ({ data: { items, nextCursor, hasMore: nextCursor !== null } })

const reason = 'announcing the new safety tips'

async function fillForm(user: ReturnType<typeof userEvent.setup>, title = 'Hello members') {
  await user.type(screen.getByLabelText('Title'), title)
  fireEvent.change(screen.getByLabelText('Text'), { target: { value: 'First paragraph.\n\nSecond with **bold**.' } })
  await user.type(screen.getByLabelText(/^Reason/), reason)
}

describe('notices: who can write', () => {
  it.each(['viewer', 'moderator'] as const)('shows %s a read-only list with no way to write', async (role) => {
    mockApi({ ...signedIn(role), 'GET /notices*': () => page([notice()]) })
    renderAt('/notices')
    expect(await screen.findByText('Stay safe online')).toBeInTheDocument()
    expect(screen.getByText(/Your role is read-only/)).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'New notice' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /^Edit/ })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /^Unpublish/ })).not.toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Notices' })).toBeInTheDocument()
    expect(screen.getByRole('columnheader', { name: 'Title' })).toBeInTheDocument()
  })

  it('lists title, category, audience, language, pinned, status and times, and draws the body safely', async () => {
    mockApi({ ...signedIn('viewer'), 'GET /notices*': () => page([notice({ locale: 'pt-BR', audience: 'minors', expiresAt: '2027-01-01T00:00:00Z' })]) })
    renderAt('/notices')
    const row = (await screen.findByText('Stay safe online')).closest('tr')!
    expect(within(row).getByText('safety')).toBeInTheDocument()
    expect(within(row).getByText('minors')).toBeInTheDocument()
    expect(within(row).getByText('pt-BR')).toBeInTheDocument()
    expect(within(row).getByText('yes')).toBeInTheDocument()
    expect(within(row).getByText('live')).toBeInTheDocument()
    const link = within(row).getByRole('link', { name: 'our tips' })
    expect(link).toHaveAttribute('href', 'https://hiyall.app/safety')
    expect(link).toHaveAttribute('rel', 'noopener noreferrer')
  })

  it('filters by status and pages with the cursor', async () => {
    const user = userEvent.setup()
    const { calls } = mockApi({
      ...signedIn('viewer'),
      'GET /notices?status=live': () => page([notice({ title: 'Live one' })]),
      'GET /notices?status=live&cursor=c1': () => page([notice({ noticeId: '019a0000-0000-7000-8000-0000000000a2', title: 'Second page' })]),
      'GET /notices': () => page([notice({ title: 'First page' })], 'c0'),
      'GET /notices?cursor=c0': () => page([notice({ noticeId: '019a0000-0000-7000-8000-0000000000a3', title: 'Older one' })]),
    })
    renderAt('/notices')
    await screen.findByText('First page')
    await user.click(screen.getByRole('button', { name: 'Load more' }))
    expect(await screen.findByText('Older one')).toBeInTheDocument()
    await user.selectOptions(screen.getByLabelText('Status'), 'live')
    expect(await screen.findByText('Live one')).toBeInTheDocument()
    expect(calls.map((c) => c.path)).toContain('/notices?status=live')
  })
})

describe('notices: create, edit, unpublish (administrator)', () => {
  it('sends the whole notice with the reason and the CSRF header', async () => {
    const user = userEvent.setup()
    const { calls } = mockApi({
      ...signedIn('admin'),
      'GET /notices*': () => page([]),
      'POST /notices': () => ({ status: 201, data: notice({ title: 'Hello members' }) }),
    })
    renderAt('/notices')
    await user.click(await screen.findByRole('button', { name: 'New notice' }))
    const publish = screen.getByRole('button', { name: 'Publish notice' })
    expect(publish).toBeDisabled()
    await user.selectOptions(screen.getByLabelText('Category'), 'update')
    await user.selectOptions(screen.getByLabelText('Audience'), 'adults')
    await user.type(screen.getByLabelText('Language'), 'pt-BR')
    await user.click(screen.getByRole('checkbox', { name: /Pinned/ }))
    fireEvent.change(screen.getByLabelText('Expires at'), { target: { value: '2027-01-01T10:00' } })
    await fillForm(user)
    expect(publish).toBeEnabled()
    await user.click(publish)
    expect(await screen.findByText(/Published “Hello members”/)).toBeInTheDocument()
    const post = calls.find((c) => c.method === 'POST' && c.path === '/notices')!
    expect(post.body).toEqual({
      category: 'update', title: 'Hello members', body: 'First paragraph.\n\nSecond with **bold**.', audience: 'adults', locale: 'pt-BR', pinned: true,
      expiresAt: new Date('2027-01-01T10:00').toISOString(), reason,
    })
    expect(post.headers['X-CSRF-Token']).toBe('csrf-123')
    // The list was loaded again after saving.
    expect(calls.filter((c) => c.method === 'GET' && c.path.startsWith('/notices')).length).toBe(2)
  })

  it('needs a reason of at least 10 characters', async () => {
    const user = userEvent.setup()
    mockApi({ ...signedIn('admin'), 'GET /notices*': () => page([]) })
    renderAt('/notices')
    await user.click(await screen.findByRole('button', { name: 'New notice' }))
    await user.type(screen.getByLabelText('Title'), 'Hello')
    fireEvent.change(screen.getByLabelText('Text'), { target: { value: 'Body' } })
    await user.type(screen.getByLabelText(/^Reason/), 'short')
    expect(screen.getByRole('button', { name: 'Publish notice' })).toBeDisabled()
    expect(screen.getByText('5 more characters needed')).toBeInTheDocument()
  })

  it('shows the live preview with only safe markup, and warns about what the server will refuse', async () => {
    const user = userEvent.setup()
    mockApi({ ...signedIn('admin'), 'GET /notices*': () => page([]) })
    renderAt('/notices')
    await user.click(await screen.findByRole('button', { name: 'New notice' }))
    fireEvent.change(screen.getByLabelText('Text'), { target: { value: 'Hi **all**\n\n[ok](https://hiyall.app) [bad](http://hiyall.app) <script>x</script>' } })
    const preview = screen.getByRole('region', { name: 'Preview of the notice' })
    expect(within(preview).getByText('all').tagName).toBe('STRONG')
    expect(within(preview).getAllByRole('link').map((a) => a.getAttribute('href'))).toEqual(['https://hiyall.app'])
    expect(preview.querySelector('script')).toBeNull()
    const warnings = screen.getByRole('list', { name: 'Things the server will refuse' })
    expect(warnings).toHaveTextContent('HTML is not allowed')
    expect(warnings).toHaveTextContent('Links must be https addresses')
  })

  it('shows the server validation error next to the form and keeps what was typed', async () => {
    const user = userEvent.setup()
    mockApi({
      ...signedIn('admin'),
      'GET /notices*': () => page([]),
      'POST /notices': () => ({ status: 422, error: { code: 'VALIDATION', message: 'body: links must be https addresses' } }),
    })
    renderAt('/notices')
    await user.click(await screen.findByRole('button', { name: 'New notice' }))
    await fillForm(user)
    await user.click(screen.getByRole('button', { name: 'Publish notice' }))
    const form = screen.getByRole('form', { name: 'New notice' })
    expect(await within(form).findByText('body: links must be https addresses')).toBeInTheDocument()
    expect(screen.getByLabelText('Title')).toHaveValue('Hello members')
    expect(screen.getByRole('button', { name: 'Publish notice' })).toBeEnabled()
  })

  it('edits with PUT, prefilled, and sends the reason', async () => {
    const user = userEvent.setup()
    const { calls } = mockApi({
      ...signedIn('admin'),
      'GET /notices*': () => page([notice()]),
      'PUT /notices/019a0000-0000-7000-8000-0000000000a1': () => ({ data: notice({ title: 'Stay safe online today' }) }),
    })
    renderAt('/notices')
    await user.click(await screen.findByRole('button', { name: 'Edit Stay safe online' }))
    expect(screen.getByLabelText('Title')).toHaveValue('Stay safe online')
    expect(screen.getByRole('checkbox', { name: /Pinned/ })).toBeChecked()
    await user.type(screen.getByLabelText('Title'), ' today')
    await user.type(screen.getByLabelText(/^Reason/), 'clearer title for members')
    await user.click(screen.getByRole('button', { name: 'Save changes' }))
    expect(await screen.findByText(/Saved “Stay safe online today”/)).toBeInTheDocument()
    const put = calls.find((c) => c.method === 'PUT')!
    expect(put.body).toMatchObject({ category: 'safety', title: 'Stay safe online today', audience: 'all', locale: '', pinned: true, reason: 'clearer title for members' })
    // The saved publish time was not touched, so it is not sent again.
    expect(put.body).not.toHaveProperty('publishedAt')
    expect(put.headers['X-CSRF-Token']).toBe('csrf-123')
  })

  it('asks for a reason before it unpublishes, then sends it', async () => {
    const user = userEvent.setup()
    const { calls } = mockApi({
      ...signedIn('admin'),
      'GET /notices*': () => page([notice(), notice({ noticeId: '019a0000-0000-7000-8000-0000000000a9', title: 'Gone already', status: 'unpublished' })]),
      'POST /notices/019a0000-0000-7000-8000-0000000000a1/unpublish': () => ({ data: notice({ status: 'unpublished' }) }),
    })
    renderAt('/notices')
    expect(screen.queryByRole('button', { name: 'Unpublish Gone already' })).not.toBeInTheDocument()
    await user.click(await screen.findByRole('button', { name: 'Unpublish Stay safe online' }))
    const dialog = screen.getByRole('dialog', { name: /Unpublish/ })
    const confirm = within(dialog).getByRole('button', { name: 'Unpublish notice' })
    expect(confirm).toBeDisabled()
    await user.type(within(dialog).getByLabelText(/Reason/), 'the advice is out of date')
    await user.click(confirm)
    expect(await screen.findByText(/Unpublished “Stay safe online”/)).toBeInTheDocument()
    const post = calls.find((c) => c.path.endsWith('/unpublish'))!
    expect(post.body).toEqual({ reason: 'the advice is out of date' })
    expect(post.headers['X-CSRF-Token']).toBe('csrf-123')
  })
})
