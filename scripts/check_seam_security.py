#!/usr/bin/env python3
"""原生接缝安全门禁：对比当前上游桥的接缝快照与 golden 基线，fail-closed。

设计依据：
  - effect 白名单是插件影响 UI 的唯一原生指令通道：放宽 = 攻击面扩大；
  - scope 只允许 id 类键（limits.js:73 SCOPE_KEYS）：出现原文类键 = 泄漏面扩大；
  - LIMITS / CAP_LIMITS / FILE_LIMITS 整对象导出：任何数值字段变动都需确认；
  - sourceGuards 是行为探针与两处路由源码探针：任何一条 false 立即拒绝；
  - 快照的 source 段只记录来源 commit/tag，不构成语义差异。

行为：
  - 快照与 golden 完全一致且所有 sourceGuards 为 true → exit 0；
  - 任何差异 → 逐条打印方向（放宽/收紧/变更），exit 1（fail-closed，强制复核 golden）；
  - 绝对红线被突破 → 标记 [HARD]，无论是否打算更新 golden 都必须先修复源码语义。

用法: python3 check_seam_security.py <上游源码目录> [--golden 路径]
"""
from __future__ import annotations

import json
import pathlib
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
DEFAULT_GOLDEN = HERE.parent / "golden" / "seam-baseline.json"

# 这些路径下的数值「变大」= 防御放松；「变小」= 收紧。WIDEN_IS_BAD 表示
# 数值增大是放松方向；其他预算仍视为任何变动都需复核（方向标 "变更"）。
NUMERIC_SECTIONS = ("limits.", "capLimits.", "fileLimits.")
WIDEN_IS_BAD_PATHS = {
    "limits.violationsToDegrade", "limits.effectWindowMs", "limits.manifestBytes",
    "limits.viewBytes", "limits.viewNodes", "limits.feeds", "limits.invokeBurst",
    "limits.invokePerSecond", "limits.invokeConcurrent", "limits.effectsPerInvoke",
    "limits.insertChars", "limits.copyChars", "limits.patchBytes", "limits.dataBytes",
    "limits.linkChars", "limits.commandArgsChars", "limits.invokeBytes",
    "limits.assetBytes", "limits.streamBacklogBytes", "limits.viewDepth",
    "limits.streamConnections", "limits.streamSubscriptions",
    "capLimits.leases", "capLimits.pluginLeases", "capLimits.eventBurst",
    "capLimits.eventsPerSecond", "capLimits.mediaBytes", "capLimits.microBytes",
    "capLimits.microSubs", "capLimits.pluginMicroSubs", "capLimits.perKind",
    "fileLimits.count", "fileLimits.bytes", "fileLimits.totalBytes",
    "fileLimits.cacheBytes", "fileLimits.requests", "fileLimits.nameChars",
}
WHITELIST_PATHS = {
    "effects.static", "effects.all", "effects.deferred",
    "effects.effectFeatures", "effects.pickerTypes",
}
HARD_ROOTS = {"scopeKeys", "protocol"}


def is_hard(path: str) -> bool:
    """叶子 sourceGuards.<name> 翻转同样是 [HARD]，而不是 [REVIEW]/未知。"""
    return path in HARD_ROOTS or path.startswith("sourceGuards")


def flatten(node, prefix=""):
    """把嵌套 dict 摊成 {点路径: 值}；list 作为整体值。"""
    out = {}
    if isinstance(node, dict):
        for k, v in node.items():
            out.update(flatten(v, f"{prefix}.{k}" if prefix else k))
    else:
        out[prefix] = node
    return out


def compare(golden, current):
    """返回差异列表 (path, old, new, hard, direction)。"""
    diffs = []
    all_keys = sorted(set(golden) | set(current))
    for k in all_keys:
        if k.startswith("source."):
            continue  # provenance only
        if k not in golden:
            diffs.append((k, "<不存在>", current[k], is_hard(k), "新增"))
            continue
        if k not in current:
            diffs.append((k, golden[k], "<不存在>", is_hard(k), "缺失"))
            continue
        old, new = golden[k], current[k]
        if isinstance(old, list) and isinstance(new, list):
            if old != new:
                added = [x for x in new if x not in old]
                removed = [x for x in old if x not in new]
                direction = "扩大/变更" if added else "缩小"
                diffs.append((k, old, new, is_hard(k), direction))
            continue
        if old != new:
            hard = is_hard(k)
            direction = "变更"
            if k.startswith("sourceGuards."):
                direction = "硬红线失守" if new is not True else "硬红线恢复"
            elif k.startswith(NUMERIC_SECTIONS) and isinstance(old, (int, float)) and isinstance(new, (int, float)):
                if k in WIDEN_IS_BAD_PATHS:
                    direction = "放宽(数值变大)" if new > old else "收紧"
                else:
                    direction = "数值变大" if new > old else "数值变小"
            diffs.append((k, old, new, hard, direction))
    return diffs


def main():
    args = sys.argv[1:]
    golden_path = DEFAULT_GOLDEN
    if "--golden" in args:
        i = args.index("--golden")
        if i + 1 >= len(args):
            sys.exit("用法错误: --golden 需跟路径")
        golden_path = pathlib.Path(args[i + 1])
        args = args[:i] + args[i + 2:]
    upstream = [a for a in args if not a.startswith("--")]
    if len(upstream) != 1:
        sys.exit("用法: check_seam_security.py <上游源码目录> [--golden 路径]")
    upstream = upstream[0]

    if not golden_path.is_file():
        sys.exit(f"缺少 golden 基线: {golden_path}")

    snap = HERE / "seam-snapshot.mjs"
    proc = subprocess.run(
        ["node", str(snap), upstream],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        print(proc.stderr, file=sys.stderr)
        sys.exit(f"快照脚本失败(rc={proc.returncode})——无法取到桥安全常量，拒绝放行")
    try:
        current = json.loads(proc.stdout)
    except json.JSONDecodeError as e:
        sys.exit(f"快照输出非合法 JSON: {e}")
    golden = json.loads(golden_path.read_text(encoding="utf-8"))

    print("=== 原生接缝安全门禁（fail-closed）===")
    print(f"golden: {golden_path}")
    guards = current.get("sourceGuards", {})
    bad_guards = [k for k, v in guards.items() if v is not True]
    if bad_guards:
        for g in bad_guards:
            print(f"[HARD] sourceGuards.{g} = {guards[g]}  ← 安全硬红线未命中/失守")
    else:
        print(f"[OK] {len(guards)} 项安全硬红线全部命中: {', '.join(sorted(guards))}")

    diffs = compare(flatten(golden), flatten(current))
    if not diffs and not bad_guards:
        print("结论：接缝安全快照与基线一致，放行。")
        return 0

    print(f"\n快照差异 {len(diffs)} 项（任何差异都需人工复核并显式更新 golden）：")
    hard_count = 0
    for path, old, new, hard, direction in diffs:
        tag = "HARD" if hard else "REVIEW"
        if hard:
            hard_count += 1
        o = json.dumps(old, ensure_ascii=False) if not isinstance(old, str) else old
        n = json.dumps(new, ensure_ascii=False) if not isinstance(new, str) else new
        print(f"  [{tag}] {path}: {o} -> {n}  ({direction})")
    print(f"\n结论：{len(diffs)} 项差异（其中 {hard_count} 项硬红线），拒绝放行。"
          " 复核确认安全后，用新上游重建 golden/seam-baseline.json 并提交。")
    return 1


if __name__ == "__main__":
    sys.exit(main())
