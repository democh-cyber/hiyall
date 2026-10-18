import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router'
import { describe, expect, it } from 'vitest'
import { App } from '../App'
import { CANNED_REPLIES } from '../cannedReplies'
import { mockApi, session } from './mockApi'

function renderAt(path: string) {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <App />
    </MemoryRouter>,
  )
}

const signedIn = (role: 'viewer' | 'moderator' | 'admin') => ({ 'GET /me': () => ({ data: session(role) }) })

const threadId = '019a0000-0000-7000-8000-0000000000b1'

const thread = (over: Record<string, unknown> = {}, member: Record<string, unknown> = {}) => ({
  threadId, category: 'safety', status: 'open',
  member: { userId: 'u-1', username: 'rita', displayName: 'Rita', ageBand: 'minor', status: 'active', ...member },
  assignedTo: null, assignedToMe: false, createdAt: '2026-10-12T09:00:00Z', lastMessageAt: '2026-10-12T10:00:00Z', lastAuthor: 'member', messageCount: 2, ...over,
})

const messages = [
  { messageId: 'm-1', author: 'member', operator: null, body: 'Someone keeps messaging me', createdAt: '2026-10-12T09:00:00Z' },
  { messageId: 'm-2', author: 'staff', operator: 'Ada', body: 'Thanks, we are looking', createdAt: '2026-10-12T09:30:00Z' },
]

const page = (items: unknown[], nextCursor: string | null = null) => ({ data: { items, nextCursor, hasMore: nextCursor !== null } })
const view = (t = thread()) => ({ data: { thread: t, messages } })

describe('support inbox', () => {
  it('lists conversations with a prominent age band and never any message text', async () => {
    mockApi({
      ...signedIn('viewer'),
      // A stray text field must never be drawn: the inbox has no message text by design.
      'GET /support/threads*': () => page([
        { ...thread(), body: 'SECRET MESSAGE TEXT', preview: 'SECRET PREVIEW' },
        thread({ threadId: '019a0000-0000-7000-8000-0000000000b2', category: 'bug', lastAuthor: 'staff', assignedTo: 'Ada' }, { userId: 'u-2', username: 'bob', displayName: 'Bob', ageBand: 'adult', status: 'suspended' }),
      ]),
    })
    renderAt('/support')
    const row = (await screen.findByText('@rita')).closest('tr')!
    expect(within(row).getByText('minor (under 18)')).toBeInTheDocument()
    expect(within(row).getByText('Rita')).toBeInTheDocument()
    expect(within(row).getByText('safety')).toBeInTheDocument()
    expect(within(row).getByText('member')).toBeInTheDocument()
    expect(within(row).getByText('waiting for us')).toBeInTheDocument()
    expect(within(row).getByText('2')).toBeInTheDocument()
    expect(within(row).getByRole('link')).toHaveAttribute('href', `/support/${threadId}`)
    const other = screen.getByText('@bob').closest('tr')!
    expect(within(other).getByText('adult')).toBeInTheDocument()
    expect(within(other).getByText('suspended')).toBeInTheDocument()
    expect(within(other).getByText('Ada')).toBeInTheDocument()
    expect(document.body).not.toHaveTextContent('SECRET')
    expect(screen.getByRole('link', { name: 'Support' })).toBeInTheDocument()
  })

  it('asks for open conversations, oldest waiting first, and builds the query from the filters', async () => {
    const user = userEvent.setup()
    const { calls } = mockApi({ ...signedIn('viewer'), 'GET /support/threads*': () => page([thread()]) })
    renderAt('/support')
    await screen.findByText('@rita')
    const paths = () => calls.filter((c) => c.path.startsWith('/support/threads')).map((c) => c.path)
    expect(paths()).toEqual(['/support/threads?status=open&sort=oldest'])
    await user.selectOptions(screen.getByLabelText('Status'), 'closed')
    await waitFor(() => expect(paths()).toContain('/support/threads?status=closed&sort=oldest'))
    await user.selectOptions(screen.getByLabelText('Category'), 'bug')
    await user.click(screen.getByRole('checkbox', { name: 'Waiting for us' }))
    await user.selectOptions(screen.getByLabelText('Assigned'), 'me')
    await user.selectOptions(screen.getByLabelText('Order'), 'newest')
    await waitFor(() => expect(paths()).toContain('/support/threads?status=closed&category=bug&waiting=true&assigned=me&sort=newest'))
    await user.selectOptions(screen.getByLabelText('Status'), 'all')
    await waitFor(() => expect(paths().at(-1)).toBe('/support/threads?status=all&category=bug&waiting=true&assigned=me&sort=newest'))
  })

  it('pages with the cursor', async () => {
    const user = userEvent.setup()
    const { calls } = mockApi({
      ...signedIn('viewer'),
      'GET /support/threads?status=open&sort=oldest&cursor=c1': () => page([thread({ threadId: '019a0000-0000-7000-8000-0000000000b3' }, { username: 'zed' })]),
      'GET /support/threads?status=open&sort=oldest': () => page([thread()], 'c1'),
    })
    renderAt('/support')
    await screen.findByText('@rita')
    await user.click(screen.getByRole('button', { name: 'Load more' }))
    expect(await screen.findByText('@zed')).toBeInTheDocument()
    expect(calls.some((c) => c.path.endsWith('cursor=c1'))).toBe(true)
  })
})

