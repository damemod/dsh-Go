#!/usr/bin/env node
// 原生接缝安全快照：从上游 checkout 的桥源码读取安全常量，并对导出的桥函数
// 做行为探针，产出规范化 JSON。供生成 golden 基线、以及运行期对比使用。
//
// 探针分两类：
//  1. 行为探针（默认）：直接 import 桥模块，用精心构造的输入调用导出函数，
//     断言返回的 code / violation / effect 字段。只要语义被放松而文本保留，
//     行为就会变化，探针即翻假；文本正则无法做到这一点。
//  2. 源码探针（仅 routes.js 两处）：userGesture 传值发生在 HTTP 路由内联表达式，
//     没有导出行为入口（要覆盖它必须重建整台 HTTP 宿主 + 插件 + 会话）。
//     对这两处使用严格结构提取：枚举全部相关调用行，逐行取出完整表达式与规范式
//     做全等比较，任一行不符即翻假。首匹配 find() 与子串正则会被诱饵注释或
//     追加 `&& false` 绕过，因此不使用；附加 `|| true` 之类放松同样翻假。
//
// source 段仅记录基线来源（commit / tag），由 check_seam_security.py 在对比时忽略。
//
// 用法: node scripts/seam-snapshot.mjs <上游源码目录>
import { pathToFileURL } from "node:url";
import { execFileSync } from "node:child_process";
import path from "node:path";
import fs from "node:fs";
import * as acorn from "./vendor/acorn.mjs"; // acorn 8.19.0 (MIT)，固定随仓库提供

const upstream = process.argv[2];
if (!upstream) {
  console.error("用法: node seam-snapshot.mjs <上游源码目录>");
  process.exit(2);
}
const nativeDir = path.join(upstream, "runtime/bridge/dsh-go-bridge/lib/native");
const mod = (f) => pathToFileURL(path.join(nativeDir, f)).href;
const read = (f) => {
  const p = path.join(nativeDir, f);
  if (!fs.existsSync(p)) throw new Error(`缺少桥源文件: ${p}`);
  return fs.readFileSync(p, "utf8");
};

const limits = await import(mod("limits.js"));
const effects = await import(mod("effects.js"));
const caps = await import(mod("capabilities.js"));
const { NativeCore } = await import(mod("core.js"));

const git = (...args) => {
  try {
    return execFileSync("git", ["-C", upstream, ...args], {
      encoding: "utf8", stdio: ["ignore", "pipe", "ignore"],
    }).trim();
  } catch {
    return null;
  }
};

const opts = () => ({ panels: new Set() });
const guard = (fn) => {
  try { return fn() === true; } catch { return false; }
};
const badViolation = (r) => r?.issue?.code === "bad-effect"
  && r.issue.violation === true && r.effect === undefined;
const unknownNoViolation = (r) => r?.issue?.code === "unknown-effect"
  && r.issue.violation === false && r.effect === undefined;
const lines = (s) => s.split("\n");

// ---------------------------------------------------------------- 行为探针

