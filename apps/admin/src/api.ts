// Client for /admin/v1. Same origin only; the session is an HttpOnly cookie the page cannot read, and
// every mutating request carries the CSRF token the server returned at sign-in.

export type Role = 'viewer' | 'moderator' | 'admin'

export interface Operator {
  operatorId: string
  email: string
  displayName: string
  role: Role
  disabledAt: string | null
  createdAt: string
  lastLoginAt: string | null
}

export interface Member {
  userId: string
  username: string
  displayName: string
  ageBand: 'minor' | 'adult'
  status: string
  createdAt: string
  reportsAgainst: number
  openReportsAgainst: number
  reportsFiled: number
  reportsFiledDismissed: number
}

export interface ReportRow {
  reportId: string
  targetType: string
  targetId: string
  reasonCode: string
  severity: 'high' | 'normal'
  status: 'open' | 'actioned' | 'dismissed'
  minor: boolean
  reporterMinor: boolean
  subjectMinor: boolean
  subjectId: string
  subjectUsername: string
  priorReportCount: number
  evidenceCount: number
  heldImageCount: number
  createdAt: string
  resolvedAt: string | null
}

export interface Evidence {
  messageId: string
  text: string
  sentAt: string
  fromReporter: boolean
  imageBlobIds: string[]
}

export interface HeldImage {
  blobId: string
  role: string
  sizeBytes: number
  sha256: string
  state: string
}

export interface ReportRef {
  reportId: string
  reasonCode: string
  severity: string
  status: string
  resolutionCode: string
  createdAt: string
  resolvedAt: string | null
}

export interface ModAction {
  actionId: string
  reportId: string | null
  actor: string
  type: string
  note: string
  createdAt: string
}

export interface Case extends ReportRow {
  description: string
  disclosureConsent: boolean
  resolutionCode: string
  reporter: Member
  subject: Member
  evidence: Evidence[]
  heldImages: HeldImage[]
  priorReports: ReportRef[]
  actions: ModAction[]
}

export interface UserView extends Member {
  activeSessions: number
  reports: ReportRef[]
  actions: ModAction[]
}

export interface AuditRecord {
  auditId: number
  at: string
  operatorId: string | null
  actor: string
  action: string
  targetType: string
  targetId: string
  reason: string
  ip: string
  detail: Record<string, unknown>
}

export interface PreviewMedia {
  mediaId: string
  width: number
  height: number
  /** Short-lived link through the console; empty when the console has no storage access. */
  url: string
}

export interface ReportedContent {
  targetType: string
  targetId: string
  text: string
  title?: string
  authorId: string
  authorUsername: string
  createdAt: string
  deleted: boolean
}

export interface ContentPreview {
  content: ReportedContent
  media: PreviewMedia[]
  mediaAvailable: boolean
}

export interface ContentCase {
  caseId: string
  mediaId: string
  userId: string
  username: string
  ageBand: 'minor' | 'adult'
  accountStatus: string
  purpose: string
  result: 'flagged' | 'match'
  scanner: string
  signals: Record<string, string>
  originalSha256: string
  originalBytes: number
  contentType: string
  suspendedUser: boolean
  status: 'open' | 'confirmed' | 'cleared' | 'reported'
  createdAt: string
  holdUntil: string
  legalHold: boolean
  reviewedBy: string
  reviewedAt: string | null
  resolutionNote: string
  reportReference: string
  reportedAt: string | null
  releasedAt: string | null
  releasedBy: string
  releaseReason: string
  objectsPurgedAt: string | null
  /** Why the hold cannot be released now; empty when it can, and once it is released. */
  releaseBlocker: '' | 'CASE_OPEN' | 'LEGAL_HOLD' | 'REPORT_OPEN' | 'OTHER_CASE_OPEN'
}

export interface Page<T> {
  items: T[]
  nextCursor: string | null
  hasMore: boolean
}

export interface SessionInfo {
  operator: Operator
  csrfToken: string
  expiresAt: string
}

export class ApiError extends Error {
  status: number
  code: string
  constructor(status: number, code: string, message: string) {
    super(message)
    this.status = status
    this.code = code
  }
}

let csrfToken = ''
let onSignedOut: () => void = () => {}

export function setCsrf(token: string) {
  csrfToken = token
}

/** Called when the server says the session is gone, so the app can show the sign-in page. */
export function setSignedOutHandler(fn: () => void) {
  onSignedOut = fn
}

export async function api<T>(method: 'GET' | 'POST', path: string, body?: unknown): Promise<T> {
  const headers: Record<string, string> = { Accept: 'application/json' }
  if (body !== undefined) headers['Content-Type'] = 'application/json'
  if (method !== 'GET' && csrfToken) headers['X-CSRF-Token'] = csrfToken
  let res: Response
  try {
    res = await fetch('/admin/v1' + path, {
      method,
      headers,
      credentials: 'same-origin',
      body: body === undefined ? undefined : JSON.stringify(body),
    })
  } catch {
    throw new ApiError(0, 'NETWORK', 'Cannot reach the console server')
  }
  let json: { success?: boolean; data?: T; error?: { code: string; message: string } } = {}
  try {
    json = await res.json()
  } catch {
    // not JSON: handled below
  }
  if (!res.ok || json.success === false) {
    const err = json.error ?? { code: 'ERROR', message: `Request failed (${res.status})` }
    if (res.status === 401 && path !== '/login') onSignedOut()
    throw new ApiError(res.status, err.code, err.message)
  }
  return json.data as T
}

export function query(params: Record<string, string | boolean | undefined>): string {
  const q = new URLSearchParams()
  for (const [k, v] of Object.entries(params)) {
    if (v === undefined || v === '' || v === false) continue
    q.set(k, String(v))
  }
  const s = q.toString()
  return s ? '?' + s : ''
}

/** Reports about chats have no preview: staff only see what the reporter shared. */
export function hasPreview(targetType: string): boolean {
  return targetType !== 'conversation' && targetType !== 'message'
}

export function canModerate(role: Role | undefined): boolean {
  return role === 'moderator' || role === 'admin'
}
