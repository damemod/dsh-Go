import assert from 'node:assert/strict'
import { test } from 'node:test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { LIMITS, TUNABLE } from '../lib/bridge/limits.js'

// contributions.schema.json 的 limits 段用 const 把协议常量又写了一遍。
// 桥 limits.js（经 sync-bridge 字节同步到 SDK vendored）才是单一事实源：
// 这里双向核对键集与值，任何一侧漂移都会让 CI 变红。
const dir = dirname(fileURLToPath(import.meta.url))
const schema = JSON.parse(readFileSync(join(dir, '../schema/contributions.schema.json'), 'utf8'))
const limitsDef = schema.$defs.limits.properties

// 提取 schema 里所有 const 叶子；键名含点（如 perPlugin 下的 'composer.actions'）视为字面
function schemaConsts(props) {
  const out = {}
  for (const [k, v] of Object.entries(props)) {
    if (v && typeof v === 'object' && 'const' in v) out[k] = v.const
    else if (v && typeof v === 'object' && v.properties) {
      for (const [sub, cv] of Object.entries(schemaConsts(v.properties))) out[`${k}.${sub}`] = cv
    }
  }
  return out
}

// 把桥 LIMITS 拍平成同样的点分路径
function flatten(obj) {
  const out = {}
  for (const [k, v] of Object.entries(obj)) {
    if (v && typeof v === 'object') {
      for (const [sub, fv] of Object.entries(flatten(v))) out[`${k}.${sub}`] = fv
    } else out[k] = v
  }
  return out
}

test('contributions.schema.json limits consts mirror bridge LIMITS (SSOT)', () => {
  const schemaConst = schemaConsts(limitsDef)
  const bridgeFlat = flatten(LIMITS)

  // 六项计时是可配置的生效值，schema 用 type:number + default，不是 const
  const expected = Object.keys(bridgeFlat).filter((k) => !TUNABLE.includes(k)).sort()
  assert.deepEqual(
    Object.keys(schemaConst).sort(), expected,
    'schema limits const 键集与桥 LIMITS 不一致（新增/删除需同步两侧）',
  )
  for (const k of expected) {
    assert.equal(schemaConst[k], bridgeFlat[k], `schema const ${k} 与桥 LIMITS 值不一致`)
  }
  // 六项计时的协议默认值以 default 形式又写了一遍，同样应对齐桥 LIMITS
  for (const k of TUNABLE) {
    assert.ok(!(k in schemaConst), `${k} 是可调生效值，不能写成 const`)
    assert.equal(
      limitsDef[k] && limitsDef[k].default, LIMITS[k],
      `${k} 的 schema default 与桥 LIMITS 协议默认值不一致`,
    )
  }
})
