#!/usr/bin/env node
// Generates the app-side native limits that mirror the bridge's protocol table.
// Single source of truth: runtime/bridge/dsh-go-bridge/lib/native/limits.js LIMITS.
//
//   node scripts/gen-native-limits.mjs           write app/lib/plugins/native/native_limits.g.dart
//   node scripts/gen-native-limits.mjs --check   exit 1 when the output is out of date
//
// Only the value-mirroring constants are generated here. App-derived totals
// (capsulesTotal/toolsTotal/turnNotesShown/turnNoteFeeds) and the App-only
// gesture window (tapWindow) stay hand-written in native_model.dart.
import { readFileSync, writeFileSync, existsSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const root = join(here, '..')
const limitsUrl = pathToFileURL(
  join(root, 'runtime/bridge/dsh-go-bridge/lib/native/limits.js'),
).href
const { LIMITS } = await import(limitsUrl)
const output = join(root, 'app/lib/plugins/native/native_limits.g.dart')

// actionsPerPlugin is applied to all four action surfaces in native_model.dart's
// actions(), so the bridge values must agree or a single mirror value is a lie.
const ACTION_SURFACES = ['composer.actions', 'message.actions', 'composer.tools', 'session.actions']
const actionValues = ACTION_SURFACES.map((s) => LIMITS.perPlugin[s])
if (!actionValues.every((v) => v === actionValues[0])) {
  throw new Error(`perPlugin action surfaces disagree: ${ACTION_SURFACES.map((s) => `${s}=${LIMITS.perPlugin[s]}`).join(', ')}`)
}
// menuLabelMax labels both message.actions and session.actions.
if (LIMITS.textChars.messageAction !== LIMITS.textChars.sessionAction) {
  throw new Error(`textChars.messageAction(${LIMITS.textChars.messageAction}) != sessionAction(${LIMITS.textChars.sessionAction})`)
}

const values = {
  actionsPerPlugin: actionValues[0],
  capsuleLabelMax: LIMITS.textChars.composerAction,
  menuLabelMax: LIMITS.textChars.messageAction,
  panelTitleMax: LIMITS.textChars.panelTitle,
  toolLabelMax: LIMITS.textChars.composerTool,
  panelsPerPlugin: LIMITS.perPlugin.panels,
  stripTextMax: LIMITS.textChars.stripText,
  toastMax: LIMITS.textChars.toast,
  copyMax: LIMITS.copyChars,
  stripPerPlugin: LIMITS.perPlugin['composer.strip'],
  turnNotePerPlugin: LIMITS.perPlugin['turn.note'],
}

const lines = [
  '// GENERATED FILE — do not edit by hand.',
  '// Regenerate: node scripts/gen-native-limits.mjs',
  '// Source: runtime/bridge/dsh-go-bridge/lib/native/limits.js (LIMITS)',
  'abstract final class GeneratedNativeLimits {',
]
for (const [name, value] of Object.entries(values)) {
  if (!Number.isInteger(value)) throw new Error(`${name} is not an integer: ${value}`)
  lines.push(`  static const int ${name} = ${value};`)
}
lines.push('}', '')
const content = lines.join('\n')

if (process.argv.includes('--check')) {
  const current = existsSync(output) ? readFileSync(output, 'utf8') : null
  if (current !== content) {
    console.error('native_limits.g.dart is out of date. Run: node scripts/gen-native-limits.mjs')
    process.exit(1)
  }
  console.log('native_limits.g.dart is in sync')
} else {
  writeFileSync(output, content)
  console.log(`wrote ${output}`)
}
