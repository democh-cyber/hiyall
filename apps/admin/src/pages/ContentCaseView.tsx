import { useState } from 'react'
import { Link, useParams } from 'react-router'
import { api, type ContentCase } from '../api'
import { useOperator } from '../auth'
import { Chip, ErrorNote, formatBytes, ReasonDialog, Time, useLoad } from '../ui'

type Pending = 'confirm' | 'clear' | 'reported' | 'view' | 'reveal' | null

interface Detail {
  case: ContentCase
  mediaAvailable: boolean
}

/**
 * One quarantined upload. Everyone moderator and up sees the evidence record. Only administrators can load the image:
 * first with a written reason (it arrives blurred), then with an explicit Reveal (also audited). Nothing here
 * is sent to anyone; reporting to the authorities is done by a person outside the console, and the reference is recorded.
 */
export function ContentCaseView() {
  const { id = '' } = useParams()
  const operator = useOperator()
  const isAdmin = operator.role === 'admin'
  const { data, error, loading, reload } = useLoad(() => api<Detail>('GET', `/content-cases/${id}`), id)
  const [pending, setPending] = useState<Pending>(null)
  const [photo, setPhoto] = useState<{ url: string; reason: string; revealed: boolean } | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [revealError, setRevealError] = useState<string | null>(null)

  if (loading && !data) return <p role="status">Loading…</p>
  if (!data) return <ErrorNote error={error ?? 'Not found'} />
  const c = data.case

  async function step(action: 'confirm' | 'clear' | 'reported', reason: string, reference: string) {
    await api('POST', `/content-cases/${id}/resolve`, { action, reason, reportReference: action === 'reported' ? reference : undefined })
    setPending(null)
    setNotice(action === 'confirm' ? 'Case confirmed and held as evidence.' : action === 'clear' ? 'Case cleared.' : 'Report reference recorded.')
    await reload()
  }

  async function load(reason: string) {
    const out = await api<{ url: string }>('POST', `/content-cases/${id}/view`, { reason })
    setPhoto({ url: out.url, reason, revealed: false })
    setPending(null)
  }

  async function reveal() {
    if (!photo) return
    setRevealError(null)
    try {
      await api('POST', `/content-cases/${id}/reveal`, { reason: photo.reason })
      setPhoto({ ...photo, revealed: true })
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
              <img src={photo.url} alt={photo.revealed ? 'Quarantined upload' : 'Quarantined upload, blurred'} className={photo.revealed ? '' : 'blurred'} />
            </div>
            <div className="actions">
              {photo.revealed
                ? <button type="button" className="secondary" onClick={() => setPhoto({ ...photo, revealed: false })}>Blur again</button>
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
            {open && <button type="button" className="secondary" onClick={() => setPending('clear')}>Clear (false positive)</button>}
            {open && <button type="button" className="primary" onClick={() => setPending('confirm')}>Confirm and hold as evidence</button>}
            <button type="button" className="danger" onClick={() => setPending('reported')}>Record that it was reported…</button>
          </div>
          <p className="hint">The console never sends anything to NCMEC or an authority. Report outside it, then record the reference here. See the runbook.</p>
        </section>
      )}
      {!isAdmin && <p className="hint">Only administrators can decide a case.</p>}

      {pending === 'view' && (
        <ReasonDialog title="Load the quarantined image" confirmLabel="Load blurred image" danger
          intro={<p>The image loads blurred. You then choose whether to reveal it. Both steps are written to the audit log with your reason.</p>}
          onSubmit={(reason) => load(reason)} onClose={() => setPending(null)} />
      )}
      {(pending === 'confirm' || pending === 'clear') && (
        <ReasonDialog title={pending === 'confirm' ? 'Confirm this case' : 'Clear this case'}
          confirmLabel={pending === 'confirm' ? 'Confirm case' : 'Clear case'} danger={pending === 'confirm'}
          intro={pending === 'clear' ? <p>The photo stays held until its date. Restoring the member, if they were suspended, is a separate step on their page.</p> : undefined}
          onSubmit={(reason) => step(pending, reason, '')} onClose={() => setPending(null)} />
      )}
      {pending === 'reported' && (
        <ReasonDialog title="Record the report" confirmLabel="Record reference" referenceLabel="Report number or authority reference"
          onSubmit={(reason, reference) => step('reported', reason, reference)} onClose={() => setPending(null)} />
      )}
    </article>
  )
}
