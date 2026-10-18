import { useId, useState, type FormEvent } from 'react'
import { Link, useParams } from 'react-router'
import { api, ApiError, canModerate, type SupportThreadRecord, type SupportThreadView } from '../api'
import { useOperator } from '../auth'
import { CANNED_REPLIES } from '../cannedReplies'
import { messageOf, Chip, ErrorNote, Time, useLoad } from '../ui'
import { AgeBand } from './Support'

const MAX_REPLY = 2000

function actionMessage(e: unknown, action: 'reply' | 'reopen' | 'other'): string {
  if (e instanceof ApiError) {
    if (e.code === 'SUPPORT_THREAD_CLOSED') return 'This conversation is closed. Reopen it before replying.'
    if (e.code === 'SUPPORT_THREAD_OPEN' && action === 'reopen') return 'This member already has another open conversation in this category, so this one cannot be reopened. Continue there, or close that one first.'
  }
  return messageOf(e)
}

/** One conversation. Loading it is an audited read; the messages are plain text the member knows staff can read. */
export function SupportThread() {
  const { id = '' } = useParams()
  const operator = useOperator()
  const mayAct = canModerate(operator.role)
  const { data, error, loading, reload, setData } = useLoad(() => api<SupportThreadView>('GET', `/support/threads/${id}`), id)
  const [reply, setReply] = useState('')
  const [busy, setBusy] = useState(false)
  const [actionError, setActionError] = useState<string | null>(null)
  const [done, setDone] = useState<string | null>(null)
  const replyId = useId()

  if (loading && !data) return <p role="status">Loading…</p>
  if (!data) return <ErrorNote error={error ?? 'Not found'} />
  const { thread, messages } = data
  const closed = thread.status === 'closed'
  const body = reply.trim()

  function adopt(t: SupportThreadRecord) {
    setData((d) => (d ? { ...d, thread: t } : d))
  }

  async function run(action: 'reply' | 'reopen' | 'other', fn: () => Promise<void>) {
    setBusy(true)
    setActionError(null)
    setDone(null)
    try {
      await fn()
    } catch (e) {
      setActionError(actionMessage(e, action))
      // The thread was closed under us: show it as closed.
      if (e instanceof ApiError && e.code === 'SUPPORT_THREAD_CLOSED') await reload()
    } finally {
      setBusy(false)
    }
  }

  async function send(e: FormEvent) {
    e.preventDefault()
    if (body === '' || [...body].length > MAX_REPLY || busy) return
    await run('reply', async () => {
      await api('POST', `/support/threads/${id}/reply`, { body })
      setReply('')
      setDone('Reply sent. The member gets a notification without its text.')
      await reload()
    })
  }

  function insert(text: string) {
    setReply((r) => (r.trim() === '' ? text : `${r.replace(/\s+$/, '')}\n\n${text}`))
  }

  return (
    <article aria-labelledby="thread-title">
      <p><Link to="/support">← Support inbox</Link></p>
      <h1 id="thread-title">
        Conversation {thread.threadId.slice(-8)} <span className="chips">
          <Chip kind={closed ? 'neutral' : 'ok'}>{thread.status}</Chip>
          <AgeBand band={thread.member.ageBand} />
        </span>
      </h1>
      <p className="sensitive" role="note">Support messages are plain text the member knows staff can read. Viewing is audited.</p>
      {done && <p role="status" className="notice">{done}</p>}
      <ErrorNote error={actionError ?? error} />

      <dl className="facts">
        <dt>Member</dt><dd>@{thread.member.username || 'unknown'} <span className="muted">{thread.member.displayName}</span> <AgeBand band={thread.member.ageBand} /></dd>
        <dt>Account</dt><dd>{thread.member.status}</dd>
        <dt>Category</dt><dd>{thread.category}</dd>
        <dt>Started</dt><dd><Time value={thread.createdAt} /></dd>
        <dt>Last activity</dt><dd><Time value={thread.lastMessageAt} /></dd>
        <dt>Assigned to</dt><dd>{thread.assignedTo ?? <span className="muted">nobody</span>}{thread.assignedToMe && <> <Chip kind="neutral">you</Chip></>}</dd>
      </dl>

      {mayAct ? (
        <div className="actions-bar">
          <div className="actions">
            {closed
              ? <button type="button" className="secondary" disabled={busy} onClick={() => void run('reopen', async () => { adopt(await api<SupportThreadRecord>('POST', `/support/threads/${id}/reopen`, {})); setDone('Conversation reopened.') })}>Reopen</button>
              : <button type="button" className="secondary" disabled={busy} onClick={() => void run('other', async () => { adopt(await api<SupportThreadRecord>('POST', `/support/threads/${id}/close`, {})); setDone('Conversation closed.') })}>Close</button>}
            {thread.assignedToMe
              ? <button type="button" className="secondary" disabled={busy} onClick={() => void run('other', async () => { adopt(await api<SupportThreadRecord>('POST', `/support/threads/${id}/assign`, { assignTo: null })); setDone('Unassigned.') })}>Unassign</button>
              : <button type="button" className="secondary" disabled={busy} onClick={() => void run('other', async () => { adopt(await api<SupportThreadRecord>('POST', `/support/threads/${id}/assign`, { assignTo: 'me' })); setDone('Assigned to you.') })}>Assign to me</button>}
          </div>
        </div>
      ) : (
        <p className="hint">Your role is read-only: you can read conversations, but moderators and administrators reply, close, reopen and assign them.</p>
      )}

      <h2>Messages</h2>
      <ol className="evidence thread" aria-label="Messages">
        {messages.map((m) => (
          <li key={m.messageId} className={m.author === 'staff' ? 'from-staff' : 'from-member'}>
            <strong>{m.author === 'staff' ? `Hiyall staff${m.operator ? ` (${m.operator})` : ''}` : `Member @${thread.member.username || 'unknown'}`}</strong>{' '}
            <span className="muted"><Time value={m.createdAt} /></span>
            <p>{m.body}</p>
          </li>
        ))}
      </ol>
      {messages.length === 0 && <p className="muted">No messages.</p>}

      {mayAct && (closed ? (
        <p className="hint">This conversation is closed. Reopen it to reply.</p>
      ) : (
        <form onSubmit={send} aria-label="Reply">
          <h2>Reply</h2>
          {thread.member.ageBand === 'minor' && (
            <p className="sensitive" role="note">This member is under 18. Keep every reply inside Hiyall: never ask for contact details and never suggest any contact outside the app.</p>
          )}
          <div className="canned" role="group" aria-label="Canned replies">
            <span className="hint">Insert a template, then edit it before you send:</span>
            {CANNED_REPLIES.map((c) => (
              <button key={c.id} type="button" className="secondary" onClick={() => insert(c.body)}>{c.title}</button>
            ))}
          </div>
          <label htmlFor={replyId}>Your reply (plain text, shown to the member as Hiyall staff)</label>
          <textarea id={replyId} value={reply} onChange={(e) => setReply(e.target.value)} rows={6} maxLength={MAX_REPLY} aria-describedby={`${replyId}-count`} />
          <div className="hint" id={`${replyId}-count`}>{[...reply].length} / {MAX_REPLY}</div>
          <div className="actions">
            <button type="submit" className="primary" disabled={busy || body === '' || [...body].length > MAX_REPLY}>{busy ? 'Working…' : 'Send reply'}</button>
          </div>
        </form>
      ))}
    </article>
  )
}
