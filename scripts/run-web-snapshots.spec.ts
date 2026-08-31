import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { expect, it } from 'vitest'

it('runs the built-boot digest snapshot before HMR rewrites dist', () => {
  const source = readFileSync(resolve(import.meta.dirname, 'run-web-snapshots.ts'), 'utf8')
  const block = /const serialFiles = \[([\s\S]*?)\]/.exec(source)
  if (block?.[1] === undefined) throw new Error('serialFiles list missing')
  const files = [...block[1].matchAll(/'([^']+)'/g)].map(match => match[1])
  expect(files[0]).toBe('apps/web/tests/built-boot.snapshot.ts')
  expect(files.indexOf('apps/web/tests/hmr-live.e2e.ts')).toBeGreaterThan(0)
})
