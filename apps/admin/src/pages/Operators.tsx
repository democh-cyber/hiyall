import { useState } from 'react'
import { api, type Operator, type Role } from '../api'
import { useOperator } from '../auth'
import { Chip, ErrorNote, ReasonDialog, Time, useLoad } from '../ui'

type Change = { op: Operator; kind: 'disable' | 'enable' | 'role'; role?: Role } | null

export function Operators() {
  const me = useOperator()
  const { data, error, loading, reload } = useLoad(() => api<{ items: Operator[] }>('GET', '/operators'), 'operators')
  const [change, setChange] = useState<Change>(null)
  const [roleFor, setRoleFor] = useState<Record<string, Role>>({})
  const [notice, setNotice] = useState<string | null>(null)

  if (loading && !data) return <p role="status">Loading…</p>
  return (
    <section aria-labelledby="ops-title">
      <h1 id="ops-title">Operators</h1>
      <p className="hint">Accounts are created on the server with <code>admin operator-add</code> (a viewer or a moderator; only the very first administrator is created directly). Each change here needs a reason and is audited. Making someone an administrator is a proposal that a different administrator approves under Approvals. The last active administrator cannot be disabled here.</p>
      {notice && <p role="status" className="notice">{notice}</p>}
      <ErrorNote error={error} />
      <div className="table-wrap">
        <table>
          <thead><tr><th scope="col">Operator</th><th scope="col">Role</th><th scope="col">Status</th><th scope="col">Last sign-in</th><th scope="col">Actions</th></tr></thead>
          <tbody>
            {(data?.items ?? []).map((o) => {
              const self = o.operatorId === me.operatorId
              const chosen = roleFor[o.operatorId] ?? o.role
              return (
                <tr key={o.operatorId}>
                  <td>{o.displayName} <span className="muted">{o.email}</span>{self && <> <Chip kind="neutral">you</Chip></>}</td>
                  <td>
                    <label className="sr-only" htmlFor={`role-${o.operatorId}`}>Role of {o.email}</label>
                    <select id={`role-${o.operatorId}`} value={chosen} onChange={(e) => setRoleFor({ ...roleFor, [o.operatorId]: e.target.value as Role })}>
                      <option value="viewer">viewer</option><option value="moderator">moderator</option><option value="admin">admin</option>
                    </select>{' '}
                    {chosen !== o.role && <button type="button" className="secondary" onClick={() => setChange({ op: o, kind: 'role', role: chosen })}>Change role</button>}
                  </td>
                  <td>{o.disabledAt ? <Chip kind="warn">disabled</Chip> : <Chip kind="ok">active</Chip>}</td>
                  <td><Time value={o.lastLoginAt} /></td>
                  <td>
                    {o.disabledAt
                      ? <button type="button" className="secondary" onClick={() => setChange({ op: o, kind: 'enable' })}>Enable</button>
                      : <button type="button" className="danger" disabled={self} title={self ? 'You cannot disable yourself' : undefined} onClick={() => setChange({ op: o, kind: 'disable' })}>Disable</button>}
                  </td>
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>
      {change && (
        <ReasonDialog
          title={change.kind === 'role' ? `Change role of ${change.op.email} to ${change.role}` : `${change.kind === 'disable' ? 'Disable' : 'Enable'} ${change.op.email}`}
          intro={change.kind === 'disable' ? <p>Their sessions end immediately.</p> : change.kind === 'role' && change.role === 'admin' ? <p>This only proposes the promotion. A different administrator has to approve it within 24 hours, and both of you are recorded.</p> : undefined}
          confirmLabel={change.kind === 'role' ? (change.role === 'admin' ? 'Propose promotion' : 'Change role') : change.kind === 'disable' ? 'Disable operator' : 'Enable operator'}
          danger={change.kind === 'disable'}
          onSubmit={async (reason) => {
            const base = `/operators/${change.op.operatorId}`
            setNotice(null)
            if (change.kind === 'role') {
              const out = await api<{ pending?: boolean }>('POST', `${base}/role`, { role: change.role, reason })
              if (out?.pending) setNotice(`Proposal recorded: ${change.op.email} becomes an administrator when a different administrator approves it under Approvals (within 24 hours).`)
            } else {
              const out = await api<{ warning?: string }>('POST', `${base}/${change.kind}`, { reason })
              // Below two active administrators nothing needing a second one can be completed: say so.
              if (out?.warning) setNotice(out.warning)
            }
            setChange(null)
            setRoleFor({})
            await reload()
          }}
          onClose={() => setChange(null)}
        />
      )}
    </section>
  )
}
