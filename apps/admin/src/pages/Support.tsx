import { useState } from 'react'
import { Link, useSearchParams } from 'react-router'
import { api, query, type Page, type SupportThreadRecord } from '../api'
import { Chip, ErrorNote, messageOf, Time, useLoad } from '../ui'

const STATUSES = ['open', 'closed', 'all'] as const
const CATEGORIES = ['account', 'safety', 'bug', 'other'] as const

/** The age band, prominent: replies to a member under 18 have stricter rules. */
export function AgeBand({ band }: { band: 'minor' | 'adult' }) {
  return band === 'minor' ? <Chip kind="minor">minor (under 18)</Chip> : <Chip kind="neutral">adult</Chip>
}

/** The support inbox. It lists who wrote and where the thread stands; no message text (opening a thread is an audited read). */
export function Support() {
  const [params, setParams] = useSearchParams()
  const status = params.get('status') ?? 'open'
  const category = params.get('category') ?? ''
  const waiting = params.get('waiting') === 'true'
  const assigned = params.get('assigned') ?? ''
  const sort = params.get('sort') ?? 'oldest'
  const filters = { status, category, waiting, assigned, sort }
  const first = useLoad(() => api<Page<SupportThreadRecord>>('GET', '/support/threads' + query(filters)), JSON.stringify(filters))
  const [tail, setTail] = useState<{ base: unknown; items: SupportThreadRecord[]; cursor: string | null } | null>(null)
  const [moreError, setMoreError] = useState<string | null>(null)
  const current = tail && tail.base === first.data ? tail : null
  const more = current?.items ?? []
  const cursor = current ? current.cursor : (first.data?.nextCursor ?? null)

  function setFilter(next: Partial<Record<'status' | 'category' | 'waiting' | 'assigned' | 'sort', string>>) {
    const merged: Record<string, string> = { status, category, waiting: waiting ? 'true' : '', assigned, sort, ...next }
    const out: Record<string, string> = {}
    // Defaults stay out of the address.
    if (merged.status !== 'open') out.status = merged.status
    if (merged.category) out.category = merged.category
    if (merged.waiting === 'true') out.waiting = 'true'
    if (merged.assigned) out.assigned = merged.assigned
    if (merged.sort !== 'oldest') out.sort = merged.sort
    setParams(out, { replace: true })
  }

  async function loadMore() {
    if (!cursor) return
    setMoreError(null)
    try {
      const page = await api<Page<SupportThreadRecord>>('GET', '/support/threads' + query({ ...filters, cursor }))
      setTail({ base: first.data, items: [...more, ...page.items], cursor: page.nextCursor })
    } catch (e) {
      setMoreError(messageOf(e))
    }
  }

  const items = [...(first.data?.items ?? []), ...more]
  return (
    <section aria-labelledby="support-title">
      <h1 id="support-title">Support inbox</h1>
      <p className="hint">Conversations members started from the app. The list shows no message text: opening a conversation is recorded in the audit log.</p>
      <form className="filters" onSubmit={(e) => e.preventDefault()} aria-label="Filters">
        <label>
          Status
          <select value={status} onChange={(e) => setFilter({ status: e.target.value })}>
            {STATUSES.map((s) => <option key={s} value={s}>{s}</option>)}
          </select>
        </label>
        <label>
          Category
          <select value={category} onChange={(e) => setFilter({ category: e.target.value })}>
            <option value="">any</option>
            {CATEGORIES.map((c) => <option key={c} value={c}>{c}</option>)}
          </select>
        </label>
        <label>
          Assigned
          <select value={assigned} onChange={(e) => setFilter({ assigned: e.target.value })}>
            <option value="">any</option>
            <option value="me">to me</option>
            <option value="none">to nobody</option>
          </select>
        </label>
        <label>
          Order
          <select value={sort} onChange={(e) => setFilter({ sort: e.target.value })}>
            <option value="oldest">oldest waiting first</option>
            <option value="newest">newest first</option>
          </select>
        </label>
        <label className="check">
          <input type="checkbox" checked={waiting} onChange={(e) => setFilter({ waiting: e.target.checked ? 'true' : '' })} />
          Waiting for us
        </label>
      </form>
      <ErrorNote error={first.error ?? moreError} />
      {first.loading ? <p role="status">Loading…</p> : items.length === 0 ? <p className="muted">No conversations.</p> : (
        <div className="table-wrap">
          <table>
            <caption className="sr-only">Support conversations</caption>
            <thead>
              <tr>
                <th scope="col">Conversation</th><th scope="col">Category</th><th scope="col">Member</th><th scope="col">Last message from</th>
                <th scope="col">Last activity</th><th scope="col">Assigned to</th><th scope="col">Messages</th>
              </tr>
            </thead>
            <tbody>
              {items.map((t) => (
                <tr key={t.threadId}>
                  <td>
                    <Link data-row to={`/support/${t.threadId}`}>{t.threadId.slice(-8)}</Link>{' '}
                    {t.status === 'closed' && <Chip kind="neutral">closed</Chip>}
                  </td>
                  <td>{t.category}</td>
                  <td>
                    @{t.member.username || 'unknown'} <span className="muted">{t.member.displayName}</span>{' '}
                    <AgeBand band={t.member.ageBand} />
                    {t.member.status !== 'active' && <Chip kind="warn">{t.member.status}</Chip>}
                  </td>
                  <td>
                    {t.lastAuthor}
                    {t.status === 'open' && t.lastAuthor === 'member' && <> <Chip kind="warn">waiting for us</Chip></>}
                  </td>
                  <td><Time value={t.lastMessageAt} /></td>
                  <td>{t.assignedTo ? <>{t.assignedTo}{t.assignedToMe && <> <Chip kind="neutral">you</Chip></>}</> : <span className="muted">nobody</span>}</td>
                  <td>{t.messageCount}</td>
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
