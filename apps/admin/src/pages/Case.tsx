import { useState } from 'react'
import { Link, useParams } from 'react-router'
import { api, canModerate, hasPreview, type Case as CaseData, type ContentPreview, type Member } from '../api'
import { useOperator } from '../auth'
import { Chip, ErrorNote, formatBytes, ReasonDialog, Time, useLoad } from '../ui'

type Pending = 'dismiss' | 'warn' | 'suspend' | null

export function Case() {
  const { id = '' } = useParams()
  const operator = useOperator()
  const { data: c, error, loading, reload } = useLoad(() => api<CaseData>('GET', `/reports/${id}`), id)
  const [pending, setPending] = useState<Pending>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [asking, setAsking] = useState(false)
  const [preview, setPreview] = useState<ContentPreview | null>(null)

  if (loading && !c) return <p role="status">Loading…</p>
  if (!c) return <ErrorNote error={error ?? 'Not found'} />
  const mayAct = canModerate(operator.role) && c.status === 'open'

  async function resolve(action: 'dismiss' | 'warn' | 'suspend', reason: string) {
    await api('POST', `/reports/${id}/resolve`, { action, reason, confirm: action === 'suspend' ? true : undefined })
    setPending(null)
    setNotice(action === 'dismiss' ? 'Report dismissed.' : action === 'warn' ? 'Marked as warned.' : 'Member suspended and signed out everywhere.')
    await reload()
  }

  async function viewContent(reason: string) {
    setPreview(await api<ContentPreview>('POST', `/reports/${id}/content`, { reason }))
    setAsking(false)
  }

  return (
    <article aria-labelledby="case-title">
      <p><Link to="/">← Reports</Link></p>
      <h1 id="case-title">
        Report {c.reportId.slice(-8)} <span className="chips">
          {c.minor && <Chip kind="minor">involves a minor</Chip>}
          {c.severity === 'high' && <Chip kind="high">high severity</Chip>}
          <Chip kind={c.status === 'open' ? 'warn' : 'ok'}>{c.status}</Chip>
        </span>
      </h1>
      {notice && <p role="status" className="notice">{notice}</p>}
      <ErrorNote error={error} />

      <dl className="facts">
        <dt>Reason</dt><dd>{c.reasonCode.replace(/_/g, ' ')}</dd>
        <dt>Target</dt><dd>{c.targetType} <code>{c.targetId}</code></dd>
        <dt>Reported</dt><dd><Time value={c.createdAt} /></dd>
        {c.resolvedAt && (<><dt>Resolved</dt><dd><Time value={c.resolvedAt} /> ({c.resolutionCode})</dd></>)}
      </dl>

      <div className="two">
        <MemberCard title="Reported member" m={c.subject} />
        <MemberCard title="Reporter" m={c.reporter} />
      </div>

      <section aria-labelledby="shared-title">
        <h2 id="shared-title">What the reporter shared</h2>
        {c.description ? <blockquote>{c.description}</blockquote> : <p className="muted">No description.</p>}
        {c.evidence.length === 0 ? (
          <p className="muted">No messages were shared. Nothing else from the chat is available to staff.</p>
        ) : (
          <ul className="evidence">
            {c.evidence.map((e) => (
              <li key={e.messageId}>
                <span className="muted">{e.fromReporter ? 'Reporter' : 'Reported member'} · <Time value={e.sentAt} /></span>
                <p>{e.text || <em>(no text)</em>}</p>
                {e.imageBlobIds.length > 0 && <span className="muted">{e.imageBlobIds.length} image(s) attached</span>}
              </li>
            ))}
          </ul>
        )}
        {c.heldImages.length > 0 && (
          <>
            <h3>Held images</h3>
            <p className="hint">Encrypted and not viewable here. Listed by id, size and SHA-256 only.</p>
            <table>
              <thead><tr><th scope="col">Blob</th><th scope="col">Kind</th><th scope="col">Size</th><th scope="col">SHA-256</th><th scope="col">State</th></tr></thead>
              <tbody>
                {c.heldImages.map((b) => (
                  <tr key={b.blobId}><td><code>{b.blobId}</code></td><td>{b.role}</td><td>{formatBytes(b.sizeBytes)}</td><td><code>{b.sha256}</code></td><td>{b.state}</td></tr>
                ))}
              </tbody>
            </table>
          </>
        )}
      </section>

      <section aria-labelledby="content-title">
        <h2 id="content-title">Reported content</h2>
        {!hasPreview(c.targetType) ? (
          <p className="muted">This report is about a private chat. Chats are end-to-end encrypted, so staff only see what the reporter shared above.</p>
        ) : !canModerate(operator.role) ? (
          <p className="hint">Your role can read the case but not the reported content.</p>
        ) : !preview ? (
          <>
            <p className="hint">Shows the {c.targetType === 'user' ? 'profile photo' : `reported ${c.targetType.replace('_', ' ')}`} as members saw it. You will be asked for a reason, and the view is audited.</p>
            <button type="button" className="secondary" onClick={() => setAsking(true)}>View reported content…</button>
          </>
        ) : (
          <>
            <p className="muted">By @{preview.content.authorUsername || 'unknown'}{preview.content.deleted && ' · deleted by the author'}</p>
            {preview.content.title && <h3>{preview.content.title}</h3>}
            {preview.content.text ? <p className="content-text">{preview.content.text}</p> : <p className="muted">No text.</p>}
            {preview.media.length > 0 && (
              preview.mediaAvailable ? (
                <div className="photos">
                  {preview.media.map((m) => <img key={m.mediaId} src={m.url} alt="Reported photo" width={m.width || undefined} height={m.height || undefined} />)}
                </div>
              ) : <p className="hint">{preview.media.length} photo(s) not shown: the console has no access to photo storage.</p>
            )}
          </>
        )}
      </section>

      <section aria-labelledby="history-title">
        <h2 id="history-title">History of the reported member</h2>
        <h3>Other reports</h3>
        {c.priorReports.length === 0 ? <p className="muted">None.</p> : (
          <ul>
            {c.priorReports.map((r) => (
              <li key={r.reportId}><Link to={`/reports/${r.reportId}`}>{r.reportId.slice(-8)}</Link> {r.reasonCode.replace(/_/g, ' ')} · {r.status}{r.resolutionCode ? ` (${r.resolutionCode})` : ''} · <Time value={r.createdAt} /></li>
            ))}
          </ul>
        )}
        <h3>Previous actions</h3>
        {c.actions.length === 0 ? <p className="muted">None.</p> : (
          <ul>
            {c.actions.map((a) => (
              <li key={a.actionId}><strong>{a.type}</strong> by {a.actor} · <Time value={a.createdAt} />{a.note && <> — {a.note}</>}</li>
            ))}
          </ul>
        )}
      </section>

      {mayAct && (
        <section aria-labelledby="act-title" className="actions-bar">
          <h2 id="act-title">Decide</h2>
          <div className="actions">
            <button type="button" className="secondary" onClick={() => setPending('dismiss')}>Dismiss</button>
            <button type="button" className="primary" onClick={() => setPending('warn')}>Warn</button>
            <button type="button" className="danger" onClick={() => setPending('suspend')}>Suspend member…</button>
          </div>
        </section>
      )}
      {!canModerate(operator.role) && <p className="hint">Your role can read cases but not act on them.</p>}

      {asking && (
        <ReasonDialog title="View reported content" confirmLabel="Show content"
          intro={<p>You are about to read content a member published. Your name and this reason are recorded in the audit log.</p>}
          onSubmit={(reason) => viewContent(reason)} onClose={() => setAsking(false)} />
      )}
      {pending && (
        <ReasonDialog
          title={pending === 'dismiss' ? 'Dismiss this report' : pending === 'warn' ? 'Warn the member' : 'Suspend the member'}
          intro={pending === 'suspend' ? <p>Suspending signs <strong>@{c.subject.username}</strong> out of every device immediately. You can restore the account later.</p> : undefined}
          confirmLabel={pending === 'dismiss' ? 'Dismiss report' : pending === 'warn' ? 'Record warning' : 'Suspend member'}
          confirmText={pending === 'suspend' ? `I confirm I am suspending @${c.subject.username}` : undefined}
          danger={pending === 'suspend'}
          onSubmit={(reason) => resolve(pending, reason)}
          onClose={() => setPending(null)}
        />
      )}
    </article>
  )
}

function MemberCard({ title, m }: { title: string; m: Member }) {
  return (
    <section className="card" aria-label={title}>
      <h2>{title}</h2>
      <p><Link to={`/users/${m.userId}`}>{m.displayName || '(no name)'} @{m.username}</Link></p>
      <p>
        <Chip kind={m.ageBand === 'minor' ? 'minor' : 'neutral'}>{m.ageBand}</Chip>{' '}
        <Chip kind={m.status === 'active' ? 'ok' : 'warn'}>{m.status}</Chip>
      </p>
      <p className="muted">
        Reported {m.reportsAgainst} time(s), {m.openReportsAgainst} open. Filed {m.reportsFiled}, {m.reportsFiledDismissed} dismissed.
      </p>
    </section>
  )
}
