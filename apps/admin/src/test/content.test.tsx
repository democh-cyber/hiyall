import { fireEvent, render, screen, waitFor, within } from '@testing-library/react'
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

/** The proposals list every admin case page loads; tests override it to show a pending one. */
const noProposals = (items: unknown[] = [], operatorId = 'op-1') => ({ [`GET /content-cases/${'019a0000-0000-7000-8000-0000000000c1'}/proposals`]: () => ({ data: { items, operatorId } }) })

const proposal = (over: Record<string, unknown> = {}) => ({
  approvalId: 'ap-1', caseId: '019a0000-0000-7000-8000-0000000000c1', kind: 'clear', status: 'pending', proposedBy: 'op-2', proposedByEmail: 'ada@hiyall.test',
  proposedAt: '2026-10-14T09:00:00Z', reason: 'the list entry was wrong', counselReference: '', expiresAt: '2026-10-15T09:00:00Z', decidedBy: '', decidedByEmail: '', decidedAt: null, decisionReason: '', ...over,
})

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
  createdAt: '2026-10-13T10:00:00Z', holdUntil: '2027-01-11T10:00:00Z', legalHold: false, reviewedBy: '', reviewedAt: null, resolutionNote: '', reportReference: '', reportedAt: null,
  releasedAt: null, releasedBy: '', releaseReason: '', objectsPurgedAt: null, releaseBlocker: '', ...over,
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

  it('loads the server-blurred image after a reason, and only the audited reveal fetches the original', async () => {
    const user = userEvent.setup()
    const { calls } = mockApi({
      ...signedIn('admin'),
      ...noProposals(),
      [`GET /content-cases/${caseId}`]: () => ({ data: { case: contentCase(), mediaAvailable: true } }),
      [`POST /content-cases/${caseId}/view`]: () => ({ data: { url: '/admin/v1/media/m-9?t=blurred-token', blurred: true } }),
      [`POST /content-cases/${caseId}/reveal`]: () => ({ data: { revealed: true, url: '/admin/v1/media/m-9?t=full-token', expiresInSeconds: 60 } }),
    })
    renderAt(`/content/${caseId}`)
    // Nothing is fetched until the administrator asks.
    await user.click(await screen.findByRole('button', { name: 'Load image (blurred)…' }))
    expect(screen.queryByRole('img')).not.toBeInTheDocument()
    const dialog = screen.getByRole('dialog', { name: 'Load the quarantined image' })
    expect(within(dialog).getByRole('button', { name: 'Load blurred image' })).toBeDisabled()
    await user.type(within(dialog).getByLabelText(/Reason/), 'reviewing the scanner match')
    await user.click(within(dialog).getByRole('button', { name: 'Load blurred image' }))
    // The page holds the link to the blurred copy the server made: no CSS filter, no original behind it.
    const image = await screen.findByRole('img', { name: 'Quarantined upload, blurred' })
    expect(image).toHaveAttribute('src', '/admin/v1/media/m-9?t=blurred-token')
    expect(image).not.toHaveClass('blurred')
    expect(calls.some((c) => c.path.endsWith('/reveal'))).toBe(false)

    await user.click(screen.getByRole('button', { name: 'Reveal image' }))
    const revealed = await screen.findByRole('img', { name: 'Quarantined upload' })
    // The second, short-lived link comes from the reveal call.
    expect(revealed).toHaveAttribute('src', '/admin/v1/media/m-9?t=full-token')
    expect(screen.getByText('This link works for one minute.')).toBeInTheDocument()
    const reveal = calls.find((c) => c.path.endsWith('/reveal'))!
    expect(reveal.body).toEqual({ reason: 'reviewing the scanner match' })
    expect(reveal.headers['X-CSRF-Token']).toBe('csrf-123')
    // It can be blurred again without another request, and the page goes back to the blurred link.
    await user.click(screen.getByRole('button', { name: 'Blur again' }))
    expect(screen.getByRole('img')).toHaveAttribute('src', '/admin/v1/media/m-9?t=blurred-token')
    expect(calls.filter((c) => c.path.endsWith('/reveal'))).toHaveLength(1)
  })

  it('says so when the one-minute unblurred link ends', async () => {
    const user = userEvent.setup()
    mockApi({
      ...signedIn('admin'),
      ...noProposals(),
      [`GET /content-cases/${caseId}`]: () => ({ data: { case: contentCase(), mediaAvailable: true } }),
      [`POST /content-cases/${caseId}/view`]: () => ({ data: { url: '/admin/v1/media/m-9?t=blurred-token', blurred: true } }),
      [`POST /content-cases/${caseId}/reveal`]: () => ({ data: { revealed: true, url: '/admin/v1/media/m-9?t=full-token', expiresInSeconds: 60 } }),
    })
    renderAt(`/content/${caseId}`)
    await user.click(await screen.findByRole('button', { name: 'Load image (blurred)…' }))
    await user.type(screen.getByLabelText(/Reason/), 'reviewing the scanner match')
    await user.click(screen.getByRole('button', { name: 'Load blurred image' }))
    await user.click(await screen.findByRole('button', { name: 'Reveal image' }))
    const revealed = await screen.findByRole('img', { name: 'Quarantined upload' })
    // The browser fails to load the expired link: back to blurred, with an explanation.
    fireEvent.error(revealed)
    expect(await screen.findByText(/The unblurred link works for one minute and has ended/)).toBeInTheDocument()
    expect(screen.getByRole('img')).toHaveAttribute('src', '/admin/v1/media/m-9?t=blurred-token')
  })

  it('records a report reference only with a reference and a reason, and never sends anything itself', async () => {
    const user = userEvent.setup()
    const { calls } = mockApi({
      ...signedIn('admin'),
      ...noProposals(),
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

  it('proposes releasing an evidence hold with a reason, and does not release it itself', async () => {
    const user = userEvent.setup()
    const { calls } = mockApi({
      ...signedIn('admin'),
      ...noProposals(),
      [`GET /content-cases/${caseId}`]: () => ({ data: { case: contentCase({ status: 'cleared' }), mediaAvailable: false } }),
      [`POST /content-cases/${caseId}/proposals`]: () => ({ status: 201, data: { approval: proposal({ kind: 'release', proposedBy: 'op-1' }) } }),
    })
    renderAt(`/content/${caseId}`)
    await user.click(await screen.findByRole('button', { name: 'Propose releasing the hold…' }))
    const dialog = screen.getByRole('dialog', { name: 'Propose releasing the evidence hold' })
    const submit = within(dialog).getByRole('button', { name: 'Propose release' })
    expect(submit).toBeDisabled()
    await user.type(within(dialog).getByLabelText(/Reason/), 'counsel says the hold has ended')
    await user.click(submit)
    await waitFor(() => expect(calls.some((c) => c.method === 'POST' && c.path === `/content-cases/${caseId}/proposals`)).toBe(true))
    const post = calls.find((c) => c.method === 'POST' && c.path === `/content-cases/${caseId}/proposals`)!
    expect(post.body).toEqual({ kind: 'release', reason: 'counsel says the hold has ended' })
    expect(post.headers['X-CSRF-Token']).toBe('csrf-123')
    expect(await screen.findByText(/A different administrator has to approve it within 24 hours/)).toBeInTheDocument()
    // The old one-step route is never called.
    expect(calls.some((c) => c.path.startsWith('/holds/'))).toBe(false)
  })

  it('clears a case only as a proposal for a second administrator', async () => {
    const user = userEvent.setup()
    const { calls } = mockApi({
      ...signedIn('admin'),
      ...noProposals(),
      [`GET /content-cases/${caseId}`]: () => ({ data: { case: contentCase(), mediaAvailable: false } }),
      [`POST /content-cases/${caseId}/proposals`]: () => ({ status: 201, data: { approval: proposal({ proposedBy: 'op-1' }) } }),
    })
    renderAt(`/content/${caseId}`)
    expect(screen.queryByRole('button', { name: /^Clear/ })).not.toBeInTheDocument()
    await user.click(await screen.findByRole('button', { name: 'Propose clearing (false positive)…' }))
    const dialog = screen.getByRole('dialog', { name: 'Propose clearing this case' })
    await user.type(within(dialog).getByLabelText(/Reason/), 'the list entry was wrong')
    await user.click(within(dialog).getByRole('button', { name: 'Propose clearing' }))
    await waitFor(() => expect(calls.some((c) => c.path.endsWith('/proposals') && c.method === 'POST')).toBe(true))
    expect(calls.find((c) => c.path.endsWith('/proposals') && c.method === 'POST')!.body).toEqual({ kind: 'clear', reason: 'the list entry was wrong' })
    // Nothing was resolved from this screen.
    expect(calls.some((c) => c.path.endsWith('/resolve'))).toBe(false)
  })

  it('lets a different administrator approve, but only lets the proposer wait or withdraw', async () => {
    const user = userEvent.setup()
    let items = [proposal()]
    const { calls } = mockApi({
      ...signedIn('admin'), // operator op-1
      [`GET /content-cases/${caseId}/proposals`]: () => ({ data: { items, operatorId: 'op-1' } }),
      [`GET /content-cases/${caseId}`]: () => ({ data: { case: contentCase(), mediaAvailable: false } }),
      'POST /approvals/ap-1/approve': () => {
        items = [proposal({ status: 'approved', decidedBy: 'op-1', decidedByEmail: 'sam@hiyall.test', decidedAt: '2026-10-14T10:00:00Z', decisionReason: 'second look agrees' })]
        return { data: { approval: items[0] } }
      },
    })
    const view = renderAt(`/content/${caseId}`)
    expect(await screen.findByText(/Proposed by ada@hiyall.test/)).toBeInTheDocument()
    expect(screen.queryByText('Waiting for a different administrator.')).not.toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Approve…' }))
    const dialog = screen.getByRole('dialog', { name: /Approve: Clear the case/ })
    await user.type(within(dialog).getByLabelText(/Reason/), 'second look agrees')
    await user.click(within(dialog).getByRole('button', { name: 'Approve' }))
    await waitFor(() => expect(calls.some((c) => c.path === '/approvals/ap-1/approve')).toBe(true))
    expect(calls.find((c) => c.path === '/approvals/ap-1/approve')!.body).toEqual({ reason: 'second look agrees' })
    expect(await screen.findByText(/Approved. The step has been carried out./)).toBeInTheDocument()
    view.unmount()

    // The proposer's own view: no Approve and no Reject, only a note and Withdraw.
    mockApi({
      ...signedIn('admin'),
      [`GET /content-cases/${caseId}/proposals`]: () => ({ data: { items: [proposal({ proposedBy: 'op-1', proposedByEmail: 'sam@hiyall.test' })], operatorId: 'op-1' } }),
      [`GET /content-cases/${caseId}`]: () => ({ data: { case: contentCase(), mediaAvailable: false } }),
    })
    renderAt(`/content/${caseId}`)
    expect(await screen.findByText('Waiting for a different administrator.')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Approve…' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Reject…' })).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Withdraw…' })).toBeInTheDocument()
  })

  it('shows the server refusal when the proposer is the approver', async () => {
    const user = userEvent.setup()
    mockApi({
      ...signedIn('admin'),
      [`GET /content-cases/${caseId}/proposals`]: () => ({ data: { items: [proposal()], operatorId: 'op-1' } }),
      [`GET /content-cases/${caseId}`]: () => ({ data: { case: contentCase(), mediaAvailable: false } }),
      'POST /approvals/ap-1/approve': () => ({ status: 403, error: { code: 'SECOND_APPROVER_REQUIRED', message: 'A different administrator has to approve this' } }),
    })
    renderAt(`/content/${caseId}`)
    await user.click(await screen.findByRole('button', { name: 'Approve…' }))
    await user.type(screen.getByLabelText(/Reason/), 'approving it anyway')
    await user.click(screen.getByRole('button', { name: 'Approve' }))
    expect(await within(screen.getByRole('dialog')).findByText('A different administrator has to approve this')).toBeInTheDocument()
  })

  it('lifts a legal hold only as a proposal with counsel’s reference', async () => {
    const user = userEvent.setup()
    const { calls } = mockApi({
      ...signedIn('admin'),
      ...noProposals(),
      [`GET /content-cases/${caseId}`]: () => ({ data: { case: contentCase({ status: 'reported', legalHold: true, releaseBlocker: 'LEGAL_HOLD' }), mediaAvailable: false } }),
      [`POST /content-cases/${caseId}/proposals`]: () => ({ status: 201, data: { approval: proposal({ kind: 'legal_hold_lift', proposedBy: 'op-1', counselReference: 'Counsel M. Okafor 2027-02-03' }) } }),
    })
    renderAt(`/content/${caseId}`)
    await user.click(await screen.findByRole('button', { name: 'Propose lifting the legal hold…' }))
    const dialog = screen.getByRole('dialog', { name: 'Propose lifting the legal hold' })
    const submit = within(dialog).getByRole('button', { name: 'Propose lifting' })
    await user.type(within(dialog).getByLabelText(/Reason/), 'counsel has closed the matter')
    expect(submit).toBeDisabled() // counsel's reference is required
    await user.type(within(dialog).getByLabelText(/Counsel’s instruction/), 'Counsel M. Okafor 2027-02-03')
    await user.click(submit)
    await waitFor(() => expect(calls.some((c) => c.path.endsWith('/proposals') && c.method === 'POST')).toBe(true))
    expect(calls.find((c) => c.path.endsWith('/proposals') && c.method === 'POST')!.body).toEqual({ kind: 'legal_hold_lift', reason: 'counsel has closed the matter', counselReference: 'Counsel M. Okafor 2027-02-03' })
    // Resolving can never switch a legal hold off: the case page has no such control.
    expect(screen.queryByRole('checkbox', { name: /legal hold/i })).not.toBeInTheDocument()
  })

  it('disables the release proposal and names the blocker while the case is open, under legal hold or referenced', async () => {
    const cases: [string, string, RegExp][] = [
      ['CASE_OPEN', 'open', /Resolve the case first/],
      ['LEGAL_HOLD', 'confirmed', /legal hold keeps this evidence/],
      ['REPORT_OPEN', 'cleared', /open report about this member/],
      ['OTHER_CASE_OPEN', 'cleared', /Another open case of this member/],
    ]
    for (const [blocker, status, text] of cases) {
      mockApi({ ...signedIn('admin'), ...noProposals(), [`GET /content-cases/${caseId}`]: () => ({ data: { case: contentCase({ status, releaseBlocker: blocker }), mediaAvailable: false } }) })
      const { unmount } = renderAt(`/content/${caseId}`)
      expect(await screen.findByText(text)).toBeInTheDocument()
      expect(screen.getByRole('button', { name: 'Propose releasing the hold…' })).toBeDisabled()
      unmount()
    }
  })

  it('shows no release to a moderator', async () => {
    mockApi({ ...signedIn('moderator'), [`GET /content-cases/${caseId}`]: () => ({ data: { case: contentCase({ status: 'cleared' }), mediaAvailable: false } }) })
    renderAt(`/content/${caseId}`)
    await screen.findByText(/Only administrators can decide a case/)
    expect(screen.queryByRole('button', { name: /Propose/ })).not.toBeInTheDocument()
  })
})

describe('approvals queue', () => {
  it('lists what waits for a second administrator and says which are the operator’s own', async () => {
    mockApi({
      ...signedIn('admin'),
      'GET /approvals?status=pending': () => ({ data: { items: [proposal(), proposal({ approvalId: 'ap-2', kind: 'release', proposedBy: 'op-1', proposedByEmail: 'sam@hiyall.test' })], operatorId: 'op-1' } }),
    })
    renderAt('/approvals')
    expect(await screen.findByRole('link', { name: 'Open case to decide' })).toHaveAttribute('href', `/content/${caseId}`)
    expect(screen.getByRole('link', { name: 'Open case (waiting for someone else)' })).toBeInTheDocument()
    expect(screen.getByText('you')).toBeInTheDocument()
  })

  it('is for administrators only', async () => {
    mockApi({ ...signedIn('moderator') })
    renderAt('/approvals')
    expect(await screen.findByText('Your role does not allow this page.')).toBeInTheDocument()
    expect(screen.queryByRole('link', { name: 'Approvals' })).not.toBeInTheDocument()
  })
})