describe('support thread', () => {
  const route = { [`GET /support/threads/${threadId}`]: () => view() }

  it('shows a viewer everything read-only, with the audit notice and the age band', async () => {
    mockApi({ ...signedIn('viewer'), ...route })
    renderAt(`/support/${threadId}`)
    expect(await screen.findByText('Someone keeps messaging me')).toBeInTheDocument()
    expect(screen.getByText('Support messages are plain text the member knows staff can read. Viewing is audited.')).toBeInTheDocument()
    expect(screen.getAllByText('minor (under 18)').length).toBeGreaterThan(0)
    expect(screen.getByText('Hiyall staff (Ada)')).toBeInTheDocument()
    expect(screen.getByText(/Your role is read-only/)).toBeInTheDocument()
    expect(screen.queryByRole('textbox')).not.toBeInTheDocument()
    for (const name of ['Send reply', 'Close', 'Reopen', 'Assign to me', 'Unassign']) {
      expect(screen.queryByRole('button', { name })).not.toBeInTheDocument()
    }
  })

  it('lets a moderator insert a template, edit it, send it and sees the thread refresh', async () => {
    const user = userEvent.setup()
    let sent = false
    const { calls } = mockApi({
      ...signedIn('moderator'),
      [`GET /support/threads/${threadId}`]: () => ({ data: { thread: thread({ lastAuthor: sent ? 'staff' : 'member' }), messages: sent ? [...messages, { messageId: 'm-3', author: 'staff', operator: 'Sam', body: 'we escalated it, thanks', createdAt: '2026-10-12T11:00:00Z' }] : messages } }),
      [`POST /support/threads/${threadId}/reply`]: () => { sent = true; return { status: 201, data: messages[1] } },
    })
    renderAt(`/support/${threadId}`)
    await screen.findByText('Someone keeps messaging me')
    // The minor reminder is next to the reply box.
    expect(screen.getByText(/never ask for contact details/)).toBeInTheDocument()
    const send = screen.getByRole('button', { name: 'Send reply' })
    expect(send).toBeDisabled()
    const box = screen.getByLabelText(/Your reply/)
    // A template goes into the box for editing; nothing is sent.
    await user.click(screen.getByRole('button', { name: 'Escalated to safety' }))
    expect(box).toHaveValue(CANNED_REPLIES.find((c) => c.id === 'escalated')!.body)
    expect(calls.some((c) => c.method === 'POST')).toBe(false)
    await user.clear(box)
    await user.type(box, 'we escalated it, thanks')
    expect(screen.getByText('23 / 2000')).toBeInTheDocument()
    await user.click(send)
    expect(await screen.findByText('Reply sent. The member gets a notification without its text.')).toBeInTheDocument()
    expect(await screen.findByText('we escalated it, thanks', { selector: 'p' })).toBeInTheDocument()
    const post = calls.find((c) => c.path.endsWith('/reply'))!
    expect(post.body).toEqual({ body: 'we escalated it, thanks' })
    expect(post.headers['X-CSRF-Token']).toBe('csrf-123')
    expect(box).toHaveValue('')
    expect(calls.filter((c) => c.method === 'GET' && c.path === `/support/threads/${threadId}`).length).toBe(2)
  })

  it('appends a second template after the text already typed', async () => {
    const user = userEvent.setup()
    mockApi({ ...signedIn('moderator'), ...route })
    renderAt(`/support/${threadId}`)
    await screen.findByText('Someone keeps messaging me')
    const box = screen.getByLabelText(/Your reply/)
    await user.type(box, 'Hello')
    await user.click(screen.getByRole('button', { name: 'Thanks for writing' }))
    expect(box).toHaveValue(`Hello\n\n${CANNED_REPLIES[0].body}`)
  })

  it('has only neutral templates that never ask for contact details', () => {
    expect(CANNED_REPLIES.length).toBeGreaterThanOrEqual(5)
    expect(CANNED_REPLIES.length).toBeLessThanOrEqual(6)
    for (const c of CANNED_REPLIES) expect(c.body).not.toMatch(/@|https?:|phone|whatsapp|snapchat|instagram|email|number/i)
  })

  it('does not show the minor reminder for an adult member', async () => {
    mockApi({ ...signedIn('moderator'), [`GET /support/threads/${threadId}`]: () => view(thread({}, { ageBand: 'adult' })) })
    renderAt(`/support/${threadId}`)
    await screen.findByText('Someone keeps messaging me')
    expect(screen.queryByText(/never ask for contact details/)).not.toBeInTheDocument()
    expect(screen.getAllByText('adult').length).toBeGreaterThan(0)
  })

  it('says to reopen first when the conversation was closed meanwhile', async () => {
    const user = userEvent.setup()
    mockApi({
      ...signedIn('moderator'),
      ...route,
      [`POST /support/threads/${threadId}/reply`]: () => ({ status: 409, error: { code: 'SUPPORT_THREAD_CLOSED', message: 'closed' } }),
    })
    renderAt(`/support/${threadId}`)
    await user.type(await screen.findByLabelText(/Your reply/), 'hello there')
    await user.click(screen.getByRole('button', { name: 'Send reply' }))
    expect(await screen.findByText('This conversation is closed. Reopen it before replying.')).toBeInTheDocument()
    // What was typed is kept.
    expect(screen.getByLabelText(/Your reply/)).toHaveValue('hello there')
  })

  it('closes, then reopens, and explains when another open conversation blocks the reopen', async () => {
    const user = userEvent.setup()
    const { calls } = mockApi({
      ...signedIn('moderator'),
      ...route,
      [`POST /support/threads/${threadId}/close`]: () => ({ data: thread({ status: 'closed' }) }),
      [`POST /support/threads/${threadId}/reopen`]: () => ({ status: 409, error: { code: 'SUPPORT_THREAD_OPEN', message: 'x' } }),
    })
    renderAt(`/support/${threadId}`)
    await user.click(await screen.findByRole('button', { name: 'Close' }))
    expect(await screen.findByText('Conversation closed.')).toBeInTheDocument()
    expect(screen.queryByRole('textbox')).not.toBeInTheDocument()
    expect(screen.getByText(/Reopen it to reply/)).toBeInTheDocument()
    expect(calls.find((c) => c.path.endsWith('/close'))!.headers['X-CSRF-Token']).toBe('csrf-123')
    await user.click(screen.getByRole('button', { name: 'Reopen' }))
    expect(await screen.findByText(/already has another open conversation in this category/)).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Reopen' })).toBeInTheDocument()
  })

  it('assigns to me and unassigns', async () => {
    const user = userEvent.setup()
    const { calls } = mockApi({
      ...signedIn('admin'),
      ...route,
      [`POST /support/threads/${threadId}/assign`]: (c) => ({ data: thread((c.body as { assignTo: string | null }).assignTo ? { assignedTo: 'Sam', assignedToMe: true } : {}) }),
    })
    renderAt(`/support/${threadId}`)
    await user.click(await screen.findByRole('button', { name: 'Assign to me' }))
    expect(await screen.findByText('Assigned to you.')).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Unassign' }))
    expect(await screen.findByText('Unassigned.')).toBeInTheDocument()
    const bodies = calls.filter((c) => c.path.endsWith('/assign')).map((c) => c.body)
    expect(bodies).toEqual([{ assignTo: 'me' }, { assignTo: null }])
  })
})
