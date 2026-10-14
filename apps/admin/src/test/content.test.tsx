import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router'
import { describe, expect, it } from 'vitest'
import { App } from '../App'
import { mockApi, session, theCase } from './mockApi'

function renderAt(path: string) {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <App />
    </MemoryRouter>,
  )
}

const signedIn = (role: 'viewer' | 'moderator' | 'admin') => ({ 'GET /me': () => ({ data: session(role) }) })

const reportId = '019a0000-0000-7000-8000-000000000001'
const caseId = '019a0000-0000-7000-8000-0000000000c1'

const preview = {
  content: { targetType: 'post', targetId: 'p-1', text: 'the reported post text', authorId: 'u-1', authorUsername: 'bob', createdAt: '2026-10-12T09:00:00Z', deleted: false },
  media: [{ mediaId: 'm-1', width: 80, height: 60, url: '/admin/v1/media/m-1?t=tok' }],
  mediaAvailable: true,
}

const contentCase = (over: Record<string, unknown> = {}) => ({
  caseId, mediaId: 'm-9', userId: 'u-1', username: 'bob', ageBand: 'minor', accountStatus: 'suspended', purpose: 'post', result: 'match', scanner: 'hashlist',
  signals: { label: 'list-1' }, originalSha256: 'abcdef0123456789', originalBytes: 2048, contentType: 'image/jpeg', suspendedUser: true, status: 'open',
  createdAt: '2026-10-13T10:00:00Z', holdUntil: '2027-01-11T10:00:00Z', legalHold: false, reviewedBy: '', reviewedAt: null, resolutionNote: '', reportReference: '', reportedAt: null, ...over,
})

describe('reported content preview', () => {
  it('asks a moderator for a reason, sends it, then shows the text and the photo through the console', async () => {
    const user = userEvent.setup()
    const { calls } = mockApi({
      ...signedIn('moderator'),
      [`GET /reports/${reportId}`]: () => ({ data: theCase({ targetType: 'post' }) }),
      [`POST /reports/${reportId}/content`]: () => ({ data: preview }),
    })
    renderAt(`/reports/${reportId}`)
    expect(screen.queryByText('the reported post text')).not.toBeInTheDocument()
    await user.click(await screen.findByRole('button', { name: 'View reported content…' }))
    const dialog = screen.getByRole('dialog', { name: 'View reported content' })
    const submit = within(dialog).getByRole('button', { name: 'Show content' })
    expect(submit).toBeDisabled()
    await user.type(within(dialog).getByLabelText(/Reason/), 'checking the reported post')
    await user.click(submit)
    expect(await screen.findByText('the reported post text')).toBeInTheDocument()
    const post = calls.find((c) => c.path === `/reports/${reportId}/content`)!
    expect(post.body).toEqual({ reason: 'checking the reported post' })
    expect(post.headers['X-CSRF-Token']).toBe('csrf-123')
    // The image comes from the console's own origin, never from a storage host.
    expect(screen.getByRole('img', { name: 'Reported photo' })).toHaveAttribute('src', '/admin/v1/media/m-1?t=tok')
  })

  it('offers nothing for a viewer, and nothing for a private chat', async () => {
    mockApi({ ...signedIn('viewer'), [`GET /reports/${reportId}`]: () => ({ data: theCase({ targetType: 'post' }) }) })
    renderAt(`/reports/${reportId}`)
    expect(await screen.findByText('Your role can read the case but not the reported content.')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'View reported content…' })).not.toBeInTheDocument()
  })

  it('never offers a preview of a chat', async () => {
    mockApi({ ...signedIn('admin'), [`GET /reports/${reportId}`]: () => ({ data: theCase({ targetType: 'conversation' }) }) })
    renderAt(`/reports/${reportId}`)
    expect(await screen.findByText(/end-to-end encrypted, so staff only see what the reporter shared/)).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'View reported content…' })).not.toBeInTheDocument()
  })

  it('says so when the console cannot reach photo storage', async () => {
    const user = userEvent.setup()
    mockApi({
      ...signedIn('moderator'),
      [`GET /reports/${reportId}`]: () => ({ data: theCase({ targetType: 'post' }) }),
      [`POST /reports/${reportId}/content`]: () => ({ data: { ...preview, media: [{ ...preview.media[0], url: '' }], mediaAvailable: false } }),
    })
    renderAt(`/reports/${reportId}`)
    await user.click(await screen.findByRole('button', { name: 'View reported content…' }))
    await user.type(screen.getByLabelText(/Reason/), 'checking the reported post')
    await user.click(screen.getByRole('button', { name: 'Show content' }))
    expect(await screen.findByText(/photo\(s\) not shown/)).toBeInTheDocument()
    expect(screen.queryByRole('img')).not.toBeInTheDocument()
  })
})

