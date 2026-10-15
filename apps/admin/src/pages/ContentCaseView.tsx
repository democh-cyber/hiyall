import { useState } from 'react'
import { Link, useParams } from 'react-router'
import { api, approvalKindText, type ApprovalList, type ContentCase, type EvidenceApproval } from '../api'
import { useOperator } from '../auth'
import { Chip, ErrorNote, formatBytes, ReasonDialog, Time, useLoad } from '../ui'

type Pending = 'confirm' | 'reported' | 'view' | 'propose-clear' | 'propose-release' | 'propose-lift' | { decide: 'approve' | 'reject' | 'withdraw'; approval: EvidenceApproval } | null

const blockerText: Record<string, string> = {
  CASE_OPEN: 'Resolve the case first.',
  LEGAL_HOLD: 'A legal hold keeps this evidence. It is lifted only on counsel’s instruction.',
  REPORT_OPEN: 'An open report about this member references the evidence.',
  OTHER_CASE_OPEN: 'Another open case of this member references the evidence.',
}

interface Detail {
  case: ContentCase
  mediaAvailable: boolean
}

/**
 * One quarantined upload. Everyone moderator and up sees the evidence record. Only administrators can load the image:
 * first with a written reason (the SERVER sends a small, heavily blurred copy, so the original pixels are not in
 * the page), then with an explicit Reveal (also audited), which returns a second link that works for one minute.
 * Clearing a case, releasing a hold and lifting a legal hold are proposals that a DIFFERENT administrator approves.
 * Nothing here is sent to anyone; reporting to the authorities is done by a person outside the console, and the
 * reference is recorded.
 */
