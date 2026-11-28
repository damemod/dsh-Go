// The plugin runs against the plugin-kit test host (the bridge's own manifest,
// effect and view code), so these are the answers the app would give.
import { realDshTools, registeredTools } from './dsh-tools.js'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'
import { createTestHost } from '../../../../sdk/plugin-kit/lib/testing.js'
import { SchemaSet } from '../../../../sdk/plugin-kit/lib/json-schema.js'
import { LIMITS, SCOPE_KEYS } from '../../../../sdk/plugin-kit/lib/bridge/limits.js'
import { checkManifest } from '../../../../sdk/plugin-kit/lib/check.js'

// dsh-tools.js registers the module hook during evaluation; loading lib/index.js
// dynamically (as weather's registeredTools does) keeps resolution after that hook.
const { apply } = await import('../lib/index.js')

const dir = fileURLToPath(new URL('..', import.meta.url))
const pkg = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8'))
const isLosslessJson = (v) => JSON.stringify(JSON.parse(JSON.stringify(v))) === JSON.stringify(v)

function host(services = {}) {
  const h = createTestHost({ dir, services: { tools: { register: () => () => {} }, ...services } })
  apply(h.ctx)
  return h
}

const looks = (row) => ({
  composerActions: row.contributes['composer.actions'].map((a) => [a.id, a.ready]),
  composerTools: row.contributes['composer.tools'].map((a) => [a.id, a.ready]),
  sessionActions: row.contributes['session.actions'].map((a) => [a.id, a.ready]),
  panels: row.contributes.panels.map((p) => [p.id, p.ready]),
  strip: row.contributes['composer.strip'].map((s) => [s.id, s.ready]),
  turn: row.contributes['turn.note'].map((n) => [n.id, n.ready]),
})

test('manifest validates against manifest.schema.json, both locales', () => {
  const schemas = new SchemaSet()
  assert.deepEqual(schemas.validate(pkg.dshGo, 'manifest.schema.json', ''), [])
  for (const locale of ['zh-CN', 'en-US']) {
    const row = host().contributions({ locale })
    assert.equal(row.state, 'ok')
    assert.deepEqual(row.issues, [], `${locale}: no manifest issues`)
  }
})

test('all six seats are present and ready, each within its per-plugin cap', () => {
  const row = host().contributions()
  assert.deepEqual(looks(row), {
    composerActions: [['write-list', true], ['polish-list', true]],
    composerTools: [['insert-tool', true], ['open-tool', true]],
    sessionActions: [['mark', true]],
    panels: [['overview', true], ['guide', true]],
    strip: [['status', true]],
    turn: [['turn', true]],
  })
  const counts = Object.fromEntries(Object.entries(row.contributes).map(([k, v]) => [k, v.length]))
  for (const [surface, count] of Object.entries(counts)) {
    assert.ok(count <= LIMITS.perPlugin[surface], `${surface}: ${count} <= ${LIMITS.perPlugin[surface]}`)
  }
  assert.equal(row.contributes['composer.actions'][0].effect[0].type, 'insert')
  assert.ok(row.contributes['composer.tools'][1].effect[0].page.startsWith('panel:'))
})