describe('quarantined uploads', () => {
  it('hides the section from viewers and keeps the image from moderators', async () => {
    mockApi({ ...signedIn('viewer') })
    const view = renderAt('/content')
    expect(await screen.findByText('Your role does not allow this page.')).toBeInTheDocument()
    expect(screen.queryByRole('link', { name: 'Quarantine' })).not.toBeInTheDocument()
    view.unmount()

    mockApi({ ...signedIn('moderator'), [`GET /content-cases/${caseId}`]: () => ({ data: { case: contentCase(), mediaAvailable: true } }) })
    renderAt(`/content/${caseId}`)
    expect(await screen.findByText('Only administrators can look at quarantined images.')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /Load image/ })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /Confirm and hold/ })).not.toBeInTheDocument()
    expect(screen.getByText('abcdef0123456789')).toBeInTheDocument()
  })

  it('lists cases without any image', async () => {
    mockApi({ ...signedIn('moderator'), 'GET /content-cases*': () => ({ data: { items: [contentCase()], nextCursor: null, hasMore: false } }) })
    renderAt('/content')
    const table = await screen.findByRole('table')
    expect(within(table).getByText('match')).toBeInTheDocument()
    expect(within(table).getByText('minor')).toBeInTheDocument()
    expect(screen.queryByRole('img')).not.toBeInTheDocument()
  })

  it('loads the image blurred after a reason, and only an explicit reveal unblurs it', async () => {
    const user = userEvent.setup()
    const { calls } = mockApi({
      ...signedIn('admin'),
      [`GET /content-cases/${caseId}`]: () => ({ data: { case: contentCase(), mediaAvailable: true } }),
      [`POST /content-cases/${caseId}/view`]: () => ({ data: { url: '/admin/v1/media/m-9?t=tok', blurred: true } }),
      [`POST /content-cases/${caseId}/reveal`]: () => ({ data: { revealed: true } }),
    })
    renderAt(`/content/${caseId}`)
    // Nothing is fetched until the administrator asks.
    await user.click(await screen.findByRole('button', { name: 'Load image (blurred)…' }))
    expect(screen.queryByRole('img')).not.toBeInTheDocument()
    const dialog = screen.getByRole('dialog', { name: 'Load the quarantined image' })
    expect(within(dialog).getByRole('button', { name: 'Load blurred image' })).toBeDisabled()
    await user.type(within(dialog).getByLabelText(/Reason/), 'reviewing the scanner match')
    await user.click(within(dialog).getByRole('button', { name: 'Load blurred image' }))
    const image = await screen.findByRole('img', { name: 'Quarantined upload, blurred' })
    expect(image).toHaveClass('blurred')
    expect(calls.some((c) => c.path.endsWith('/reveal'))).toBe(false)

    await user.click(screen.getByRole('button', { name: 'Reveal image' }))
    await waitFor(() => expect(screen.getByRole('img', { name: 'Quarantined upload' })).not.toHaveClass('blurred'))
    const reveal = calls.find((c) => c.path.endsWith('/reveal'))!
    expect(reveal.body).toEqual({ reason: 'reviewing the scanner match' })
    expect(reveal.headers['X-CSRF-Token']).toBe('csrf-123')
    // It can be blurred again without another request.
    await user.click(screen.getByRole('button', { name: 'Blur again' }))
    expect(screen.getByRole('img')).toHaveClass('blurred')
    expect(calls.filter((c) => c.path.endsWith('/reveal'))).toHaveLength(1)
  })

  it('records a report reference only with a reference and a reason, and never sends anything itself', async () => {
    const user = userEvent.setup()
    const { calls } = mockApi({
      ...signedIn('admin'),
      [`GET /content-cases/${caseId}`]: () => ({ data: { case: contentCase({ status: 'confirmed' }), mediaAvailable: false } }),
      [`POST /content-cases/${caseId}/resolve`]: () => ({ data: { caseId, action: 'reported' } }),
    })
    renderAt(`/content/${caseId}`)
    expect(await screen.findByText(/The console has no access to photo storage/)).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Record that it was reported…' }))
    const dialog = screen.getByRole('dialog', { name: 'Record the report' })
    const submit = within(dialog).getByRole('button', { name: 'Record reference' })
    await user.type(within(dialog).getByLabelText(/Reason/), 'reported through the CyberTipline')
    expect(submit).toBeDisabled()
    await user.type(within(dialog).getByLabelText('Report number or authority reference'), 'NCMEC-123456')
    await user.click(submit)
    await waitFor(() => expect(calls.some((c) => c.method === 'POST')).toBe(true))
    expect(calls.find((c) => c.method === 'POST')!.body).toEqual({ action: 'reported', reason: 'reported through the CyberTipline', reportReference: 'NCMEC-123456' })
  })
})
