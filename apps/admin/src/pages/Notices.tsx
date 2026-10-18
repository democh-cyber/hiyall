import { useId, useState, type FormEvent } from 'react'
import { api, query, type NoticeAudience, type NoticeCategory, type NoticeInput, type NoticeRecord, type NoticeStatus, type Page } from '../api'
import { useOperator } from '../auth'
import { MAX_NOTICE_BODY, MAX_NOTICE_TITLE, NoticeBody, noticeBodyProblems } from '../noticeMarkup'
import { Chip, ErrorNote, MIN_REASON, messageOf, ReasonDialog, Time, useLoad } from '../ui'

const STATUSES = ['all', 'live', 'scheduled', 'ended', 'unpublished'] as const
const CATEGORIES: NoticeCategory[] = ['safety', 'news', 'update']
const AUDIENCES: NoticeAudience[] = ['all', 'minors', 'adults']

const statusKind: Record<NoticeStatus, 'ok' | 'warn' | 'neutral'> = { live: 'ok', scheduled: 'warn', ended: 'neutral', unpublished: 'neutral' }

/** The notice board: what members read in the app's Notices tab. Everyone signed in can read the list; administrators write. */
export function Notices() {
  const me = useOperator()
  const isAdmin = me.role === 'admin'
  const [status, setStatus] = useState<(typeof STATUSES)[number]>('all')
  const filter = status === 'all' ? '' : status
  const first = useLoad(() => api<Page<NoticeRecord>>('GET', '/notices' + query({ status: filter })), status)
  const [tail, setTail] = useState<{ base: unknown; items: NoticeRecord[]; cursor: string | null } | null>(null)
  const [moreError, setMoreError] = useState<string | null>(null)
  const [editing, setEditing] = useState<NoticeRecord | 'new' | null>(null)
  const [unpublishing, setUnpublishing] = useState<NoticeRecord | null>(null)
  const [done, setDone] = useState<string | null>(null)
  const current = tail && tail.base === first.data ? tail : null
  const more = current?.items ?? []
  const cursor = current ? current.cursor : (first.data?.nextCursor ?? null)

  async function loadMore() {
    if (!cursor) return
    setMoreError(null)
    try {
      const page = await api<Page<NoticeRecord>>('GET', '/notices' + query({ status: filter, cursor }))
      setTail({ base: first.data, items: [...more, ...page.items], cursor: page.nextCursor })
    } catch (e) {
      setMoreError(messageOf(e))
    }
  }

  const items = [...(first.data?.items ?? []), ...more]
  return (
    <section aria-labelledby="notices-title">
      <h1 id="notices-title">Notices</h1>
      <p className="hint">
        Short posts from the Hiyall team that members read in the app: safety advice, news, app updates.
        {isAdmin ? ' Every change needs a reason and is recorded in the audit log.' : ' Your role is read-only: administrators publish, edit and unpublish.'}
      </p>
      {done && <p role="status" className="notice">{done}</p>}
      <form className="filters" onSubmit={(e) => e.preventDefault()} aria-label="Filters">
        <label>
          Status
          <select value={status} onChange={(e) => setStatus(e.target.value as (typeof STATUSES)[number])}>
            {STATUSES.map((s) => <option key={s} value={s}>{s}</option>)}
          </select>
        </label>
        {isAdmin && editing === null && <button type="button" className="primary" onClick={() => { setDone(null); setEditing('new') }}>New notice</button>}
      </form>
      {isAdmin && editing !== null && (
        <NoticeForm
          notice={editing === 'new' ? null : editing}
          onCancel={() => setEditing(null)}
          onSaved={async (n, created) => {
            setEditing(null)
            setDone(created ? `Published “${n.title}” (${n.status}).` : `Saved “${n.title}”.`)
            await first.reload()
          }}
        />
      )}
      <ErrorNote error={first.error ?? moreError} />
      {first.loading ? <p role="status">Loading…</p> : items.length === 0 ? <p className="muted">No notices.</p> : (
        <div className="table-wrap">
          <table>
            <caption className="sr-only">Notices, newest first</caption>
            <thead>
              <tr>
                <th scope="col">Title</th><th scope="col">Category</th><th scope="col">Audience</th><th scope="col">Language</th><th scope="col">Pinned</th>
                <th scope="col">Status</th><th scope="col">Published</th><th scope="col">Expires</th>
                {isAdmin && <th scope="col">Actions</th>}
              </tr>
            </thead>
            <tbody>
              {items.map((n) => (
                <tr key={n.noticeId}>
                  <td>
                    {n.title}
                    <details>
                      <summary>Text</summary>
                      <NoticeBody body={n.body} />
                      <p className="hint">Written by {n.createdBy}, updated <Time value={n.updatedAt} /></p>
                    </details>
                  </td>
                  <td>{n.category}</td>
                  <td>{n.audience}</td>
                  <td>{n.locale === '' ? 'every language' : n.locale}</td>
                  <td>{n.pinned ? 'yes' : 'no'}</td>
                  <td><Chip kind={statusKind[n.status]}>{n.status}</Chip></td>
                  <td><Time value={n.publishedAt} /></td>
                  <td>{n.expiresAt ? <Time value={n.expiresAt} /> : <span className="muted">no end</span>}</td>
                  {isAdmin && (
                    <td>
                      {n.status !== 'unpublished' && (
                        <>
                          <button type="button" className="secondary" aria-label={`Edit ${n.title}`} onClick={() => { setDone(null); setEditing(n) }}>Edit</button>{' '}
                          <button type="button" className="danger" aria-label={`Unpublish ${n.title}`} onClick={() => { setDone(null); setUnpublishing(n) }}>Unpublish</button>
                        </>
                      )}
                    </td>
                  )}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {cursor && <button type="button" className="secondary" onClick={loadMore}>Load more</button>}
      {unpublishing && (
        <ReasonDialog
          title={`Unpublish “${unpublishing.title}”`}
          intro={<p>Members stop seeing this notice. It cannot be published again; write a new one if needed.</p>}
          confirmLabel="Unpublish notice"
          danger
          onSubmit={async (reason) => {
            await api('POST', `/notices/${unpublishing.noticeId}/unpublish`, { reason })
            setDone(`Unpublished “${unpublishing.title}”.`)
            setUnpublishing(null)
            await first.reload()
          }}
          onClose={() => setUnpublishing(null)}
        />
      )}
    </section>
  )
}

/** An ISO time as the value of a datetime-local input (the operator's own time zone). */
function toLocalInput(iso: string | null): string {
  if (!iso) return ''
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return ''
  const p = (n: number) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`
}

function toIso(local: string): string | undefined {
  if (local === '') return undefined
  const d = new Date(local)
  return Number.isNaN(d.getTime()) ? undefined : d.toISOString()
}

interface NoticeFormProps {
  /** The notice being edited, or null for a new one. */
  notice: NoticeRecord | null
  onCancel: () => void
  onSaved: (n: NoticeRecord, created: boolean) => Promise<void>
}

/** Create or edit. The helper texts mirror the server's rules; the server decides and its message is shown beside the form. */
function NoticeForm({ notice, onCancel, onSaved }: NoticeFormProps) {
  const id = useId()
  const [category, setCategory] = useState<NoticeCategory>(notice?.category ?? 'news')
  const [title, setTitle] = useState(notice?.title ?? '')
  const [body, setBody] = useState(notice?.body ?? '')
  const [audience, setAudience] = useState<NoticeAudience>(notice?.audience ?? 'all')
  const [locale, setLocale] = useState(notice?.locale ?? '')
  const [pinned, setPinned] = useState(notice?.pinned ?? false)
  const initialPublished = toLocalInput(notice?.publishedAt ?? null)
  const [publishedAt, setPublishedAt] = useState(initialPublished)
  const [expiresAt, setExpiresAt] = useState(toLocalInput(notice?.expiresAt ?? null))
  const [reason, setReason] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const problems = noticeBodyProblems(body)
  const reasonOk = reason.trim().length >= MIN_REASON && reason.trim().length <= 1000
  const ready = title.trim() !== '' && body.trim() !== '' && reasonOk && !busy

  async function submit(e: FormEvent) {
    e.preventDefault()
    if (!ready) return
    setBusy(true)
    setError(null)
    const input: NoticeInput = { category, title: title.trim(), body: body.trim(), audience, locale: locale.trim(), pinned, reason: reason.trim() }
    // When editing, the publish time is only sent if it was changed, so the saved time keeps its seconds.
    if (publishedAt !== '' && (notice === null || publishedAt !== initialPublished)) input.publishedAt = toIso(publishedAt)
    const end = toIso(expiresAt)
    if (end) input.expiresAt = end
    try {
      const saved = notice === null
        ? await api<NoticeRecord>('POST', '/notices', input)
        : await api<NoticeRecord>('PUT', `/notices/${notice.noticeId}`, input)
      await onSaved(saved, notice === null)
    } catch (err) {
      setError(messageOf(err))
      setBusy(false)
    }
  }

  return (
    <form className="card notice-form" onSubmit={submit} aria-label={notice ? 'Edit notice' : 'New notice'}>
      <h2>{notice ? 'Edit notice' : 'New notice'}</h2>
      <div className="two">
        <div>
          <label htmlFor={`${id}-category`}>Category</label>
          <select id={`${id}-category`} value={category} onChange={(e) => setCategory(e.target.value as NoticeCategory)}>
            {CATEGORIES.map((c) => <option key={c} value={c}>{c}</option>)}
          </select>
          <label htmlFor={`${id}-title`}>Title</label>
          <input id={`${id}-title`} type="text" value={title} onChange={(e) => setTitle(e.target.value)} maxLength={MAX_NOTICE_TITLE} required aria-describedby={`${id}-title-hint`} />
          <div className="hint" id={`${id}-title-hint`}>One line, up to {MAX_NOTICE_TITLE} characters ({[...title].length} used).</div>
          <label htmlFor={`${id}-audience`}>Audience</label>
          <select id={`${id}-audience`} value={audience} onChange={(e) => setAudience(e.target.value as NoticeAudience)}>
            {AUDIENCES.map((a) => <option key={a} value={a}>{a}</option>)}
          </select>
          <div className="hint">minors: members under 18. adults: everyone else.</div>
          <label htmlFor={`${id}-locale`}>Language</label>
          <input id={`${id}-locale`} type="text" value={locale} onChange={(e) => setLocale(e.target.value)} maxLength={20} placeholder="en or pt-BR" aria-describedby={`${id}-locale-hint`} />
          <div className="hint" id={`${id}-locale-hint`}>Leave empty to show it in every language.</div>
          <label className="check">
            <input type="checkbox" checked={pinned} onChange={(e) => setPinned(e.target.checked)} />
            Pinned (stays at the top of the board)
          </label>
          <label htmlFor={`${id}-published`}>Publish at</label>
          <input id={`${id}-published`} type="datetime-local" value={publishedAt} onChange={(e) => setPublishedAt(e.target.value)} />
          <div className="hint">Empty: now. A later time schedules the notice. Your time zone.</div>
          <label htmlFor={`${id}-expires`}>Expires at</label>
          <input id={`${id}-expires`} type="datetime-local" value={expiresAt} onChange={(e) => setExpiresAt(e.target.value)} />
          <div className="hint">Empty: stays until unpublished. Must be in the future.</div>
        </div>
        <div>
          <label htmlFor={`${id}-body`}>Text</label>
          <textarea id={`${id}-body`} value={body} onChange={(e) => setBody(e.target.value)} rows={10} maxLength={MAX_NOTICE_BODY} required aria-describedby={`${id}-body-hint`} />
          <div className="hint" id={`${id}-body-hint`}>
            Up to {MAX_NOTICE_BODY} characters ({[...body].length} used). A blank line starts a paragraph. <code>**bold**</code> and <code>[label](https://address)</code> are the only markup: https links only, no HTML (no &lt; or &gt;), no images.
          </div>
          {problems.length > 0 && <ul className="hint problems" aria-label="Things the server will refuse">{problems.map((p) => <li key={p}>{p}</li>)}</ul>}
          <h3>Preview</h3>
          <div className="preview" role="region" aria-label="Preview of the notice">
            {title.trim() !== '' && <p><strong>{title}</strong></p>}
            {body.trim() === '' ? <p className="muted">Nothing to preview yet.</p> : <NoticeBody body={body} />}
          </div>
        </div>
      </div>
      <label htmlFor={`${id}-reason`}>Reason (recorded in the audit log, at least {MIN_REASON} characters)</label>
      <textarea id={`${id}-reason`} value={reason} onChange={(e) => setReason(e.target.value)} rows={3} maxLength={1000} required />
      <div className="hint">{reason.trim().length < MIN_REASON ? `${MIN_REASON - reason.trim().length} more characters needed` : 'Reason ready'}</div>
      <ErrorNote error={error} />
      <div className="actions">
        <button type="button" className="secondary" onClick={onCancel}>Cancel</button>
        <button type="submit" className="primary" disabled={!ready}>{busy ? 'Saving…' : notice ? 'Save changes' : 'Publish notice'}</button>
      </div>
    </form>
  )
}
