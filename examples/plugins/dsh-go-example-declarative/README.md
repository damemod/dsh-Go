# 声明式示例插件

一个插件把四种声明式能力放在一起：

- **静态效果**：`write-list` 胶囊在清单里声明 `insert`，App 自己执行，不运行宿主代码；`insert-tool` 加号工具同理。
- **延后结果**：`polish-list` 先给出「正在润色」，随后把整理后的文字插入输入框；可以被取消。
- **工具结果卡**：`declarative_checklist` 工具通过 `presentationMeta` 返回 `dsh-go/view`，App 把清单画成原生卡片。
- **多席位组合**：胶囊、状态条、加号工具、对话操作、回合尾注、两个面板都在这一个插件里。

清单、视图和效果都在框架公布的限额内；没有改框架、桥、SDK 或 golden。

```sh
dsh plugin --profile web add /绝对路径/examples/plugins/dsh-go-example-declarative
```

自查：

```sh
npm test
npm run check -- --load --lang zh
```

测试用 `sdk/plugin-kit` 的测试宿主，覆盖清单校验、六个席位、静态效果、延后结果的完成 / 取消、状态条与尾注推送、面板视图预算、工具卡、无桥接主机以及损坏清单的拒绝。

MIT © DSH-TUI (ccch1mneyyy)。
