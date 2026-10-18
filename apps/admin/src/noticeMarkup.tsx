import type { ReactNode } from 'react'

// The notice board's markup: paragraphs (a blank line), **bold** and [label](https://address) links, nothing else.
// The same rules the server enforces on save and the apps use to draw a notice (domain.ValidateNoticeBody). Everything
// is built as React elements from text, never as HTML, so any other markup (tags, images, other schemes) stays literal text.

/** Same shape as the server's link pattern: a short label without brackets, an address without spaces or parentheses. */
const LINK_OR_BOLD = /\[([^[\]\n]{1,80})\]\(([^()\s]{1,300})\)|\*\*/g

/** An https address with a host and no credentials; anything else (http, javascript, data, mailto) is not a link. */
export function isSafeLink(target: string): boolean {
  if (/\s/.test(target)) return false
  try {
    const u = new URL(target)
    return u.protocol === 'https:' && u.hostname !== '' && u.username === '' && u.password === ''
  } catch {
    return false
  }
}

type Token = { kind: 'text'; text: string } | { kind: 'link'; label: string; href: string } | { kind: 'bold' }

function tokenize(paragraph: string): Token[] {
  const tokens: Token[] = []
  let last = 0
  for (const m of paragraph.matchAll(LINK_OR_BOLD)) {
    const at = m.index ?? 0
    if (at > last) tokens.push({ kind: 'text', text: paragraph.slice(last, at) })
    if (m[0] === '**') {
      tokens.push({ kind: 'bold' })
    } else if (isSafeLink(m[2]) && paragraph[at - 1] !== '!') {
      tokens.push({ kind: 'link', label: m[1], href: m[2] })
    } else {
      // Not a safe link (or an image marker): it stays visible as the text the author wrote.
      tokens.push({ kind: 'text', text: m[0] })
    }
    last = at + m[0].length
  }
  if (last < paragraph.length) tokens.push({ kind: 'text', text: paragraph.slice(last) })
  // An unmatched ** is literal text.
  const bolds = tokens.flatMap((t, i) => (t.kind === 'bold' ? [i] : []))
  if (bolds.length % 2 === 1) tokens[bolds[bolds.length - 1]] = { kind: 'text', text: '**' }
  return tokens
}

function renderParagraph(paragraph: string, key: number): ReactNode {
  const out: ReactNode[] = []
  let bold = false
  let run: ReactNode[] = []
  const flush = () => {
    if (run.length === 0) return
    out.push(bold ? <strong key={out.length}>{run}</strong> : <span key={out.length}>{run}</span>)
    run = []
  }
  tokenize(paragraph).forEach((t, i) => {
    if (t.kind === 'bold') {
      flush()
      bold = !bold
    } else if (t.kind === 'link') {
      run.push(<a key={i} href={t.href} target="_blank" rel="noopener noreferrer">{t.label}</a>)
    } else {
      run.push(t.text)
    }
  })
  flush()
  return <p key={key}>{out}</p>
}

/** The paragraphs of a notice body as React nodes. */
export function renderNoticeBody(body: string): ReactNode[] {
  return body
    .replace(/\r\n/g, '\n')
    .trim()
    .split(/\n{2,}/)
    .filter((p) => p.trim() !== '')
    .map((p, i) => renderParagraph(p, i))
}

export function NoticeBody({ body }: { body: string }) {
  return <div className="notice-body">{renderNoticeBody(body)}</div>
}

export const MAX_NOTICE_TITLE = 120
export const MAX_NOTICE_BODY = 4000

/**
 * A mirror of the server's body rules, for helper text only (the server decides): what is wrong with this body,
 * empty when it looks fine.
 */
export function noticeBodyProblems(body: string): string[] {
  const problems: string[] = []
  const text = body.replace(/\r\n/g, '\n').trim()
  if (text === '') return problems
  if ([...text].length > MAX_NOTICE_BODY) problems.push(`Too long: at most ${MAX_NOTICE_BODY} characters.`)
  if (/[<>]/.test(text)) problems.push('HTML is not allowed: remove < and >.')
  if (text.includes('![')) problems.push('Images are not allowed.')
  const links = [...text.matchAll(/\[([^[\]\n]{1,80})\]\(([^()\s]{1,300})\)/g)]
  if (links.some((m) => !isSafeLink(m[2]))) problems.push('Links must be https addresses.')
  const rest = text.replace(/\[([^[\]\n]{1,80})\]\(([^()\s]{1,300})\)/g, '')
  if (rest.includes('](')) problems.push('Write a link as [label](https://address).')
  if (text.split('\n\n').some((p) => (p.match(/\*\*/g) ?? []).length % 2 === 1)) problems.push('Close every bold text with **.')
  return problems
}
