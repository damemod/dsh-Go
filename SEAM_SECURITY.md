# 原生接缝安全门禁（定义侧）

本仓库 `damemod/dsh-Go` 是原生插件接缝的**定义侧**：effect 白名单、scope 键、
LIMITS 预算和行为硬红线都定义在 `runtime/bridge/dsh-go-bridge/lib/native/`。
本门禁对该定义做「快照 vs golden」校验，任何安全不变量被放松即拒绝，是接缝
安全的主防线，不向任何上游仓库提出变更。

## 1. 文件

```
.github/workflows/seam-security.yml    # PR / push:main / 定时 / 手动 触发
scripts/seam-snapshot.mjs              # 快照：import 桥模块做行为探针 + routes.js AST 探针
scripts/vendor/acorn.mjs               # acorn 8.19.0 (MIT)，AST 探针用，固定随仓库提供
scripts/vendor/LICENSE.acorn           # acorn 许可
scripts/check_seam_security.py         # 门禁：快照与 golden 逐项对比，fail-closed
golden/seam-baseline.json              # 安全基线，来源 v1.2.0 (c1a84e3)
tests/test_seam_security_gate.py       # 意图驱动变异测试（34 例）
SEAM_SECURITY.md                       # 本文件
```

本仓库是干净 fork，不含 Dharness 的 `apply_autonomous.py` 补丁脚本；锚点预算
门禁（防功能专用持久补丁）属于发版工程链，不在此仓库落地。

## 2. 守什么

golden 全部常量取自 v1.2.0 (`c1a84e3f833ad59ff07a5027994dae3935907a2d`) 真实源码：

- `protocol = 1`（`limits.js:3`）；
- effect 白名单：static/all/deferred（`effects.js:7-10`）、effectFeatures / pickerTypes
  （`capabilities.js:9-10`）；
- capabilities：features / capEvents / terminalEvents（`capabilities.js:7,25-31`）；
- `scopeKeys = [sessionId, turnId, messageId, callId]`（`limits.js:73`，仅 id 类键，
  无原文键）；
- `LIMITS` 44 字段、`CAP_LIMITS` 13 字段、`FILE_LIMITS` 8 字段整对象导出，任何
  数值变动都进入对比。

行为探针与路由源码探针共 10 项（`sourceGuards`）：permission 硬拒、link 仅 https、
URL 无凭据、未知 effect 不计违规（v1 兼容基石）、capability/picker 的 unknown 不
计违规、文件选择需用户点按、违规达阈值降级，以及两处 `routes.js` userGesture
传值/类型检查。任一项不为 true 即 `[HARD]` 拒绝。

## 3. 判定方向

- 数值变大（release 预算、降级阈值等）= 防御放松 → 报「放宽」；
- 白名单新增项 = 攻击面扩大 → 报「扩大/变更」；
- `scopeKeys` / `protocol` / 任一 `sourceGuards` = HARD，变化直接拒绝；
- 任何差异退出码 1（fail-closed），强制人工复核并显式更新 golden。

## 4. 上游 tag 更新时的处理

`check_seam_security.py` 报差异时：

1. 新增 view 组件：本快照不含组件清单，不报差异。
2. effect 白名单 / limits 真被放松：默认不跟进该 tag；在上游提 issue/PR 收回，
   或在自有分支打补丁收紧。若确为安全改进（阈值调小），人工确认后更新 golden 并附理由。
3. `sourceGuards` 失守：`[HARD]`，禁止更新 golden 放行，先修源码或固定补丁。
4. `scopeKeys` 变化：新增原文类键按 2 处理；仅 id 类键扩展需人工确认。

更新 golden：确认安全后重新生成并逐项 diff，理由随提交记录，不得只为让 CI 变绿。

```
node scripts/seam-snapshot.mjs . > golden/seam-baseline.json
```

## 5. 边界与威胁模型

本门禁定位为**防漂移**：上游同步或发版时，桥的安全不变量被无意改动、或未经审视合入，快照对比即报警，强制人工 review 并显式更新 golden 后才恢复通过。它防的是「没 review 就变了」，不是「禁止合法变更」。不定位为防蓄意源码篡改：能改桥源码者同样能改 golden 与门禁本身，静态分析也无法判定语义等价，故此类防护由分支保护、代码审查、签名与最小权限承担。

- 本门禁检查「可直接观测的安全常量 / 白名单 / 行为探针」，不保证新增组件符合架构意图。
- 两处 `routes.js` userGesture 无导出行为入口，用 acorn AST 结构化断言：`normalizeEffects` 参数对象的 `userGesture` 必须恰好一个、非简写、右式为 `body.userGesture === true`；类型检查 if 的条件为规范式且恰好一次 `fail()`。对象重复键、双 if、追加 `&& false`/`|| true` 均翻假；注释与字符串字面量不参与语法，不会造成误报或漏判。桥文件大幅重构时需复核断言。
- acorn 8.19.0 (MIT) 以单文件 vendor 在仓库内，SHA-256 `76254fc76529713b4dfd2532972d17a991ffd9aafeebb1f977445b5506b9fb0b`，不依赖网络安装。
- 变异测试覆盖已列放松形态，不等于对所有语义放松的证明。
- routes 两处探针的已知局限：死代码诱饵、spread 后置覆盖、callee 别名、标识符计算键、不可达 fail 等构造可使断言被满足而真实语义已放松。这些属于蓄意源码篡改手法，正常漂移不会产生；userGesture 的实际安全语义由 `capabilities.js` 的 `pickerEffect()` 行为探针覆盖，routes 两行只是请求值到该函数的传值管道。发现此类写法应走人工审查，不依赖本门禁拦截。
- 完整编译与真机验证需 Flutter toolchain（本机 proot 无）。
