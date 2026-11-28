// dsh-go-example-declarative: four declarative capabilities in one plugin.
//
//   静态效果      composer.actions / composer.tools declare an effect; the app runs it with no host code
//   延后结果      on("polish-list") returns pending + a result that lands in the composer later
//   工具结果卡    a registered tool returns presentationMeta; the app draws the "dsh-go/view" card
//   多席位组合    capsule, status strip, plus-panel tools, chat action, turn note and panels
//
// Every effect and seat stays within the framework's published limits: two capsule actions, two
// plus-panel tools, two panels, one strip, one chat action, one turn note, two effects per invoke.
// Nothing here changes the framework, the bridge, the SDK or the golden files.
import { defineTool } from '@deepseek-ai/dsh-tools'
import { overviewView } from './view.js'

export const name = 'dsh-go-example-declarative'
export const inject = ['tools']

const CARD_MAX_BYTES = 8 * 1024

// Same shape as toolCard() in @dsh-go/plugin-kit: catch, round-trip through JSON,
// cap the size, and fall back to no card rather than failing the whole tool call.
function toolCard(build) {
  return (args, value) => {
    try {
      const view = build(args, value)
      if (view === undefined || view === null) return {}
      const text = JSON.stringify(view)
      if (text === undefined || Buffer.byteLength(text, 'utf8') > CARD_MAX_BYTES) return {}
      return { 'dsh-go/view': JSON.parse(text) }
    } catch {
      return {}
    }
  }
}

// Deferred work takes a moment and can be cancelled mid-flight.
function pause(ms, signal) {
  return new Promise((resolve) => {
    if (signal?.aborted) return resolve()
    const timer = setTimeout(() => {
      signal?.removeEventListener('abort', onAbort)
      resolve()
    }, ms)
    function onAbort() {
      clearTimeout(timer)
      resolve()
    }
    signal?.addEventListener('abort', onAbort, { once: true })
  })
}

function checklistCard(_args, value) {
  if (!Array.isArray(value?.items)) return undefined
  const items = value.items.slice(0, 6)
  return {
    type: 'stack',
    title: '清单卡',
    children: [
      { type: 'text', text: '这份清单共 ' + items.length + ' 项' },
      {
        type: 'list',
        items: items.map((item) => ({ title: typeof item === 'string' ? item : String(item?.text ?? '') })),
      },
    ],
  }
}

export function apply(ctx) {
  ctx.tools.register(defineTool({
    name: 'declarative_checklist',
    description:
      'Turn a short topic into a numbered checklist and show it as a native card. ' +
      'The user sees the result as a card, so keep the model text short.',
    parameters: {
      topic: { type: 'string', required: true, description: 'What the checklist is about.' },
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        properties: {
          topic: { type: 'string', required: true },
          items: { type: 'array', required: true, items: { type: 'string' } },
        },
      },
      render: (_args, value) => [{ type: 'text', text: '清单：' + (value?.items ?? []).join('、') }],
      presentationMeta: toolCard(checklistCard),
    },
    timeoutMs: 30000,
    isConcurrencySafe: () => true,
    execute: (args) => ({ topic: String(args?.topic ?? ''), items: ['明确目标', '列出步骤', '检查结果'] }),
  }))

  // A host that only loads tools (no dshGo bridge) still gets the tool above.
  if (typeof ctx.inject !== 'function') return
  ctx.inject(['dshGo'], (ctx) => {
    const marked = new Set()

    // 延后结果: acknowledge at once, then insert the polished text later.
    ctx.dshGo.on('polish-list', (scope) => ({
      pending: { label: '正在润色', timeoutMs: 60000 },
      result: async (signal) => {
        await pause(20, signal)
        if (signal?.aborted) return {}
        const draft = typeof scope?.draft === 'string' ? scope.draft.trim() : ''
        return draft === ''
          ? { toast: '输入框里还没有清单' }
          : { insert: '把下面的清单润色得更清楚，保持原来的项数：\n\n' + draft }
      },
    }))

    ctx.dshGo.on('mark', (scope) => {
      marked.add(scope.sessionId)
      ctx.dshGo.refresh('overview')
      return { toast: '已标记这段对话' }
    })

    // A turn note pushes a short line at the end of each turn.
    if (typeof ctx.dshGo.turnNote === 'function') {
      ctx.dshGo.turnNote('turn', (scope, emit) => {
        emit({ 1: { text: '声明式' } })
        return () => {}
      })
    }

    // A live status strip: emits a short caption and stays in sync with the panel.
    ctx.dshGo.strip('status', (scope, emit, caps) => {
      emit({ text: caps.locale === 'en-US' ? 'Demo ready' : '示例就绪' })
      return () => {}
    })

    ctx.dshGo.panel('overview', {
      view: (scope, caps) => ({
        ...overviewView(),
        children: [
          ...overviewView().children,
          { type: 'metric', label: '已标记对话', value: String(marked.size) },
          ...(caps.surfaces?.includes('session.actions') ? [] : [{ type: 'callout', tone: 'info', text: '更新 App 后可在右侧栏标记对话。' }]),
        ],
      }),
      actions: {
        openGuide: () => ({ open: 'panel:guide' }),
      },
    })

    ctx.dshGo.panel('guide', {
      view: {
        v: 2,
        type: 'stack',
        title: '声明式能力说明',
        accent: 'app',
        children: [
          { type: 'text', text: '清单里写一次，App 直接执行。', style: { size: 'subtitle', weight: 'bold' } },
          { type: 'badge', text: '静态效果', tone: 'info' },
          { type: 'badge', text: '延后结果', tone: 'good' },
          { type: 'badge', text: '工具结果卡', tone: 'info' },
          { type: 'callout', tone: 'info', text: '全部是框架现成能力，本示例只负责把它们放在一起演示。' },
        ],
      },
    })
  })
}
