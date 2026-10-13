import { useState } from 'react'
import { api, query, type AuditRecord, type Page } from '../api'
import { ErrorNote, messageOf, Time, useLoad } from '../ui'

export function Audit() {
  const [action, setAction] = useState('')
  const [target, setTarget] = useState('')
  const [applied, setApplied] = useState({ action: '', target: '' })
  const first = useLoad(() => api<Page<AuditRecord>>('GET', '/audit' + query({ action: applied.action, target: applied.target })), JSON.stringify(applied))
  const [tail, setTail] = useState<{ base: unknown; items: AuditRecord[]; cursor: string | null } | null>(null)
  const [moreError, setMoreError] = useState<string | null>(null)
  const current = tail && tail.base === first.data ? tail : null
  const more = current?.items ?? []
  const cursor = current ? current.cursor : (first.data?.nextCursor ?? null)

  async function loadMore() {
    if (!cursor) return
    try {
      const page = await api<Page<AuditRecord>>('GET', '/audit' + query({ action: applied.action, target: applied.target, cursor }))
      setTail({ base: first.data, items: [...more, ...page.items], cursor: page.nextCursor })
    } catch (e) {
      setMoreError(messageOf(e))
    }
  }

  const items = [...(first.data?.items ?? []), ...more]
  return (
    <section aria-labelledby="audit-title">
      <h1 id="audit-title">Audit log</h1>
      <p className="hint">Append-only. Reading this page is itself recorded.</p>
      <form className="filters" onSubmit={(e) => { e.preventDefault(); setApplied({ action: action.trim(), target: target.trim() }) }} aria-label="Filters">
        <label>Action <input value={action} onChange={(e) => setAction(e.target.value)} placeholder="case_view" /></label>
        <label>Target id <input value={target} onChange={(e) => setTarget(e.target.value)} /></label>
        <button type="submit" className="secondary">Filter</button>
      </form>
      <ErrorNote error={first.error ?? moreError} />
      {first.loading ? <p role="status">Loading…</p> : (
        <div className="table-wrap">
          <table>
            <thead><tr><th scope="col">When</th><th scope="col">Who</th><th scope="col">Action</th><th scope="col">Target</th><th scope="col">Reason</th><th scope="col">From</th></tr></thead>
            <tbody>
              {items.map((r) => (
                <tr key={r.auditId}>
                  <td><Time value={r.at} /></td><td>{r.actor}</td><td>{r.action}</td>
                  <td>{r.targetType} <code>{r.targetId}</code></td><td>{r.reason}</td><td>{r.ip}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {cursor && <button type="button" className="secondary" onClick={loadMore}>Load more</button>}
    </section>
  )
}
