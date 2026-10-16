import { useState } from 'react'
import { Link, useSearchParams } from 'react-router'
import { api, query, type ContentCase, type Page } from '../api'
import { Chip, ErrorNote, messageOf, Time, useLoad } from '../ui'

const STATUSES = ['open', 'pending', 'confirmed', 'reported', 'cleared', 'all'] as const

/** Uploads the scanner stopped. The list shows no imagery: only who, what the scanner said and where the case stands. */
export function ContentCases() {
  const [params, setParams] = useSearchParams()
  const status = params.get('status') ?? 'open'
  const filter = status === 'all' ? '' : status
  const first = useLoad(() => api<Page<ContentCase>>('GET', '/content-cases' + query({ status: filter })), status)
  const [tail, setTail] = useState<{ base: unknown; items: ContentCase[]; cursor: string | null } | null>(null)
  const [moreError, setMoreError] = useState<string | null>(null)
  const current = tail && tail.base === first.data ? tail : null
  const more = current?.items ?? []
  const cursor = current ? current.cursor : (first.data?.nextCursor ?? null)

  async function loadMore() {
    if (!cursor) return
    setMoreError(null)
    try {
      const page = await api<Page<ContentCase>>('GET', '/content-cases' + query({ status: filter, cursor }))
      setTail({ base: first.data, items: [...more, ...page.items], cursor: page.nextCursor })
    } catch (e) {
      setMoreError(messageOf(e))
    }
  }

  const items = [...(first.data?.items ?? []), ...more]
  return (
    <section aria-labelledby="cases-title">
      <h1 id="cases-title">Quarantined uploads</h1>
      <p className="hint">Photos the upload scanner matched or flagged. They are never shown to members. Only administrators can look at the image.</p>
      <form className="filters" onSubmit={(e) => e.preventDefault()} aria-label="Filters">
        <label>
          Status
          <select value={status} onChange={(e) => setParams(e.target.value === 'open' ? {} : { status: e.target.value }, { replace: true })}>
            {STATUSES.map((s) => <option key={s} value={s}>{s}</option>)}
          </select>
        </label>
      </form>
      <ErrorNote error={first.error ?? moreError} />
      {first.loading ? <p role="status">Loading…</p> : items.length === 0 ? <p className="muted">No cases.</p> : (
        <div className="table-wrap">
          <table>
            <caption className="sr-only">Quarantined uploads, newest first</caption>
            <thead>
              <tr><th scope="col">Case</th><th scope="col">Result</th><th scope="col">Uploader</th><th scope="col">Purpose</th><th scope="col">Status</th><th scope="col">Detected</th></tr>
            </thead>
            <tbody>
              {items.map((c) => (
                <tr key={c.caseId}>
                  <td><Link data-row to={`/content/${c.caseId}`}>{c.caseId.slice(-8)}</Link></td>
                  <td><Chip kind={c.result === 'match' ? 'high' : 'warn'}>{c.result}</Chip></td>
                  <td>@{c.username || 'unknown'} {c.ageBand === 'minor' && <Chip kind="minor">minor</Chip>}</td>
                  <td>{c.purpose}</td>
                  <td>{c.status}</td>
                  <td><Time value={c.createdAt} /></td>
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
