import { useState } from 'react'
import { Link, useParams } from 'react-router'
import { api, canModerate, type UserView } from '../api'
import { useOperator } from '../auth'
import { Chip, ErrorNote, ReasonDialog, Time, useLoad } from '../ui'

interface Reply {
  user: UserView
  identities?: { issuer: string; subject: string }[]
}

export function User() {
  const { id = '' } = useParams()
  const operator = useOperator()
  const [withIdentity, setWithIdentity] = useState(false)
  const { data, error, loading, reload } = useLoad(() => api<Reply>('GET', `/users/${id}${withIdentity ? '?identity=true' : ''}`), `${id}|${withIdentity}`)
  const [restoring, setRestoring] = useState(false)

  if (loading && !data) return <p role="status">Loading…</p>
  if (!data) return <ErrorNote error={error ?? 'Not found'} />
  const u = data.user

  return (
    <article aria-labelledby="user-title">
      <p><Link to="/">← Reports</Link></p>
      <h1 id="user-title">{u.displayName || '(no name)'} <span className="muted">@{u.username}</span></h1>
      <p>
        <Chip kind={u.ageBand === 'minor' ? 'minor' : 'neutral'}>{u.ageBand}</Chip>{' '}
        <Chip kind={u.status === 'active' ? 'ok' : 'warn'}>{u.status}</Chip>
      </p>
      <ErrorNote error={error} />
      <dl className="facts">
        <dt>Member since</dt><dd><Time value={u.createdAt} /></dd>
        <dt>Live sessions</dt><dd>{u.activeSessions}</dd>
        <dt>Reports against</dt><dd>{u.reportsAgainst} ({u.openReportsAgainst} open)</dd>
        <dt>Reports filed</dt><dd>{u.reportsFiled} ({u.reportsFiledDismissed} dismissed)</dd>
      </dl>
      <p className="hint">Messages, location, visitors and contact details are not available to staff.</p>

      {canModerate(operator.role) && u.status === 'suspended' && (
        <button type="button" className="primary" onClick={() => setRestoring(true)}>Restore account…</button>
      )}
      {operator.role === 'admin' && !withIdentity && (
        <button type="button" className="secondary" onClick={() => setWithIdentity(true)}>Show sign-in identity (recorded)</button>
      )}
      {data.identities && (
        <section aria-label="Sign-in identity">
          <h2>Sign-in identity</h2>
          {data.identities.length === 0 ? <p className="muted">None.</p> : (
            <ul>{data.identities.map((i) => <li key={i.issuer + i.subject}><code>{i.issuer}</code> · <code>{i.subject}</code></li>)}</ul>
          )}
        </section>
      )}

      <h2>Reports about this member</h2>
      <ul>
        {u.reports.map((r) => (
          <li key={r.reportId}><Link to={`/reports/${r.reportId}`}>{r.reportId.slice(-8)}</Link> {r.reasonCode.replace(/_/g, ' ')} · {r.status}{r.resolutionCode ? ` (${r.resolutionCode})` : ''} · <Time value={r.createdAt} /></li>
        ))}
        {u.reports.length === 0 && <li className="muted">None.</li>}
      </ul>
      <h2>Actions</h2>
      <ul>
        {u.actions.map((a) => (
          <li key={a.actionId}><strong>{a.type}</strong> by {a.actor} · <Time value={a.createdAt} />{a.note && <> — {a.note}</>}</li>
        ))}
        {u.actions.length === 0 && <li className="muted">None.</li>}
      </ul>

      {restoring && (
        <ReasonDialog
          title="Restore this account"
          confirmLabel="Restore account"
          onSubmit={async (reason) => {
            await api('POST', `/users/${id}/restore`, { reason })
            setRestoring(false)
            await reload()
          }}
          onClose={() => setRestoring(false)}
        />
      )}
    </article>
  )
}
