import { useEffect, useState } from 'react'
import { Link, useSearchParams } from 'react-router'
import { api, query, type Page, type ReportRow } from '../api'
import { Chip, ErrorNote, messageOf, Time, useLoad } from '../ui'

const STATUSES = ['open', 'actioned', 'dismissed', 'all'] as const

export function Queue() {
  const [params, setParams] = useSearchParams()
  const status = params.get('status') ?? 'open'
  const severity = params.get('severity') ?? ''
  const minor = params.get('minor') === 'true'
  const key = `${status}|${severity}|${minor}`
  const first = useLoad(() => api<Page<ReportRow>>('GET', '/reports' + query({ status, severity, minor })), key)
  // Pages after the first. A tail belongs to the first page it followed; a new first page (other filter) drops it.
  const [tail, setTail] = useState<{ base: unknown; items: ReportRow[]; cursor: string | null } | null>(null)
  const [moreError, setMoreError] = useState<string | null>(null)
  const current = tail && tail.base === first.data ? tail : null
  const more = current?.items ?? []
  const cursor = current ? current.cursor : (first.data?.nextCursor ?? null)

  async function loadMore() {
    if (!cursor) return
    setMoreError(null)
    try {
      const page = await api<Page<ReportRow>>('GET', '/reports' + query({ status, severity, minor, cursor }))
      setTail({ base: first.data, items: [...more, ...page.items], cursor: page.nextCursor })
    } catch (e) {
      setMoreError(messageOf(e))
    }
  }

  function set(name: string, value: string) {
    const next = new URLSearchParams(params)
    if (value) next.set(name, value)
    else next.delete(name)
    setParams(next, { replace: true })
  }

  // j and k move between rows, Enter opens one.
  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      const t = e.target as HTMLElement
      if (t.closest('input, select, textarea') || e.metaKey || e.ctrlKey || e.altKey) return
      if (e.key !== 'j' && e.key !== 'k') return
      const rows = Array.from(document.querySelectorAll<HTMLAnchorElement>('a[data-row]'))
      const at = rows.indexOf(document.activeElement as HTMLAnchorElement)
      const to = e.key === 'j' ? Math.min(rows.length - 1, at + 1) : Math.max(0, at - 1)
      rows[to]?.focus()
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [])

  const items = [...(first.data?.items ?? []), ...more]
  return (
    <section aria-labelledby="queue-title">
      <h1 id="queue-title">Reports</h1>
      <form className="filters" onSubmit={(e) => e.preventDefault()} aria-label="Filters">
        <label>
          Status
          <select value={status} onChange={(e) => set('status', e.target.value === 'open' ? '' : e.target.value)}>
            {STATUSES.map((s) => <option key={s} value={s}>{s}</option>)}
          </select>
        </label>
        <label>
          Severity
          <select value={severity} onChange={(e) => set('severity', e.target.value)}>
            <option value="">any</option>
            <option value="high">high</option>
            <option value="normal">normal</option>
          </select>
        </label>
        <label className="check">
          <input type="checkbox" checked={minor} onChange={(e) => set('minor', e.target.checked ? 'true' : '')} />
          Involves a minor
        </label>
      </form>
      <ErrorNote error={first.error ?? moreError} />
      {first.loading ? <p role="status">Loading…</p> : items.length === 0 ? <p className="muted">No reports match.</p> : (
        <div className="table-wrap">
          <table>
            <caption className="sr-only">Reports, minors first, then high severity, then oldest</caption>
            <thead>
              <tr><th scope="col">Report</th><th scope="col">Reason</th><th scope="col">Flags</th><th scope="col">About</th><th scope="col">Prior</th><th scope="col">Status</th><th scope="col">Reported</th></tr>
            </thead>
            <tbody>
              {items.map((r) => (
                <tr key={r.reportId}>
                  <td><Link data-row to={`/reports/${r.reportId}`}>{r.reportId.slice(-8)}</Link></td>
                  <td>{r.reasonCode.replace(/_/g, ' ')} <span className="muted">({r.targetType})</span></td>
                  <td className="chips">
                    {r.minor && <Chip kind="minor">minor</Chip>}
                    {r.severity === 'high' && <Chip kind="high">high</Chip>}
                    {r.evidenceCount > 0 && <Chip kind="neutral">{r.evidenceCount} shared</Chip>}
                    {r.heldImageCount > 0 && <Chip kind="neutral">{r.heldImageCount} image{r.heldImageCount === 1 ? '' : 's'}</Chip>}
                  </td>
                  <td>@{r.subjectUsername || 'unknown'}</td>
                  <td>{r.priorReportCount}</td>
                  <td>{r.status}</td>
                  <td><Time value={r.createdAt} /></td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {cursor && <button type="button" className="secondary" onClick={loadMore}>Load more</button>}
      <p className="hint">Keyboard: j and k move between rows, Enter opens a case.</p>
    </section>
  )
}