test('scope keys stay in the framework id set; no arbitrary key is read', () => {
  assert.deepEqual(SCOPE_KEYS, ['sessionId', 'turnId', 'messageId', 'callId'])
  const code = readFileSync(new URL('../lib/index.js', import.meta.url), 'utf8')
  assert.doesNotMatch(code, /scope\[|scope\.[A-Za-z_$][\w$]*\s*=/, 'scope is read by known keys only')
})

test('static effects never invoke', async () => {
  for (const id of ['write-list', 'insert-tool', 'open-tool']) {
    await assert.rejects(host().invoke(id), { status: 409, code: 'no-handler' })
  }
})

test('polish-list: deferred result inserts the polished draft, never sends', async () => {
  const empty = await host().invoke('polish-list', { context: { draft: '   ' } })
  assert.deepEqual(empty.effects, [])
  assert.deepEqual(await empty.settled, { t: 'done', effects: [{ type: 'toast', text: '输入框里还没有清单' }] })

  const r = await host().invoke('polish-list', { context: { draft: '一、目标\n二、步骤' } })
  assert.deepEqual(r.effects, [])
  assert.deepEqual({ label: r.pending.label, timeoutMs: r.pending.timeoutMs }, { label: '正在润色', timeoutMs: 60000 })
  assert.deepEqual(await r.settled, {
    t: 'done',
    effects: [{ type: 'insert', text: '把下面的清单润色得更清楚，保持原来的项数：\n\n一、目标\n二、步骤' }],
  })
  assert.deepEqual(r.issues, [])
})

test('polish-list: cancellation settles void and inserts nothing', async () => {
  const r = await host().invoke('polish-list', { context: { draft: 'x' } })
  r.cancel()
  assert.deepEqual(await r.settled, { t: 'void', reason: 'cancelled' })
  assert.equal(host().violations.length, 0)
})

test('mark updates the panel and the chat action returns a toast', async () => {
  const h = host()
  const before = await h.view('overview', { sessionId: 's1' })
  assert.match(JSON.stringify(before.view), /已标记对话.*"value":"0"/)
  const r = await h.invoke('mark', { scope: { sessionId: 's1' } })
  assert.deepEqual(r.effects, [{ type: 'toast', text: '已标记这段对话' }])
  const after = await h.view('overview', { sessionId: 's1' })
  assert.match(JSON.stringify(after.view), /已标记对话.*"value":"1"/)
  assert.deepEqual(h.violations, [])
})

test('strip and turn note push short text through their feeds', async () => {
  const h = host()
  const strip = h.subscribe('status', { sessionId: 's1' })
  await strip.settled
  assert.deepEqual(strip.history, [{ text: '示例就绪' }])
  strip.stop()
  const note = h.subscribe('turn', { sessionId: 's1' })
  await note.settled
  assert.deepEqual(note.history, [{ 1: { text: '声明式' } }])
  note.stop()
  assert.deepEqual([...strip.errors, ...note.errors], [])
})

test('both panels render inside the view budgets in both locales', async () => {
  const h = host()
  for (const id of ['overview', 'guide']) {
    for (const locale of ['zh-CN', 'en-US']) {
      const r = await h.view(id, { sessionId: 's1', ...(id === 'overview' ? {} : {}) }, { locale })
      assert.ok(r.stats.bytes <= LIMITS.viewBytes, `${id}/${locale}: ${r.stats.bytes} bytes`)
      assert.ok(r.stats.nodes <= LIMITS.viewNodes, `${id}/${locale}: ${r.stats.nodes} nodes`)
      assert.ok(isLosslessJson(r.view))
    }
  }
  const guide = await h.view('guide')
  assert.equal(guide.view.v, 2)
  assert.equal(guide.view.accent, 'app')
})

test(`tool card (${realDshTools ? 'real dsh-tools' : 'stub'}): presented as a native card, under 8 KiB`, async () => {
  const tool = (await registeredTools()).get('declarative_checklist')
  assert.ok(tool, 'declarative_checklist registered')
  const args = { topic: '发布' }
  const value = await tool.execute(args, { signal: new AbortController().signal })
  const meta = tool.output.presentationMeta(args, value)
  assert.deepEqual(Object.keys(meta), ['dsh-go/view'])
  assert.ok(isLosslessJson(meta))
  assert.ok(Buffer.byteLength(JSON.stringify(meta)) < 8 * 1024)
  const card = meta['dsh-go/view']
  assert.equal(card.type, 'stack')
  assert.equal(card.children[1].type, 'list')
  assert.deepEqual(card.children[1].items.map((x) => x.title), ['明确目标', '列出步骤', '检查结果'])
})

test('a broken tool result never fails the tool call', async () => {
  const tool = (await registeredTools()).get('declarative_checklist')
  assert.deepEqual(tool.output.presentationMeta({}, null), {})
  assert.deepEqual(tool.output.presentationMeta({}, { items: 'not an array' }), {})
})

test('without the bridge nothing native is registered and nothing breaks', () => {
  const h = createTestHost({ dir, bridge: false, services: { tools: { register: () => () => {} } } })
  apply(h.ctx)
  assert.equal(h.pending.length, 1)
  assert.deepEqual(h.pending[0].missing, ['dshGo'])
})

test('corruption probe: the same gates reject a too-many action and a non-static effect', () => {
  const good = checkManifest(pkg, { dir })
  assert.ok(!good.issues.some((i) => ['too-many', 'invalid-field'].includes(i.code)), 'the shipped manifest is clean')

  const over = structuredClone(pkg)
  over.dshGo.contributes['composer.actions'].push({ id: 'extra', label: { zh: '多一个', en: 'Extra' } })
  const overReport = checkManifest(over, { dir })
  assert.ok(overReport.issues.some((i) => i.code === 'too-many'), 'a third capsule is rejected')

  const bad = structuredClone(pkg)
  bad.dshGo.contributes['composer.actions'][0].effect = { type: 'replace', text: 'x' }
  const badReport = checkManifest(bad, { dir })
  assert.ok(badReport.issues.some((i) => i.code === 'invalid-field'), 'a non-static effect is rejected')
})
