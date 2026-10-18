import { render } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import { isSafeLink, NoticeBody, noticeBodyProblems } from '../noticeMarkup'

function html(body: string): HTMLElement {
  const { container } = render(<NoticeBody body={body} />)
  return container
}

describe('notice markup', () => {
  it('draws paragraphs from blank lines', () => {
    const c = html('First paragraph.\n\nSecond paragraph.')
    expect([...c.querySelectorAll('p')].map((p) => p.textContent)).toEqual(['First paragraph.', 'Second paragraph.'])
  })

  it('draws **bold** as strong and keeps the rest as text', () => {
    const c = html('Be **careful** with links.')
    expect(c.querySelector('strong')?.textContent).toBe('careful')
    expect(c.querySelector('p')?.textContent).toBe('Be careful with links.')
  })

  it('leaves an unclosed ** as literal text', () => {
    const c = html('Be **careful')
    expect(c.querySelector('strong')).toBeNull()
    expect(c.textContent).toBe('Be **careful')
  })

  it('turns an https link into an anchor that opens safely in a new tab', () => {
    const a = html('Read [our tips](https://hiyall.app/safety) first.').querySelector('a')!
    expect(a.getAttribute('href')).toBe('https://hiyall.app/safety')
    expect(a.textContent).toBe('our tips')
    expect(a.getAttribute('target')).toBe('_blank')
    expect(a.getAttribute('rel')).toBe('noopener noreferrer')
  })

  it.each([
    ['http', '[x](http://hiyall.app)'],
    ['javascript', '[x](javascript:alert(1))'],
    ['javascript without parentheses', '[x](javascript:alert)'],
    ['data', '[x](data:text/html;base64,AAAA)'],
    ['mailto', '[x](mailto:a@b.test)'],
    ['protocol-relative', '[x](//evil.test/a)'],
    ['credentials', '[x](https://user:pw@evil.test/)'],
    ['no scheme', '[x](hiyall.app)'],
  ])('does not link a %s address', (_name, text) => {
    const c = html(text)
    expect(c.querySelector('a')).toBeNull()
    expect(c.textContent).toBe(text)
  })

  it('shows HTML as text and creates no elements from it', () => {
    const c = html('<script>alert(1)</script> <img src=x onerror=alert(1)> <b>bold?</b>')
    expect(c.querySelector('script, img, b')).toBeNull()
    expect(c.textContent).toContain('<script>alert(1)</script>')
    expect(c.textContent).toContain('<img src=x onerror=alert(1)>')
  })

  it('shows an image marker as text', () => {
    const c = html('![alt](https://hiyall.app/a.png)')
    expect(c.querySelector('img')).toBeNull()
    expect(c.textContent).toContain('![')
  })

  it('treats bold around a link as bold link', () => {
    const c = html('**see [here](https://hiyall.app)**')
    expect(c.querySelector('strong a')?.getAttribute('href')).toBe('https://hiyall.app')
  })

  it('isSafeLink accepts only https addresses with a host', () => {
    expect(isSafeLink('https://hiyall.app/x?y=1')).toBe(true)
    expect(isSafeLink('https://')).toBe(false)
    expect(isSafeLink('http://hiyall.app')).toBe(false)
    expect(isSafeLink('https://a b.test')).toBe(false)
  })
})

describe('notice body helper (mirror of the server rules)', () => {
  it('has nothing to say about a good body', () => {
    expect(noticeBodyProblems('Hello **there**.\n\nSee [tips](https://hiyall.app).')).toEqual([])
    expect(noticeBodyProblems('')).toEqual([])
  })

  it('names each rule the server enforces', () => {
    expect(noticeBodyProblems('a <b> c').join(' ')).toMatch(/HTML/)
    expect(noticeBodyProblems('![x](https://hiyall.app/a.png)').join(' ')).toMatch(/Images/)
    expect(noticeBodyProblems('[x](http://hiyall.app)').join(' ')).toMatch(/https/)
    expect(noticeBodyProblems('a **b').join(' ')).toMatch(/bold/)
    expect(noticeBodyProblems('x'.repeat(4001)).join(' ')).toMatch(/Too long/)
  })
})
