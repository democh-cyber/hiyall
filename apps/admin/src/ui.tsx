import { useCallback, useEffect, useId, useRef, useState, type FormEvent, type ReactNode } from 'react'
import { ApiError } from './api'

export function messageOf(e: unknown): string {
  return e instanceof ApiError ? e.message : 'Something went wrong'
}

export function Time({ value }: { value: string | null }) {
  if (!value) return <span>never</span>
  const d = new Date(value)
  return <time dateTime={value} title={value}>{d.toLocaleString()}</time>
}

export function Chip({ kind, children }: { kind: 'high' | 'minor' | 'neutral' | 'ok' | 'warn'; children: ReactNode }) {
  return <span className={`chip chip-${kind}`}>{children}</span>
}

export function ErrorNote({ error }: { error: string | null }) {
  return (
    <div role="alert" aria-live="assertive" className={error ? 'error' : 'error empty'}>
      {error}
    </div>
  )
}

/** Runs a loader when its key changes and exposes loading and error state. */
export function useLoad<T>(load: () => Promise<T>, key: string) {
  const [data, setData] = useState<T | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const loadRef = useRef(load)
  loadRef.current = load
  const reload = useCallback(() => {
    setLoading(true)
    setError(null)
    return loadRef.current().then(setData, (e) => setError(messageOf(e))).finally(() => setLoading(false))
  }, [])
  // eslint-disable-next-line react-hooks/exhaustive-deps
  useEffect(() => { reload() }, [key])
  return { data, error, loading, reload, setData }
}

export interface DialogProps {
  title: string
  onClose: () => void
  children: ReactNode
}

/** A modal dialog: focus moves in, Escape closes, Tab stays inside. */
export function Dialog({ title, onClose, children }: DialogProps) {
  const ref = useRef<HTMLDivElement>(null)
  const titleId = useId()
  useEffect(() => {
    const previous = document.activeElement as HTMLElement | null
    const first = ref.current?.querySelector<HTMLElement>('textarea, input, select, button')
    first?.focus()
    return () => previous?.focus?.()
  }, [])
  function onKeyDown(e: React.KeyboardEvent) {
    if (e.key === 'Escape') {
      e.stopPropagation()
      onClose()
    } else if (e.key === 'Tab' && ref.current) {
      const nodes = Array.from(ref.current.querySelectorAll<HTMLElement>('textarea, input, select, button:not([disabled])'))
      if (nodes.length === 0) return
      const first = nodes[0]
      const last = nodes[nodes.length - 1]
      if (e.shiftKey && document.activeElement === first) {
        e.preventDefault()
        last.focus()
      } else if (!e.shiftKey && document.activeElement === last) {
        e.preventDefault()
        first.focus()
      }
    }
  }
  return (
    <div className="backdrop" onKeyDown={onKeyDown}>
      <div className="dialog" role="dialog" aria-modal="true" aria-labelledby={titleId} ref={ref}>
        <h2 id={titleId}>{title}</h2>
        {children}
      </div>
    </div>
  )
}

export const MIN_REASON = 10

export interface ReasonDialogProps {
  title: string
  intro?: ReactNode
  confirmLabel: string
  /** A second step: the person must tick this before the action can be sent (suspend). */
  confirmText?: string
  danger?: boolean
  /** An extra required line of text (a report reference); onSubmit then receives it as the second argument. */
  referenceLabel?: string
  onSubmit: (reason: string, reference: string) => Promise<void>
  onClose: () => void
}

/** Every action needs a written reason of at least 10 characters, and some need an explicit confirmation. */
export function ReasonDialog({ title, intro, confirmLabel, confirmText, danger, referenceLabel, onSubmit, onClose }: ReasonDialogProps) {
  const [reason, setReason] = useState('')
  const [reference, setReference] = useState('')
  const referenceId = useId()
  const [confirmed, setConfirmed] = useState(!confirmText)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const reasonId = useId()
  const trimmed = reason.trim()
  const ready = trimmed.length >= MIN_REASON && confirmed && !busy && (!referenceLabel || reference.trim().length > 0)

  async function submit(e: FormEvent) {
    e.preventDefault()
    if (!ready) return
    setBusy(true)
    setError(null)
    try {
      await onSubmit(trimmed, reference.trim())
    } catch (err) {
      setError(messageOf(err))
      setBusy(false)
    }
  }

  return (
    <Dialog title={title} onClose={onClose}>
      <form onSubmit={submit}>
        {intro && <div className="intro">{intro}</div>}
        <label htmlFor={reasonId}>Reason (recorded in the audit log, at least {MIN_REASON} characters)</label>
        <textarea id={reasonId} value={reason} onChange={(e) => setReason(e.target.value)} rows={4} maxLength={1000} required />
        <div className="hint">{trimmed.length < MIN_REASON ? `${MIN_REASON - trimmed.length} more characters needed` : 'Reason ready'}</div>
        {referenceLabel && (
          <>
            <label htmlFor={referenceId}>{referenceLabel}</label>
            <input id={referenceId} type="text" value={reference} onChange={(e) => setReference(e.target.value)} maxLength={200} required />
          </>
        )}
        {confirmText && (
          <label className="check">
            <input type="checkbox" checked={confirmed} onChange={(e) => setConfirmed(e.target.checked)} />
            {confirmText}
          </label>
        )}
        <ErrorNote error={error} />
        <div className="actions">
          <button type="button" className="secondary" onClick={onClose}>Cancel</button>
          <button type="submit" className={danger ? 'danger' : 'primary'} disabled={!ready}>{busy ? 'Working…' : confirmLabel}</button>
        </div>
      </form>
    </Dialog>
  )
}

export function formatBytes(n: number): string {
  if (n < 1024) return `${n} B`
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KiB`
  return `${(n / 1024 / 1024).toFixed(1)} MiB`
}
