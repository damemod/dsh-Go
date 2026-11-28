// Static view for the overview panel. Built from v1 core nodes so it renders on
// every app that speaks protocol v1; the guide panel shows the v2 variants.
export function overviewView() {
  return {
    type: 'stack',
    title: '四种声明式能力',
    children: [
      { type: 'text', text: '本示例只用现成的清单声明与桥接接口，不新增框架能力。' },
      {
        type: 'list',
        items: [
          { title: '静态效果', subtitle: '写清单、插入模板：清单声明，App 直接执行' },
          { title: '延后结果', subtitle: '润色清单：先给等待提示，稍后回填' },
          { title: '工具结果卡', subtitle: '工具返回 presentationMeta，绘成原生卡片' },
          { title: '多席位组合', subtitle: '胶囊、状态条、加号工具、对话操作、回合尾注' },
        ],
      },
      {
        type: 'steps',
        items: [
          { label: '选一个入口', status: 'current', detail: '胶囊、加号或状态条' },
          { label: '看回填结果', status: 'todo', detail: '延后效果与工具卡' },
        ],
      },
    ],
  }
}
