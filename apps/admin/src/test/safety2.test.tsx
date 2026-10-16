import { render, screen, waitFor, within } from '@testing-library/react'
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
const caseId = '019a0000-0000-7000-8000-0000000000c1'

const promotion = (over: Record<string, unknown> = {}) => ({
  approvalId: 'ap-9', caseId: '', kind: 'promote_admin', status: 'pending', proposedBy: 'op-2', proposedByEmail: 'ada@hiyall.test', proposedAt: '2026-10-14T09:00:00Z',
  reason: 'new on-call administrator', counselReference: '', expiresAt: '2026-10-15T09:00:00Z', decidedBy: '', decidedByEmail: '', decidedAt: null, decisionReason: '',
  targetOperator: 'op-7', targetOperatorEmail: 'kim@hiyall.test', ...over,
})

describe('two-person control of administrators', () => {
  it('warns when fewer than two administrators are active', async () => {
    mockApi({ ...signedIn('admin'), 'GET /approvals?status=pending': () => ({ data: { items: [], operatorId: 'op-1', activeAdmins: 1 } }) })
    renderAt('/approvals')
    expect(await screen.findByText(/Only 1 active administrator: nothing here can be approved until there are two/)).toBeInTheDocument()
  })

  it('does not warn with two administrators', async () => {
    mockApi({ ...signedIn('admin'), 'GET /approvals?status=pending': () => ({ data: { items: [], operatorId: 'op-1', activeAdmins: 2 } }) })
    renderAt('/approvals')
    await screen.findByText('Nothing is waiting.')
    expect(screen.queryByText(/nothing here can be approved/)).not.toBeInTheDocument()
  })

  it('lets a different administrator approve a promotion on the page, and the proposer only withdraw', async () => {
    const user = userEvent.setup()
    let items = [promotion(), promotion({ approvalId: 'ap-10', proposedBy: 'op-1', proposedByEmail: 'sam@hiyall.test', targetOperatorEmail: 'lee@hiyall.test' })]
    const { calls } = mockApi({
      ...signedIn('admin'),
      'GET /approvals?status=pending': () => ({ data: { items, operatorId: 'op-1', activeAdmins: 2 } }),
      'POST /approvals/ap-9/approve': () => { items = items.slice(1); return { data: { approval: promotion({ status: 'approved' }) } } },
    })
    renderAt('/approvals')
    expect(await screen.findByText('kim@hiyall.test')).toBeInTheDocument()
    expect(screen.getAllByRole('button', { name: 'Withdraw…' })).toHaveLength(1) // only the operator's own proposal
    expect(screen.getAllByRole('button', { name: 'Approve…' })).toHaveLength(1)
    await user.click(screen.getByRole('button', { name: 'Approve…' }))
    const dialog = screen.getByRole('dialog', { name: /Approve: Make an operator an administrator/ })
    await user.type(within(dialog).getByLabelText(/Reason/), 'checked with the team lead')
    await user.click(within(dialog).getByRole('button', { name: 'Approve' }))
    await waitFor(() => expect(calls.some((c) => c.path === '/approvals/ap-9/approve')).toBe(true))
    expect(calls.find((c) => c.path === '/approvals/ap-9/approve')!.body).toEqual({ reason: 'checked with the team lead' })
    expect(await screen.findByText('Approved. The step has been carried out.')).toBeInTheDocument()
  })

  it('makes promoting an operator a proposal and says so', async () => {
    const user = userEvent.setup()
    const ops = [
      { operatorId: 'op-1', email: 'sam@hiyall.test', displayName: 'Sam', role: 'admin', disabledAt: null, createdAt: '2026-10-01T00:00:00Z', lastLoginAt: null },
      { operatorId: 'op-7', email: 'kim@hiyall.test', displayName: 'Kim', role: 'moderator', disabledAt: null, createdAt: '2026-10-01T00:00:00Z', lastLoginAt: null },
    ]
    const { calls } = mockApi({
      ...signedIn('admin'),
      'GET /operators': () => ({ data: { items: ops } }),
      'POST /operators/op-7/role': () => ({ status: 202, data: { pending: true, approval: promotion() } }),
    })
    renderAt('/operators')
    await user.selectOptions(await screen.findByLabelText('Role of kim@hiyall.test'), 'admin')
    await user.click(screen.getByRole('button', { name: 'Change role' }))
    const dialog = screen.getByRole('dialog')
    expect(within(dialog).getByText(/only proposes the promotion/)).toBeInTheDocument()
    await user.type(within(dialog).getByLabelText(/Reason/), 'new on-call administrator')
    await user.click(within(dialog).getByRole('button', { name: 'Propose promotion' }))
    expect(await screen.findByText(/Proposal recorded: kim@hiyall.test becomes an administrator when a different administrator approves/)).toBeInTheDocument()
    expect(calls.find((c) => c.path === '/operators/op-7/role')!.body).toEqual({ role: 'admin', reason: 'new on-call administrator' })
  })
})

