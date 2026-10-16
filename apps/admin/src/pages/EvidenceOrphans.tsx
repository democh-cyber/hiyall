import { api, type EvidenceOrphans as Orphans } from '../api'
import { ErrorNote, Time, useLoad } from '../ui'

/**
 * Held evidence objects that no case names, older than an hour (the evidence sweep lists them; it never deletes them).
 * Each one is an upload whose case could not be written, or one that was dropped: review it, and have whoever holds the
 * evidence bucket's delete credential remove it, or keep it. The list is read-audited.
 */
export function EvidenceOrphans() {
  const { data, error, loading } = useLoad(() => api<Orphans>('GET', '/evidence/orphans'), 'orphans')
  if (loading && !data) return <p role="status">Loading…</p>
  const items = data?.items ?? []
  return (
    <section aria-labelledby="orphans-title">
      <h1 id="orphans-title">Evidence objects without a case</h1>
      <p className="hint">{data?.checkedAt ? <>Checked <Time value={data.checkedAt} />.</> : 'Not checked yet: the sweep runs hourly.'}{data && !data.complete && ' The list may be incomplete.'}</p>
      <ErrorNote error={error} />
      {items.length === 0 && !error && <p>No orphaned evidence objects.</p>}
      {items.length > 0 && (
        <div className="table-wrap">
          <table>
            <caption className="sr-only">Evidence objects with no case</caption>
            <thead><tr><th scope="col">Object</th><th scope="col">Upload</th><th scope="col">Stored</th></tr></thead>
            <tbody>
              {items.map((o) => (
                <tr key={o.key}><td><code>{o.key}</code></td><td><code>{o.mediaId || 'unknown'}</code></td><td><Time value={o.lastModified} /></td></tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  )
}
