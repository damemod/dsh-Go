"""fork 身份不变量门禁：把 fork 相对上游的四项立场固化为 CI 断言。

背景：fork 长期手工吸收上游优化，且合并出口制度性关闭（不向上游提 PR、禁止外部
提交进 main）。当逐批收割上游改动时，若某批误把上游语义带回，CI 的既有检查不会
发现——因为在上游自己的测试里那些语义是「正确」的。本测试把 fork 的身份写成
fail-closed 断言，任何一项被改动即变红，强制复核。

四项身份（均为 fork 相对上游 main 的明确立场，见 STATUS.md / 裁决文档）：
  1. 遥测默认关闭（App 层 usage_stats.dart），且无升级邀请弹窗；
  2. replace / close 效果原语存在（fork 自研，上游从未实现）；
  3. limits SSOT 生成链一致（桥 limits.js 为唯一源，native_limits.g.dart 同步）；
  4. golden 接缝基线含 close 所有权硬约束（防 close 泄漏到静态/延后效果）。

只读：不修改任何工作区文件；--check 模式验证生成物新鲜度。
"""
from __future__ import annotations

import json
import pathlib
import re
import subprocess
import unittest

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent

USAGE_STATS = ROOT / "app" / "lib" / "usage" / "usage_stats.dart"
UPGRADE_NOTICE = ROOT / "app" / "lib" / "ui" / "shell" / "usage_upgrade_notice.dart"
EFFECTS_JS = ROOT / "runtime" / "bridge" / "dsh-go-bridge" / "lib" / "native" / "effects.js"
NATIVE_EFFECTS = ROOT / "app" / "lib" / "plugins" / "native" / "native_effects.dart"
LIMITS_JS = ROOT / "runtime" / "bridge" / "dsh-go-bridge" / "lib" / "native" / "limits.js"
GEN_LIMITS = ROOT / "scripts" / "gen-native-limits.mjs"
GOLDEN = ROOT / "golden" / "seam-baseline.json"


def _read(path: pathlib.Path) -> str:
    return path.read_text(encoding="utf-8")


class ForkInvariantTests(unittest.TestCase):
    # ---- 身份 1：遥测默认关 + 无升级弹窗 ----

    def test_telemetry_default_enabled_false(self):
        """UsageStatsState.enabled 默认必须为 false（fork 裁决 3a4d4611）。"""
        src = _read(USAGE_STATS)
        self.assertRegex(
            src,
            r"const\s+UsageStatsState\s*\(\s*\{\s*this\.loaded\s*=\s*false\s*,\s*"
            r"this\.enabled\s*=\s*false\s*,\s*this\.noticed\s*=\s*false\s*\}\s*\)",
            "UsageStatsState 的 enabled 默认不再是 false（上游默认开被带回？）",
        )

    def test_telemetry_pref_default_false(self):
        """读取偏好开关时，缺键默认必须为 false（?? false）。"""
        src = _read(USAGE_STATS)
        self.assertRegex(
            src,
            r"getBool\(enabledKey\)\s*\?\?\s*false",
            "usage_stats 读取 enabledKey 的缺省值不再是 false",
        )

    def test_telemetry_collecting_keeps_noticed_gate(self):
        """collecting 必须保留 noticed 门控（fork 被动 opt-in 立场）。"""
        src = _read(USAGE_STATS)
        self.assertRegex(
            src,
            r"bool\s+get\s+collecting\s*=>\s*loaded\s*&&\s*enabled\s*&&\s*noticed",
            "collecting 丢了 noticed 门控（上游去门控语义被带回？）",
        )

    def test_no_upgrade_notice_file(self):
        """fork 已删除升级邀请弹窗；该文件不得重新出现。"""
        self.assertFalse(
            UPGRADE_NOTICE.exists(),
            "usage_upgrade_notice.dart 重新出现（fork 3a4d4611 已删除该弹窗）",
        )

    # ---- 身份 2：replace / close 效果原语 ----

    def test_bridge_effect_types_include_replace_and_close(self):
        """桥的 ALL_TYPES 与 SHORTHAND 必须都含 replace 与 close。"""
        src = _read(EFFECTS_JS)
        m = re.search(r"export\s+const\s+ALL_TYPES\s*=\s*new\s+Set\(\[([^\]]*)\]\)", src)
        self.assertIsNotNone(m, "effects.js 中找不到 ALL_TYPES 定义")
        for word in ("replace", "close"):
            self.assertIn('"%s"' % word, m.group(1), "ALL_TYPES 缺少 %s" % word)
        m = re.search(r"const\s+SHORTHAND\s*=\s*\[([^\]]*)\]", src)
        self.assertIsNotNone(m, "effects.js 中找不到 SHORTHAND 定义")
        for word in ("replace", "close"):
            self.assertIn('"%s"' % word, m.group(1), "SHORTHAND 缺少 %s" % word)

    def test_dart_effect_classes_replace_and_close(self):
        """App 侧必须有 ReplaceEffect 与 CloseEffect 解析类。"""
        src = _read(NATIVE_EFFECTS)
        for cls in ("ReplaceEffect", "CloseEffect"):
            self.assertRegex(
                src,
                r"final\s+class\s+%s\s+extends\s+NativeEffect" % cls,
                "native_effects.dart 缺少 %s 类" % cls,
            )

    # ---- 身份 3：limits SSOT 生成链 ----

    def test_limits_ssot_source_is_bridge(self):
        """SSOT 声明必须指向桥 limits.js，且该文件存在、PROTOCOL 为 1。"""
        gen = _read(GEN_LIMITS)
        self.assertIn("runtime/bridge/dsh-go-bridge/lib/native/limits.js", gen,
                      "生成脚本不再以桥 limits.js 为唯一源")
        self.assertIn("--check", gen, "生成脚本缺少 --check 模式")
        src = _read(LIMITS_JS)
        self.assertRegex(src, r"export\s+const\s+PROTOCOL\s*=\s*1\s*;",
                         "limits.js 的 PROTOCOL 不再是 1")

    def test_generated_limits_are_fresh(self):
        """native_limits.g.dart 必须与桥 limits.js 同步（--check exit 0）。"""
        proc = subprocess.run(
            ["node", str(GEN_LIMITS), "--check"],
            cwd=str(ROOT), capture_output=True, text=True, timeout=60,
        )
        self.assertEqual(
            proc.returncode, 0,
            "limits SSOT 生成物过期：%s %s" % (proc.stdout.strip(), proc.stderr.strip()),
        )

    # ---- 身份 4：golden 接缝基线含 close 所有权约束 ----

    def test_golden_has_close_ownership_guard(self):
        """golden 的 sourceGuards.closeOwnPanel 必须为 true（防 close 泄漏硬约束）。"""
        data = json.loads(_read(GOLDEN))
        guards = data.get("sourceGuards")
        self.assertIsInstance(guards, dict, "golden 的 sourceGuards 不是预期的 dict 结构")
        self.assertIs(
            guards.get("closeOwnPanel"), True,
            "golden sourceGuards.closeOwnPanel 不再为 true（close 所有权硬约束被放宽？）",
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