describe('counsel’s reference form', () => {
  it('keeps the proposal disabled until the reference matches the rule', async () => {
    const user = userEvent.setup()
    mockApi({
      ...signedIn('admin'),
      [`GET /content-cases/${caseId}/proposals`]: () => ({ data: { items: [], operatorId: 'op-1' } }),
      [`GET /content-cases/${caseId}`]: () => ({
        data: { mediaAvailable: false, case: { caseId, mediaId: 'm-9', userId: 'u-1', username: 'bob', ageBand: 'adult', accountStatus: 'active', purpose: 'post', result: 'match', scanner: 'hashlist', signals: {}, originalSha256: 'ab', originalBytes: 10, contentType: 'image/jpeg', suspendedUser: false, status: 'reported', createdAt: '2026-10-13T10:00:00Z', holdUntil: '2027-10-13T10:00:00Z', legalHold: true, reviewedBy: '', reviewedAt: null, resolutionNote: '', reportReference: 'N-1', reportedAt: null, releasedAt: null, releasedBy: '', releaseReason: '', objectsPurgedAt: null, releaseBlocker: 'LEGAL_HOLD' } },
      }),
    })
    renderAt(`/content/${caseId}`)
    await user.click(await screen.findByRole('button', { name: 'Propose lifting the legal hold…' }))
    const dialog = screen.getByRole('dialog', { name: 'Propose lifting the legal hold' })
    const submit = within(dialog).getByRole('button', { name: 'Propose lifting' })
    await user.type(within(dialog).getByLabelText(/Reason/), 'counsel has closed the matter')
    const ref = within(dialog).getByLabelText(/Counsel’s instruction/)
    expect(within(dialog).getByText(/no commas/)).toBeInTheDocument()
    for (const bad of ['Okafor, 2027', 'short', '-Okafor email']) {
      await user.clear(ref)
      await user.type(ref, bad)
      expect(submit).toBeDisabled()
    }
    await user.clear(ref)
    await user.type(ref, 'Counsel Okafor email 2027-02-03')
    expect(submit).toBeEnabled()
  })

  it('says a pending case cannot be decided yet', async () => {
    mockApi({
      ...signedIn('admin'),
      [`GET /content-cases/${caseId}/proposals`]: () => ({ data: { items: [], operatorId: 'op-1' } }),
      [`GET /content-cases/${caseId}`]: () => ({
        data: { mediaAvailable: false, case: { caseId, mediaId: 'm-9', userId: 'u-1', username: 'bob', ageBand: 'adult', accountStatus: 'active', purpose: 'post', result: 'flagged', scanner: 'hashlist', signals: {}, originalSha256: 'ab', originalBytes: 10, contentType: 'image/jpeg', suspendedUser: false, status: 'pending', createdAt: '2026-10-13T10:00:00Z', holdUntil: '2027-10-13T10:00:00Z', legalHold: false, reviewedBy: '', reviewedAt: null, resolutionNote: '', reportReference: '', reportedAt: null, releasedAt: null, releasedBy: '', releaseReason: '', objectsPurgedAt: null, releaseBlocker: 'CASE_OPEN' } },
      }),
    })
    renderAt(`/content/${caseId}`)
    expect(await screen.findByText(/This case is pending: the evidence objects have not been confirmed yet/)).toBeInTheDocument()
  })
})

describe('Apple revocations and evidence orphans', () => {
  const revocation = { revocationId: 'rv-1', issuer: 'https://securetoken.google.com/p', subject: 'fb-uid-1', userId: 'u-77', reason: 'the app could not obtain a Sign in with Apple authorization code', createdAt: '2026-10-14T09:00:00Z' }

  it('lists the manual revocations and marks one done with a reason', async () => {
    const user = userEvent.setup()
    let items = [revocation]
    const { calls } = mockApi({
      ...signedIn('admin'),
      'GET /apple-revocations': () => ({ data: { items } }),
      'POST /apple-revocations/rv-1/revoked': () => { items = []; return { data: { revocationId: 'rv-1', done: true } } },
    })
    renderAt('/apple-revocations')
    expect(await screen.findByText('fb-uid-1')).toBeInTheDocument()
    expect(screen.getByText('u-77')).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Mark revoked…' }))
    const dialog = screen.getByRole('dialog', { name: 'Mark the Apple authorization revoked' })
    const submit = within(dialog).getByRole('button', { name: 'Mark revoked' })
    expect(submit).toBeDisabled()
    await user.type(within(dialog).getByLabelText(/Reason/), 'revoked in Apple console, ticket 7')
    await user.click(submit)
    expect(await screen.findByText('Nothing to revoke.')).toBeInTheDocument()
    expect(calls.find((c) => c.path === '/apple-revocations/rv-1/revoked')!.body).toEqual({ reason: 'revoked in Apple console, ticket 7' })
  })

  it('shows evidence objects without a case', async () => {
    mockApi({
      ...signedIn('admin'),
      'GET /evidence/orphans': () => ({ data: { checkedAt: '2026-10-14T09:00:00Z', complete: true, items: [{ key: 'hold/019a0000-0000-7000-8000-0000000000aa/original', mediaId: '019a0000-0000-7000-8000-0000000000aa', lastModified: '2026-10-14T05:00:00Z' }] } }),
    })
    renderAt('/evidence-orphans')
    expect(await screen.findByText('hold/019a0000-0000-7000-8000-0000000000aa/original')).toBeInTheDocument()
  })

  it('is for administrators only, in the pages and in the navigation', async () => {
    mockApi({ ...signedIn('moderator') })
    renderAt('/apple-revocations')
    expect(await screen.findByText('Your role does not allow this page.')).toBeInTheDocument()
    expect(screen.queryByRole('link', { name: 'Apple revocations' })).not.toBeInTheDocument()
    expect(screen.queryByRole('link', { name: 'Evidence orphans' })).not.toBeInTheDocument()
  })

  it('offers the pages to an administrator', async () => {
    mockApi({ ...signedIn('admin'), 'GET /reports*': () => ({ data: { items: [], nextCursor: null, hasMore: false } }) })
    renderAt('/')
    expect(await screen.findByRole('link', { name: 'Apple revocations' })).toHaveAttribute('href', '/apple-revocations')
    expect(screen.getByRole('link', { name: 'Evidence orphans' })).toHaveAttribute('href', '/evidence-orphans')
  })
})
