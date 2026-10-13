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

  if (loading && !data) return <p role="status">Loading…</p>
  return (
    <section aria-labelledby="ops-title">
      <h1 id="ops-title">Operators</h1>
      <p className="hint">Accounts are created on the server with <code>admin operator-add</code>. Each change here needs a reason and is audited.</p>
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
          intro={change.kind === 'disable' ? <p>Their sessions end immediately.</p> : undefined}
          confirmLabel={change.kind === 'role' ? 'Change role' : change.kind === 'disable' ? 'Disable operator' : 'Enable operator'}
          danger={change.kind === 'disable'}
          onSubmit={async (reason) => {
            const base = `/operators/${change.op.operatorId}`
            if (change.kind === 'role') await api('POST', `${base}/role`, { role: change.role, reason })
            else await api('POST', `${base}/${change.kind}`, { reason })
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