export function ContentCaseView() {
  const { id = '' } = useParams()
  const operator = useOperator()
  const isAdmin = operator.role === 'admin'
  const { data, error, loading, reload } = useLoad(() => api<Detail>('GET', `/content-cases/${id}`), id)
  const [pending, setPending] = useState<Pending>(null)
  const proposals = useLoad(() => api<ApprovalList>('GET', `/content-cases/${id}/proposals`), id)
  const [photo, setPhoto] = useState<{ blurUrl: string; fullUrl: string | null; reason: string; revealed: boolean; expired: boolean } | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [revealError, setRevealError] = useState<string | null>(null)

  if (loading && !data) return <p role="status">Loading…</p>
  if (!data) return <ErrorNote error={error ?? 'Not found'} />
  const c = data.case

  async function step(action: 'confirm' | 'reported', reason: string, reference: string) {
    await api('POST', `/content-cases/${id}/resolve`, { action, reason, reportReference: action === 'reported' ? reference : undefined })
    setPending(null)
    setNotice(action === 'confirm' ? 'Case confirmed and held as evidence.' : 'Report reference recorded.')
    await reload()
  }

  /** Proposes clearing, releasing the hold or lifting the legal hold; a different administrator has to approve it. */
  async function propose(kind: 'clear' | 'release' | 'legal_hold_lift', reason: string, counselReference: string) {
    await api('POST', `/content-cases/${id}/proposals`, { kind, reason, counselReference: kind === 'legal_hold_lift' ? counselReference : undefined })
    setPending(null)
    setNotice('Proposal recorded. A different administrator has to approve it within 24 hours.')
    await proposals.reload()
  }

  async function decide(approval: EvidenceApproval, decision: 'approve' | 'reject' | 'withdraw', reason: string) {
    await api('POST', `/approvals/${approval.approvalId}/${decision}`, { reason })
    setPending(null)
    setNotice(decision === 'approve' ? 'Approved. The step has been carried out.' : decision === 'reject' ? 'Proposal rejected.' : 'Proposal withdrawn.')
    await Promise.all([reload(), proposals.reload()])
  }

  async function load(reason: string) {
    const out = await api<{ url: string }>('POST', `/content-cases/${id}/view`, { reason })
    setPhoto({ blurUrl: out.url, fullUrl: null, reason, revealed: false, expired: false })
    setPending(null)
  }

  async function reveal() {
    if (!photo) return
    setRevealError(null)
    try {
      // The reveal is audited and returns a second link, good for one minute, to the unblurred image.
      const out = await api<{ url: string }>('POST', `/content-cases/${id}/reveal`, { reason: photo.reason })
      setPhoto({ ...photo, fullUrl: out.url, revealed: true, expired: false })
    } catch (e) {
      setRevealError(e instanceof Error ? e.message : 'Could not record the reveal')
    }
  }

  const open = c.status === 'open'
  return (
    <article aria-labelledby="ccase-title">
      <p><Link to="/content">← Quarantined uploads</Link></p>
      <h1 id="ccase-title">
        Case {c.caseId.slice(-8)} <span className="chips">
          <Chip kind={c.result === 'match' ? 'high' : 'warn'}>{c.result}</Chip>
          {c.ageBand === 'minor' && <Chip kind="minor">uploader is a minor</Chip>}
          <Chip kind={open ? 'warn' : 'ok'}>{c.status}</Chip>
          {c.legalHold && <Chip kind="neutral">legal hold</Chip>}
        </span>
      </h1>
      {notice && <p role="status" className="notice">{notice}</p>}
      <ErrorNote error={error} />

      <dl className="facts">
        <dt>Uploader</dt><dd><Link to={`/users/${c.userId}`}>@{c.username || 'unknown'}</Link> ({c.accountStatus}){c.suspendedUser && ' · suspended by the scanner pending review'}</dd>
        <dt>Purpose</dt><dd>{c.purpose}</dd>
        <dt>Scanner</dt><dd>{c.scanner}{Object.entries(c.signals).map(([k, v]) => <span key={k}> · {k}: <code>{v}</code></span>)}</dd>
        <dt>Original</dt><dd>{c.contentType}, {formatBytes(c.originalBytes)}, SHA-256 <code>{c.originalSha256}</code></dd>
        <dt>Detected</dt><dd><Time value={c.createdAt} /></dd>
        <dt>Held until</dt><dd><Time value={c.holdUntil} />{c.legalHold && ' (a legal hold keeps it longer)'}</dd>
        {c.releasedAt && (<><dt>Hold released</dt><dd>{c.releasedBy} · <Time value={c.releasedAt} />{c.releaseReason && ` — ${c.releaseReason}`}{c.objectsPurgedAt ? <> · files removed <Time value={c.objectsPurgedAt} /></> : ' · files are removed after the held-until date'}</dd></>)}
        {c.reviewedBy && (<><dt>Last step</dt><dd>{c.reviewedBy} · <Time value={c.reviewedAt} />{c.resolutionNote && ` — ${c.resolutionNote}`}</dd></>)}
        {c.reportReference && (<><dt>Reported</dt><dd><code>{c.reportReference}</code> · <Time value={c.reportedAt} /></dd></>)}
      </dl>

      <section aria-labelledby="photo-title">
        <h2 id="photo-title">The image</h2>
        {!isAdmin ? (
          <p className="hint">Only administrators can look at quarantined images.</p>
        ) : !data.mediaAvailable ? (
          <p className="hint">The console has no access to photo storage (ADMIN_MEDIA_*).</p>
        ) : !photo ? (
          <>
            <p className="sensitive">This may be illegal imagery. Look only if you must to decide the case. Every view is recorded with your name and reason. Do not copy, save or share it.</p>
            <button type="button" className="secondary" onClick={() => setPending('view')}>Load image (blurred)…</button>
          </>
        ) : (
          <>
            <div className="photos">
              {/* The blur is made by the server: this is a small, blurred copy, not the original under a filter. */}
              <img src={photo.revealed && photo.fullUrl ? photo.fullUrl : photo.blurUrl} alt={photo.revealed ? 'Quarantined upload' : 'Quarantined upload, blurred'}
                onError={() => photo.revealed && setPhoto({ ...photo, revealed: false, fullUrl: null, expired: true })} />
            </div>
            {photo.expired && <p role="status" className="hint">The unblurred link works for one minute and has ended. Reveal again if you must.</p>}
            {photo.revealed && <p className="hint">This link works for one minute.</p>}
            <div className="actions">
              {photo.revealed
                ? <button type="button" className="secondary" onClick={() => setPhoto({ ...photo, revealed: false, fullUrl: null })}>Blur again</button>
                : <button type="button" className="danger" onClick={() => void reveal()}>Reveal image</button>}
            </div>
            <ErrorNote error={revealError} />
          </>
        )}
      </section>

      {isAdmin && (c.status === 'open' || c.status === 'confirmed') && (
        <section aria-labelledby="decide-title" className="actions-bar">
          <h2 id="decide-title">Decide</h2>
          <div className="actions">
            {open && <button type="button" className="secondary" onClick={() => setPending('propose-clear')}>Propose clearing (false positive)…</button>}
            {open && <button type="button" className="primary" onClick={() => setPending('confirm')}>Confirm and hold as evidence</button>}
            <button type="button" className="danger" onClick={() => setPending('reported')}>Record that it was reported…</button>
          </div>
          <p className="hint">The console never sends anything to NCMEC or an authority. Report outside it, then record the reference here. See the runbook.
            Clearing a case needs a second administrator to approve your proposal.</p>
        </section>
      )}
      {!isAdmin && <p className="hint">Only administrators can decide a case.</p>}

      {isAdmin && (
        <section aria-labelledby="proposals-title" className="actions-bar">
          <h2 id="proposals-title">Two-person approvals</h2>
          <ErrorNote error={proposals.error} />
          {(proposals.data?.items ?? []).length === 0 && <p className="hint">No proposals for this case.</p>}
          <ul className="proposals">
            {(proposals.data?.items ?? []).map((a) => {
              const mine = a.proposedBy === proposals.data?.operatorId
              return (
                <li key={a.approvalId}>
                  <strong>{approvalKindText[a.kind]}</strong> <Chip kind={a.status === 'pending' ? 'warn' : a.status === 'approved' ? 'ok' : 'neutral'}>{a.status}</Chip>
                  <div className="hint">
                    Proposed by {a.proposedByEmail} · <Time value={a.proposedAt} /> — {a.reason}
                    {a.counselReference && <> · counsel: <code>{a.counselReference}</code></>}
                    {a.status === 'pending' && <> · expires <Time value={a.expiresAt} /></>}
                    {a.decidedAt && <> · {a.status} by {a.decidedByEmail || a.proposedByEmail} — {a.decisionReason}</>}
                  </div>
                  {a.status === 'pending' && (
                    <div className="actions">
                      {mine ? (
                        <>
                          <span className="hint">Waiting for a different administrator.</span>
                          <button type="button" className="secondary" onClick={() => setPending({ decide: 'withdraw', approval: a })}>Withdraw…</button>
                        </>
                      ) : (
                        <>
                          <button type="button" className="primary" onClick={() => setPending({ decide: 'approve', approval: a })}>Approve…</button>
                          <button type="button" className="secondary" onClick={() => setPending({ decide: 'reject', approval: a })}>Reject…</button>
                        </>
                      )}
                    </div>
                  )}
                </li>
              )
            })}
          </ul>
          {c.legalHold && !(proposals.data?.items ?? []).some((a) => a.kind === 'legal_hold_lift' && a.status === 'pending') && (
            <div className="actions">
              <button type="button" className="secondary" onClick={() => setPending('propose-lift')}>Propose lifting the legal hold…</button>
            </div>
          )}
        </section>
      )}

      {isAdmin && !c.releasedAt && (
        <section aria-labelledby="release-title" className="actions-bar">
          <h2 id="release-title">Evidence hold</h2>
          {c.releaseBlocker ? (
            <p className="hint" role="note">The hold cannot be released yet. {blockerText[c.releaseBlocker] ?? c.releaseBlocker}</p>
          ) : (
            <p className="hint">Releasing deletes nothing at once, and needs a second administrator to approve. The files under the hold are removed by the console after the held-until date, and the case record stays.</p>
          )}
          <div className="actions">
            <button type="button" className="secondary" disabled={!!c.releaseBlocker} onClick={() => setPending('propose-release')}>Propose releasing the hold…</button>
          </div>
        </section>
      )}

      {pending === 'view' && (
        <ReasonDialog title="Load the quarantined image" confirmLabel="Load blurred image" danger
          intro={<p>The image loads blurred. You then choose whether to reveal it. Both steps are written to the audit log with your reason.</p>}
          onSubmit={(reason) => load(reason)} onClose={() => setPending(null)} />
      )}
      {pending === 'confirm' && (
        <ReasonDialog title="Confirm this case" confirmLabel="Confirm case" danger onSubmit={(reason) => step('confirm', reason, '')} onClose={() => setPending(null)} />
      )}
      {pending === 'propose-clear' && (
        <ReasonDialog title="Propose clearing this case" confirmLabel="Propose clearing"
          intro={<p>A different administrator has to approve this within 24 hours; nothing changes until they do. The photo stays held until its date. Restoring the member, if they were suspended, is a separate step on their page.</p>}
          onSubmit={(reason) => propose('clear', reason, '')} onClose={() => setPending(null)} />
      )}
      {pending === 'propose-release' && (
        <ReasonDialog title="Propose releasing the evidence hold" confirmLabel="Propose release" danger
          intro={<p>Do this only when counsel, or your written retention rule, says the evidence is no longer needed. A different administrator has to approve it. The files are removed by the console once the held-until date has passed, and the removal is audited.</p>}
          onSubmit={(reason) => propose('release', reason, '')} onClose={() => setPending(null)} />
      )}
      {pending === 'propose-lift' && (
        <ReasonDialog title="Propose lifting the legal hold" confirmLabel="Propose lifting" danger referenceLabel="Counsel’s instruction (who, and a date or reference)"
          intro={<p>A legal hold is lifted only on counsel’s instruction. Name it here; a different administrator has to approve, and both of you are recorded.</p>}
          onSubmit={(reason, reference) => propose('legal_hold_lift', reason, reference)} onClose={() => setPending(null)} />
      )}
      {typeof pending === 'object' && pending !== null && (
        <ReasonDialog
          title={`${pending.decide === 'approve' ? 'Approve' : pending.decide === 'reject' ? 'Reject' : 'Withdraw'}: ${approvalKindText[pending.approval.kind]}`}
          confirmLabel={pending.decide === 'approve' ? 'Approve' : pending.decide === 'reject' ? 'Reject' : 'Withdraw'} danger={pending.decide === 'approve'}
          intro={<p>Proposed by {pending.approval.proposedByEmail}: {pending.approval.reason}{pending.approval.counselReference && <> (counsel: {pending.approval.counselReference})</>}</p>}
          onSubmit={(reason) => decide(pending.approval, pending.decide, reason)} onClose={() => setPending(null)} />
      )}
      {pending === 'reported' && (
        <ReasonDialog title="Record the report" confirmLabel="Record reference" referenceLabel="Report number or authority reference"
          onSubmit={(reason, reference) => step('reported', reason, reference)} onClose={() => setPending(null)} />
      )}
    </article>
  )
}