const sourceGuards = {
  // 原生 command 永远不能选权限预设。同时走 validate 与 normalize 两条入口。
  permissionHardDeny: guard(() => {
    const inputs = [
      { type: "command", name: "permission" },
      { type: "command", name: "permission", args: "read-only" },
    ];
    const direct = inputs.every((e) => {
      const r = effects.validate(e, opts());
      return badViolation(r) && /permission/i.test(r.issue.message);
    });
    const viaNormalize = effects.normalize({ command: { name: "permission" } }, opts());
    return direct && viaNormalize.violation === true && viaNormalize.effects.length === 0
      && viaNormalize.issues.every((i) => i.code === "bad-effect");
  }),

  // link.url 只接受 https；http/ftp/data 必须被拒，https 必须放行。
  linkHttpsOnly: guard(() => {
    const rejected = ["http://example.com", "ftp://example.com", "data:text/plain,hi"]
      .every((url) => badViolation(effects.validate({ type: "link", url }, opts())));
    const ok = effects.validate({ type: "link", url: "https://example.com" }, opts());
    return rejected && ok.effect?.type === "link" && ok.issue === undefined;
  }),

  // link.url 不得携带任一凭据：单独用户名、单独密码、用户名+密码都被拒。
  linkNoCredentials: guard(() => {
    const rejected = [
      "https://user@example.com",
      "https://:pass@example.com",
      "https://user:pass@example.com",
    ].every((url) => {
      const r = effects.validate({ type: "link", url }, opts());
      return badViolation(r) && /credential/i.test(r.issue.message);
    });
    const ok = effects.validate({ type: "link", url: "https://example.com" }, opts());
    return rejected && ok.effect?.type === "link" && ok.issue === undefined;
  }),

  // effects.js 的未知 effect：记 issue 但不计违规（v1 兼容基石）。
  unknownEffectNoViolation: guard(() => {
    const r = effects.validate({ type: "exec" }, opts());
    const n = effects.normalize([{ type: "exec" }, { type: "noop" }], opts());
    return unknownNoViolation(r) && n.violation === false && n.effects.length === 0
      && n.issues.length === 2 && n.issues.every((i) => i.code === "unknown-effect");
  }),

  // close 能关闭 UI，ownership 是它的安全边界：id 或 tap source 必须命中本插件
  // 声明的 panel；无来源、别人的 panel、静态 / 延后 / 文件回调一律硬拒。
  // 这是行为探针而非文本断言：ownership 若被放松成恒真，本探针即翻假。
  closeOwnPanel: guard(() => {
    const panels = new Set(["usage"]);
    const good = effects.validate({ type: "close", id: "usage" }, { panels }).effect?.id === "usage"
      && effects.validate({ type: "close" }, { panels, source: "usage" }).effect?.id === "usage"
      && effects.normalize({ close: "usage" }, { panels }).effects[0]?.id === "usage";
    const rejected = [
      effects.validate({ type: "close" }, { panels }),
      effects.validate({ type: "close", id: "foreign" }, { panels }),
      effects.validate({ type: "close", id: "usage" }, { panels, static: true }),
      effects.validate({ type: "close", id: "usage" }, { panels, deferred: true }),
      effects.validate({ type: "close", id: "usage" }, { panels, fileResult: true }),
    ].every((r) => r.issue?.violation === true);
    return good && rejected;
  }),

  // capabilities.js:131 capabilityEffect 的 unknown()：未声明或未协商都不得计违规。
  capabilityEffectUnknownNoViolation: guard(() => {
    return [
      caps.capabilityEffect({ type: "audio", op: "play" }, {}),
      caps.capabilityEffect({ type: "audio", op: "play" },
        { capabilities: { declared: ["audio"], features: [] } }),
    ].every(unknownNoViolation);
  }),

  // capabilities.js:161 pickerEffect 的 unknown()：未声明或未协商都不得计违规。
  pickerEffectUnknownNoViolation: guard(() => {
    return [
      caps.pickerEffect({ type: "pickFile", action: "cb" }, { userGesture: true }),
      caps.pickerEffect({ type: "pickFile", action: "cb" },
        { capabilities: { declared: ["files"], features: [] }, userGesture: true }),
    ].every(unknownNoViolation);
  }),

  // 文件选择必须显式点按：false / undefined / 字符串 "true" 都不得通过；true 放行。
  // 同时验证 validate 的分派路径，避免只改分派表而绕过 pickerEffect 本体。
  pickerUserGesture: guard(() => {
    const good = { capabilities: { declared: ["files"], features: ["files"] } };
    const rejected = [false, undefined, "true"].every((ug) => {
      const r = caps.pickerEffect({ type: "pickFile", action: "cb" },
        { ...good, userGesture: ug });
      return badViolation(r) && /gesture/i.test(r.issue.message);
    });
    const viaValidate = effects.validate({ type: "pickFile", action: "cb" },
      { ...good, userGesture: false });
    const ok = caps.pickerEffect({ type: "pickFile", action: "cb" },
      { ...good, userGesture: true });
    return rejected && badViolation(viaValidate) && ok.effect?.type === "pickFile"
      && ok.issue === undefined;
  }),

  // 违规累计到阈值即降级：core.js 的 NativeCore.violation / success / health
  // 都是公开实例成员，构成真实行为入口，无需源码探针。
  // 上限 32：阈值被放大到异常值时直接翻假，避免探针自身做百万次循环。
  degradeAtThreshold: guard(() => {
    const n = limits.LIMITS.violationsToDegrade;
    if (!Number.isInteger(n) || n < 1 || n > 32) return false;
    const pkg = "seam-probe";
    const run = (totalViolations) => {
      const c = new NativeCore({}, limits.LIMITS, "seam-probe");
      try {
        for (let i = 1; i <= totalViolations; i++) {
          c.violation(pkg, "probe", "probe");
          const degraded = c.health.get(pkg)?.degraded === true;
          if (degraded !== (i >= n)) return false;
        }
        return c.health.get(pkg)?.degraded === true;
      } finally {
        c.dispose();
      }
    };
    const oneShort = (() => {
      const c = new NativeCore({}, limits.LIMITS, "seam-probe");
      try {
        for (let i = 1; i <= n - 1; i++) c.violation(pkg, "probe", "probe");
        return c.health.get(pkg)?.degraded === false;
      } finally {
        c.dispose();
      }
    })();
    // success 重置：累计 n-1 次 → success → 再 n-1 次仍不得降级，第 n 次才降级
    const reset = (() => {
      const c = new NativeCore({}, limits.LIMITS, "seam-probe");
      try {
        for (let i = 1; i <= n - 1; i++) c.violation(pkg, "probe", "probe");
        c.success(pkg);
        for (let i = 1; i <= n - 1; i++) {
          c.violation(pkg, "probe", "probe");
          if (c.health.get(pkg)?.degraded === true) return false;
        }
        c.violation(pkg, "probe", "probe");
        return c.health.get(pkg)?.degraded === true;
      } finally {
        c.dispose();
      }
    })();
    return oneShort && reset && run(n);
  }),
};

