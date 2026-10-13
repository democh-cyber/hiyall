import { vi } from 'vitest'

export interface Call {
  method: string
  path: string
  body: unknown
  headers: Record<string, string>
}

type Handler = (call: Call) => { status?: number; data?: unknown; error?: { code: string; message: string } }

/** Replaces fetch with a table of "METHOD /path" handlers (query string included in the key's path prefix match). */
export function mockApi(routes: Record<string, Handler>) {
  const calls: Call[] = []
  const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input).replace(/^\/admin\/v1/, '')
    const method = init?.method ?? 'GET'
    const call: Call = { method, path: url, body: init?.body ? JSON.parse(String(init.body)) : undefined, headers: (init?.headers ?? {}) as Record<string, string> }
    calls.push(call)
    const key = Object.keys(routes).find((k) => k === `${method} ${url}` || (k.endsWith('*') && `${method} ${url}`.startsWith(k.slice(0, -1))))
    const reply = key ? routes[key](call) : { status: 404, error: { code: 'NOT_FOUND', message: 'unavailable' } }
    const status = reply.status ?? (reply.error ? 400 : 200)
    const body = reply.error ? { success: false, error: reply.error } : { success: true, data: reply.data }
    return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })
  })
  vi.stubGlobal('fetch', fetchMock)
  return { calls, fetchMock }
}

export const operator = (role: 'viewer' | 'moderator' | 'admin') => ({
  operatorId: 'op-1', email: 'sam@hiyall.test', displayName: 'Sam', role, disabledAt: null, createdAt: '2026-10-01T00:00:00Z', lastLoginAt: null,
})

export const session = (role: 'viewer' | 'moderator' | 'admin') => ({ operator: operator(role), csrfToken: 'csrf-123', expiresAt: '2026-10-14T00:00:00Z' })

export const member = (over: Record<string, unknown> = {}) => ({
  userId: 'u-1', username: 'bob', displayName: 'Bob', ageBand: 'adult', status: 'active', createdAt: '2026-01-01T00:00:00Z',
  reportsAgainst: 2, openReportsAgainst: 1, reportsFiled: 0, reportsFiledDismissed: 0, ...over,
})

export const row = (over: Record<string, unknown> = {}) => ({
  reportId: '019a0000-0000-7000-8000-000000000001', targetType: 'user', targetId: 'u-1', reasonCode: 'harassment', severity: 'normal', status: 'open',
  minor: false, reporterMinor: false, subjectMinor: false, subjectId: 'u-1', subjectUsername: 'bob', priorReportCount: 1, evidenceCount: 0, heldImageCount: 0,
  createdAt: '2026-10-12T10:00:00Z', resolvedAt: null, ...over,
})

export const theCase = (over: Record<string, unknown> = {}) => ({
  ...row({ minor: true, severity: 'high', reasonCode: 'sexual_content', evidenceCount: 1, heldImageCount: 1 }),
  description: 'sent me an image', disclosureConsent: true, resolutionCode: '', reporter: member({ userId: 'u-2', username: 'rita', displayName: 'Rita', ageBand: 'minor' }),
  subject: member(),
  evidence: [{ messageId: 'm-1', text: 'the shared message text', sentAt: '2026-10-12T09:00:00Z', fromReporter: false, imageBlobIds: ['b-1'] }],
  heldImages: [{ blobId: 'b-1', role: 'full', sizeBytes: 2048, sha256: 'q6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6s=', state: 'uploaded' }],
  priorReports: [], actions: [], ...over,
})