// ---------------------------------------------------------------- 源码探针（AST）
// routes.js:366 与 :293 没有可调用的导出行为入口；用 acorn 解析为 AST 做结构化断言。
// 文本正则会被构造性写法绕过（对象重复键、双 if、字符串里的 //、追加短路），
// AST 只看真实语法结构：注释/字符串不是代码，重复键与复合条件都如实呈现。

const routes = read("routes.js");
const routesAst = acorn.parse(routes, {
  ecmaVersion: 2024, sourceType: "module", allowAwaitOutsideFunction: true,
});
const nodeSrc = (n) => routes.slice(n.start, n.end);
function walkAst(node, visit) {
  if (!node || typeof node !== "object") return;
  if (typeof node.type === "string") visit(node);
  for (const k of Object.keys(node)) {
    if (k === "start" || k === "end" || k === "loc" || k === "range") continue;
    const v = node[k];
    if (Array.isArray(v)) v.forEach((x) => walkAst(x, visit));
    else if (v && typeof v === "object") walkAst(v, visit);
  }
}
const isNamed = (node, name) => node?.type === "Property"
  && (node.key.name === name || node.key.value === name);

// B2：所有 invoke 路径（参数对象含 capabilities）的 normalizeEffects 调用，
// 其 userGesture 属性必须恰好一个、非简写、右式源码等于规范式。重复键会被
// count!==1 抓住；追加 || true / 改 true / !!x 会被右式全等比较抓住。
const UG_CANON = "body.userGesture === true";
const ugChecks = [];
walkAst(routesAst, (n) => {
  if (n.type !== "CallExpression" || n.callee?.name !== "normalizeEffects") return;
  const arg = n.arguments?.[1];
  if (!arg || arg.type !== "ObjectExpression") return;
  if (!arg.properties.some((p) => isNamed(p, "capabilities"))) return;
  const ugProps = arg.properties.filter((p) => isNamed(p, "userGesture"));
  ugChecks.push({
    count: ugProps.length,
    value: ugProps.length === 1 ? nodeSrc(ugProps[0].value) : null,
    shorthand: ugProps.length === 1 ? ugProps[0].shorthand : null,
  });
});
sourceGuards.routesUserGesturePassthrough = ugChecks.length > 0
  && ugChecks.every((c) => c.count === 1 && c.value === UG_CANON && !c.shorthand);

// B1：所有条件源码等于规范式的 if 语句，其 consequent 必须恰好调用一次 fail。
// 追加 && false 使条件不再是规范式（不再被识别为检查）；双 if 使规范 if 的
// failCount=0；删 fail 同样 count=0。三者均翻假。
const TYPE_CANON = 'body.userGesture !== undefined && typeof body.userGesture !== "boolean"';
const typeChecks = [];
walkAst(routesAst, (n) => {
  if (n.type !== "IfStatement" || nodeSrc(n.test) !== TYPE_CANON) return;
  let failCount = 0;
  walkAst(n.consequent, (c) => {
    if (c.type === "CallExpression" && c.callee?.name === "fail") failCount++;
  });
  typeChecks.push(failCount);
});
sourceGuards.routesUserGestureTypeCheck = typeChecks.length > 0
  && typeChecks.every((c) => c === 1);

// ---------------------------------------------------------------- 快照组装

const snapshot = {
  schema: 2,
  source: {
    commit: git("rev-parse", "HEAD"),
    tag: git("describe", "--tags", "--always"),
  },
  protocol: limits.PROTOCOL,
  effects: {
    static: [...effects.STATIC_TYPES].sort(),
    all: [...effects.ALL_TYPES].sort(),
    deferred: [...effects.DEFERRED_TYPES].sort(),
    effectFeatures: [...caps.EFFECT_FEATURES].sort(),
    pickerTypes: [...caps.PICKER_TYPES].sort(),
  },
  capabilities: {
    features: [...caps.FEATURES].sort(),
    capEvents: Object.keys(caps.CAP_EVENTS).sort(),
    terminalEvents: [...caps.TERMINAL_EVENTS].sort(),
  },
  // scope 只允许 id 类键；出现原文类键即为泄漏面扩大
  scopeKeys: [...limits.SCOPE_KEYS].sort(),
  // 整对象导出：任何数值字段（含 insertChars / copyChars / stream 系列）变动都进入对比
  limits: { ...limits.LIMITS },
  // 能力预算与文件选择预算整对象导出
  capLimits: { ...caps.CAP_LIMITS },
  fileLimits: { ...caps.FILE_LIMITS },
  sourceGuards,
};

process.stdout.write(JSON.stringify(snapshot, null, 2) + "\n");
