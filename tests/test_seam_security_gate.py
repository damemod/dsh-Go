#!/usr/bin/env python3
"""意图驱动回归测试：验证 check_seam_security.py 对安全放松 fail-closed。

覆盖复核报告 M2/M3/M4/M5/M6/D1/G1/G2/G3/P1b/P2/R1/X1/X2/X3 全部意图。
每个意图含多个场景、多条断言。变异只写入临时复制的 lib/native 子树，
真实 upstream checkout 不被修改。

运行: python3 -m unittest discover -s tests -p 'test_seam_security_gate.py'
"""
from __future__ import annotations

import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent
CHECKER = ROOT / "scripts" / "check_seam_security.py"
SNAPSHOT = ROOT / "scripts" / "seam-snapshot.mjs"
GOLDEN = ROOT / "golden" / "seam-baseline.json"
UPSTREAM = pathlib.Path(os.environ.get("DSH_UPSTREAM_SRC", "upstream"))
NATIVE = "runtime/bridge/dsh-go-bridge/lib/native"


def run_checker(upstream: pathlib.Path):
    return subprocess.run(
        ["python3", str(CHECKER), str(upstream)],
        capture_output=True, text=True,
    )


def run_snapshot(upstream: pathlib.Path):
    return subprocess.run(["node", str(SNAPSHOT), str(upstream)],
                          capture_output=True, text=True)


def snapshot(upstream: pathlib.Path) -> dict:
    p = run_snapshot(upstream)
    assert p.returncode == 0, p.stderr
    return json.loads(p.stdout)


class SeamGateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        assert UPSTREAM.is_dir(), f"上游源码不存在: {UPSTREAM}"
        assert GOLDEN.is_file(), f"golden 不存在: {GOLDEN}"
        base = snapshot(UPSTREAM)
        assert all(base["sourceGuards"].values()), (
            f"基线源码有探针未命中: {base['sourceGuards']}")
        golden_data = json.loads(GOLDEN.read_text(encoding="utf-8"))
        # source 段是 provenance，不参与语义对比；其余必须逐字段相等
        assert {k: v for k, v in base.items() if k != "source"} == \
               {k: v for k, v in golden_data.items() if k != "source"}, \
            "golden 与真实源码快照不一致"

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="seam-gate-test-")
        self.addCleanup(self._tmp.cleanup)
        self.copy = pathlib.Path(self._tmp.name) / "up"
        native_src = UPSTREAM / NATIVE
        native_dst = self.copy / NATIVE
        native_dst.mkdir(parents=True)
        for f in native_src.iterdir():
            if f.is_file():
                shutil.copy2(f, native_dst / f.name)

    def _native(self, name: str) -> pathlib.Path:
        return self.copy / NATIVE / name

    def _read(self, name: str) -> str:
        return self._native(name).read_text(encoding="utf-8")

    def _write(self, name: str, text: str) -> None:
        self._native(name).write_text(text, encoding="utf-8")

    def _replace(self, name: str, old: str, new: str, count: int = 1) -> None:
        text = self._read(name)
        self.assertIn(old, text, f"变异锚点不存在于 {name}: {old}")
        self._write(name, text.replace(old, new, count))

    def _assert_reject(self, *must_contain: str, hard: bool = True):
        r = run_checker(self.copy)
        combined = r.stdout + r.stderr
        self.assertNotEqual(r.returncode, 0,
                            f"门禁未拒绝安全放松:\n{combined}")
        for needle in must_contain:
            self.assertIn(needle, combined, f"拒绝输出缺少标记 {needle!r}:\n{combined}")
        if hard:
            self.assertIn("[HARD]", combined)
        return r

    def _guard(self, name: str):
        return snapshot(self.copy)["sourceGuards"][name]

    # ---------------------------------------------------------------- 正常路径

    def test_intent_clean_source_passes(self):
        r = run_checker(UPSTREAM)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("放行", r.stdout)
        self.assertIn("[OK] 10 项安全硬红线全部命中", r.stdout)

    # ---------------------------------------------------------------- M2 https-only

    def test_intent_M2_https_only_relaxation_rejected(self):
        # 场景 A：保留原文探针，追加 `&& url.protocol !== "http:"` 放行 http。
        self._replace("effects.js",
                      'if (url.protocol !== "https:") return bad("link.url must be https");',
                      'if (url.protocol !== "https:" && url.protocol !== "http:") return bad("link.url must be https");')
        self.assertIs(self._guard("linkHttpsOnly"), False,
                      "行为探针应检测 http URL 被放行")
        self._assert_reject("linkHttpsOnly", "[HARD] sourceGuards.linkHttpsOnly")

    def test_intent_M2_https_only_gate_removed_rejected(self):
        # 场景 B：整行删除 https 检查。
        self._replace("effects.js",
                      '      if (url.protocol !== "https:") return bad("link.url must be https");\n',
                      '')
        self.assertIs(self._guard("linkHttpsOnly"), False)
        self._assert_reject("linkHttpsOnly")

    # ---------------------------------------------------------------- M3 no credentials

    def test_intent_M3_credentials_or_to_and_rejected(self):
        # 场景 A：|| 改 &&，单独 user / pass 被放行。
        self._replace("effects.js",
                      'if (url.username !== "" || url.password !== "") return bad("link.url must not carry credentials");',
                      'if (url.username !== "" && url.password !== "") return bad("link.url must not carry credentials");')
        self.assertIs(self._guard("linkNoCredentials"), False,
                      "行为探针应检测单独 user:pass 被放行")
        self._assert_reject("linkNoCredentials", "[HARD] sourceGuards.linkNoCredentials")

    def test_intent_M3_credentials_check_removed_rejected(self):
        # 场景 B：整行删除凭据检查。
        self._replace("effects.js",
                      '      if (url.username !== "" || url.password !== "") return bad("link.url must not carry credentials");\n',
                      '')
        self.assertIs(self._guard("linkNoCredentials"), False)
        self._assert_reject("linkNoCredentials")

    # ---------------------------------------------------------------- M4 permission hard deny

    def test_intent_M4_permission_hard_deny_short_circuit_rejected(self):
        # 场景 A：保留文本，加 `&& false` 绕过（复核报告原版假绿变异）。
        self._replace("effects.js",
                      'if (e.name === "permission") return bad("native effects cannot select permission presets");',
                      'if (e.name === "permission" && false) return bad("native effects cannot select permission presets");')
        self.assertIs(self._guard("permissionHardDeny"), False)
        self._assert_reject("permissionHardDeny", "[HARD] sourceGuards.permissionHardDeny")

    def test_intent_M4_permission_hard_deny_removed_rejected(self):
        # 场景 B：直接删除硬拒分支。
        self._replace("effects.js",
                      '      if (e.name === "permission") return bad("native effects cannot select permission presets");\n',
                      '')
        self.assertIs(self._guard("permissionHardDeny"), False)
        self._assert_reject("permissionHardDeny")

    # ---------------------------------------------------------------- M5 picker 阈值翻转

    def test_intent_M5_picker_gesture_flipped_rejected(self):
        # 场景 A：!== true → === false（复核报告 M5）。
        self._replace("capabilities.js",
                      'if (opts.userGesture !== true) return bad("file selection needs an explicit user gesture");',
                      'if (opts.userGesture === false) return bad("file selection needs an explicit user gesture");')
        self.assertIs(self._guard("pickerUserGesture"), False)
        self._assert_reject("pickerUserGesture", "HARD")

    def test_intent_M5_picker_gesture_replaced_with_truthy_rejected(self):
        # 场景 B：改成任意真值即可（`=== true` → `!= null`），字符串 "true" 会通过。
        self._replace("capabilities.js",
                      'if (opts.userGesture !== true) return bad("file selection needs an explicit user gesture");',
                      'if (opts.userGesture == null) return bad("file selection needs an explicit user gesture");')
        self.assertIs(self._guard("pickerUserGesture"), False)
        self._assert_reject("pickerUserGesture")

    # ---------------------------------------------------------------- M6 降级阈值 hard condition

    def test_intent_M6_degrade_condition_widened_rejected(self):
        # 场景 A：真实条件改成 >1000000（复核报告 M6）。
        self._replace("core.js",
                      'if (h.consecutive >= LIMITS.violationsToDegrade && !h.degraded) {',
                      'if (h.consecutive > 1000000 && !h.degraded) {')
        self.assertIs(self._guard("degradeAtThreshold"), False)
        self._assert_reject("degradeAtThreshold")

    def test_intent_M6_degrade_flag_never_set_rejected(self):
        # 场景 B：条件保留，h.degraded = true 改为 false（永不降级）。
        self._replace("core.js",
                      '      h.degraded = true;',
                      '      h.degraded = false;')
        self.assertIs(self._guard("degradeAtThreshold"), False)
        self._assert_reject("degradeAtThreshold")

    # ---------------------------------------------------------------- D1 dead reference

    def test_intent_D1_dead_reference_condition_gutted_rejected(self):
        # 场景：保留 violationsToDegrade 死引用，真实条件失效（原版假绿）。
        self._replace("core.js",
                      'if (h.consecutive >= LIMITS.violationsToDegrade && !h.degraded) {',
                      'const _unused_degrade = LIMITS.violationsToDegrade;\n    if (h.consecutive > 1000000 && !h.degraded) {')
        self.assertIs(self._guard("degradeAtThreshold"), False,
                      "行为探针不受死引用干扰")
        self._assert_reject("degradeAtThreshold", "[HARD] sourceGuards.degradeAtThreshold")

    # ---------------------------------------------------------------- P1b picker && false

    def test_intent_P1b_picker_hard_deny_short_circuit_rejected(self):
        self._replace("capabilities.js",
                      'if (opts.userGesture !== true) return bad("file selection needs an explicit user gesture");',
                      'if (opts.userGesture !== true && false) return bad("file selection needs an explicit user gesture");')
        self.assertIs(self._guard("pickerUserGesture"), False)
        self._assert_reject("pickerUserGesture", "[HARD] sourceGuards.pickerUserGesture")

    # ---------------------------------------------------------------- P2 unknown() violation:false

    def test_intent_P2_capability_unknown_violation_flipped_rejected(self):
        # 场景 A：capabilityEffect 的 unknown() 改成 violation:true。
        self._replace("capabilities.js",
                      'const unknown = (message) => ({ issue: { code: "unknown-effect", message, violation: false } });\n  const bad = (message) => ({ issue: { code: "bad-effect", message, violation: true } });\n  const p = opts.capabilities;',
                      'const unknown = (message) => ({ issue: { code: "unknown-effect", message, violation: true } });\n  const bad = (message) => ({ issue: { code: "bad-effect", message, violation: true } });\n  const p = opts.capabilities;')
        self.assertIs(self._guard("capabilityEffectUnknownNoViolation"), False)
        self._assert_reject("capabilityEffectUnknownNoViolation",
                            "[HARD] sourceGuards.capabilityEffectUnknownNoViolation")

    def test_intent_P2_picker_unknown_violation_flipped_rejected(self):
        # 场景 B：pickerEffect 的 unknown() 改成 violation:true。
        self._replace("capabilities.js",
                      'const unknown = (message) => ({ issue: { code: "unknown-effect", message, violation: false } });\n  const bad = (message) => ({ issue: { code: "bad-effect", message, violation: true } });\n  if (!(opts.capabilities?.declared ?? []).includes("files"))',
                      'const unknown = (message) => ({ issue: { code: "unknown-effect", message, violation: true } });\n  const bad = (message) => ({ issue: { code: "bad-effect", message, violation: true } });\n  if (!(opts.capabilities?.declared ?? []).includes("files"))')
        self.assertIs(self._guard("pickerEffectUnknownNoViolation"), False)
        self._assert_reject("pickerEffectUnknownNoViolation",
                            "[HARD] sourceGuards.pickerEffectUnknownNoViolation")

    # ---------------------------------------------------------------- R1 routes userGesture 链路

    def test_intent_R1_userGesture_hardcoded_true_rejected(self):
        # 场景 A：body.userGesture === true 改成恒 true（复核报告 R1）。
        self._replace("routes.js",
                      "userGesture: body.userGesture === true",
                      "userGesture: true")
        self.assertIs(self._guard("routesUserGesturePassthrough"), False)
        self._assert_reject("routesUserGesturePassthrough",
                            "[HARD] sourceGuards.routesUserGesturePassthrough")

    def test_intent_R1_userGesture_truthy_cast_rejected(self):
        # 场景 B：改成 !!body.userGesture（字符串 "false" 会变 true）。
        self._replace("routes.js",
                      "userGesture: body.userGesture === true",
                      "userGesture: !!body.userGesture")
        self.assertIs(self._guard("routesUserGesturePassthrough"), False)
        self._assert_reject("routesUserGesturePassthrough")

    def test_intent_R1_userGesture_type_check_removed_rejected(self):
        # 场景 C：删除 body.userGesture 类型校验，使 "false" 等字符串进入链路。
        self._replace("routes.js",
                      '    if (body.userGesture !== undefined && typeof body.userGesture !== "boolean") fail(400, "bad-request", "userGesture must be a boolean");\n',
                      '')
        self.assertIs(self._guard("routesUserGestureTypeCheck"), False)
        self._assert_reject("routesUserGestureTypeCheck",
                            "[HARD] sourceGuards.routesUserGestureTypeCheck")

    # ---------------------------------------------------------------- B2/B1 routes 源码探针残留绕过（独立审查发现）

    def test_intent_B2_decoy_comment_plus_true_rejected(self):
        # 真调用行前插诱饵注释、真行改 userGesture: true；AST 下真调用被改即翻假。
        true_line = ("    const norm = normalizeEffects(result, { panels, source: isPanel ? body.id : "
                     "undefined, capabilities: capabilities.options(rec, capabilityConn), "
                     "userGesture: body.userGesture === true });")
        decoy = "    // normalizeEffects(result, { userGesture: body.userGesture === true });\n"
        self._replace("routes.js", true_line,
                      decoy + true_line.replace("body.userGesture === true", "true"))
        self.assertIs(self._guard("routesUserGesturePassthrough"), False,
                      "诱饵注释不应让真行的 userGesture: true 蒙混过关")
        self._assert_reject("routesUserGesturePassthrough",
                            "[HARD] sourceGuards.routesUserGesturePassthrough")

    def test_intent_B1_type_check_and_false_rejected(self):
        # 类型检查行条件末尾追加 && false；AST 下条件不再是规范式、检查消失即翻假。
        self._replace("routes.js",
                      'typeof body.userGesture !== "boolean") fail(',
                      'typeof body.userGesture !== "boolean" && false) fail(')
        self.assertIs(self._guard("routesUserGestureTypeCheck"), False,
                      "追加 && false 使类型校验失效，应翻假")
        self._assert_reject("routesUserGestureTypeCheck",
                            "[HARD] sourceGuards.routesUserGestureTypeCheck")

    def test_intent_B2_duplicate_key_rejected(self):
        # 对象重复键：首个规范、末个 true；JS 末键胜出，AST 应据属性数=2 翻假。
        self._replace("routes.js",
                      "userGesture: body.userGesture === true });",
                      "userGesture: body.userGesture === true, userGesture: true });")
        self.assertIs(self._guard("routesUserGesturePassthrough"), False,
                      "重复键末值胜出放行文件选择，应翻假")
        self._assert_reject("routesUserGesturePassthrough",
                            "[HARD] sourceGuards.routesUserGesturePassthrough")

    def test_intent_B1_double_if_rejected(self):
        # 双 if：首 if 条件规范但空体、次 if(false) 才 fail；AST 应据规范 if 无 fail 翻假。
        self._replace("routes.js",
                      'if (body.userGesture !== undefined && typeof body.userGesture !== "boolean") fail(400, "bad-request", "userGesture must be a boolean");',
                      'if (body.userGesture !== undefined && typeof body.userGesture !== "boolean") {} if (false) fail(400, "bad-request", "userGesture must be a boolean");')
        self.assertIs(self._guard("routesUserGestureTypeCheck"), False,
                      "规范 if 空体、真检查被架空，应翻假")
        self._assert_reject("routesUserGestureTypeCheck",
                            "[HARD] sourceGuards.routesUserGestureTypeCheck")

    def test_intent_B2_or_true_and_bangbang_rejected(self):
        # || true 与 !!body.userGesture：右式源码不再等于规范式，AST 应翻假。
        self._replace("routes.js",
                      "userGesture: body.userGesture === true });",
                      "userGesture: true || body.userGesture === true });")
        self.assertIs(self._guard("routesUserGesturePassthrough"), False)
        self._assert_reject("routesUserGesturePassthrough")
        # 第二个场景在独立副本上重来（setUp 每例一份，这里再改一次）。
        self._write("routes.js", self._read("routes.js").replace(
            "userGesture: true || body.userGesture === true });",
            "userGesture: !!body.userGesture });", 1))
        self.assertIs(self._guard("routesUserGesturePassthrough"), False)
        self._assert_reject("routesUserGesturePassthrough")

    def test_intent_B1_delete_fail_rejected(self):
        # 规范 if 删掉 fail 调用：AST 应据 failCount=0 翻假。
        self._replace("routes.js",
                      'typeof body.userGesture !== "boolean") fail(',
                      'typeof body.userGesture !== "boolean") void (')
        self.assertIs(self._guard("routesUserGestureTypeCheck"), False)
        self._assert_reject("routesUserGestureTypeCheck",
                            "[HARD] sourceGuards.routesUserGestureTypeCheck")

    def test_intent_string_slash_benign_does_not_false_reject(self):
        # 良性变更：注入含 // 的字符串字面量，真检查未动。AST 应正确放行，不误报。
        self._replace("routes.js",
                      "const norm = normalizeEffects(result, { panels,",
                      'const ugHide="http://";\n    const norm = normalizeEffects(result, { panels,')
        snap = snapshot(self.copy)
        self.assertTrue(snap["sourceGuards"]["routesUserGesturePassthrough"],
                        "字符串里的 // 不是代码，不应误报")
        r = run_checker(self.copy)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    # ---------------------------------------------------------------- G1 insertChars 漏字段

    def test_intent_G1_insert_chars_widened_rejected(self):
        self._replace("limits.js", "insertChars: 2000,", "insertChars: 200000,")
        snap = snapshot(self.copy)
        self.assertEqual(snap["limits"]["insertChars"], 200000)
        self.assertTrue(all(snap["sourceGuards"].values()))
        self._assert_reject("limits.insertChars", "放宽(数值变大)", "[REVIEW]", hard=False)

    def test_intent_G1_copy_chars_widened_rejected(self):
        self._replace("limits.js", "copyChars: 8000,", "copyChars: 800000,")
        self.assertIn("copyChars", snapshot(self.copy)["limits"])
        self._assert_reject("limits.copyChars", "放宽(数值变大)", hard=False)

    # ---------------------------------------------------------------- G2 CAP_LIMITS

    def test_intent_G2_cap_limits_widened_rejected(self):
        self._replace("capabilities.js",
                      "leases: 8, pluginLeases: 2, eventBurst: 4, eventsPerSecond: 10,",
                      "leases: 800, pluginLeases: 200, eventBurst: 400, eventsPerSecond: 1000,")
        snap = snapshot(self.copy)
        self.assertEqual(snap["capLimits"]["eventBurst"], 400)
        self.assertEqual(snap["capLimits"]["eventsPerSecond"], 1000)
        r = self._assert_reject("capLimits.eventBurst", "capLimits.eventsPerSecond", hard=False)
        self.assertIn("放宽(数值变大)", r.stdout + r.stderr)

    def test_intent_G2_cap_limits_media_bytes_widened_rejected(self):
        self._replace("capabilities.js",
                      "mediaBytes: 16 * 1024 * 1024, mediaMs: 30000, mediaConcurrent: 2,",
                      "mediaBytes: 160 * 1024 * 1024, mediaMs: 30000, mediaConcurrent: 2,")
        self.assertEqual(snapshot(self.copy)["capLimits"]["mediaBytes"], 160 * 1024 * 1024)
        self._assert_reject("capLimits.mediaBytes", hard=False)

    # ---------------------------------------------------------------- G3 FILE_LIMITS

    def test_intent_G3_file_limits_widened_rejected(self):
        self._replace("capabilities.js",
                      "count: 4, bytes: 8 * 1024 * 1024, totalBytes: 16 * 1024 * 1024,",
                      "count: 400, bytes: 800 * 1024 * 1024, totalBytes: 1600 * 1024 * 1024,")
        snap = snapshot(self.copy)
        self.assertEqual(snap["fileLimits"]["count"], 400)
        self.assertEqual(snap["fileLimits"]["bytes"], 800 * 1024 * 1024)
        self._assert_reject("fileLimits.count", "fileLimits.bytes", "fileLimits.totalBytes", hard=False)

    # ---------------------------------------------------------------- X1 scopeKeys

    def test_intent_X1_scope_raw_text_key_rejected(self):
        self._replace("limits.js",
                      'export const SCOPE_KEYS = ["sessionId", "turnId", "messageId", "callId"];',
                      'export const SCOPE_KEYS = ["sessionId", "turnId", "messageId", "callId", "rawText"];')
        snap = snapshot(self.copy)
        self.assertIn("rawText", snap["scopeKeys"])
        r = self._assert_reject("scopeKeys", "[HARD] scopeKeys")
        # HARD 标记修复：叶子路径 diff 也必须显示 [HARD] 而非 [REVIEW]
        self.assertIn("[HARD] scopeKeys:", r.stdout)

    # ---------------------------------------------------------------- X2 permission 删除

    def test_intent_X2_permission_branch_deleted_rejected(self):
        self._replace("effects.js",
                      '      if (e.name === "permission") return bad("native effects cannot select permission presets");\n',
                      '      if (e.name === "permission") return { effect: e };\n')
        self.assertIs(self._guard("permissionHardDeny"), False)
        r = self._assert_reject("permissionHardDeny")
        self.assertIn("[HARD] sourceGuards.permissionHardDeny:", r.stdout)

    # ---------------------------------------------------------------- X3 白名单扩大

    def test_intent_X3_whitelist_widened_rejected(self):
        self._replace("capabilities.js",
                      'export const EFFECT_FEATURES = ["audio", "voice", "overlay"];',
                      'export const EFFECT_FEATURES = ["audio", "voice", "overlay", "files"];')
        snap = snapshot(self.copy)
        self.assertIn("files", snap["effects"]["effectFeatures"])
        self._assert_reject("effects.effectFeatures", "[REVIEW]", hard=False)

    # ---------------------------------------------------------------- HARD 标记叶子路径

    def test_intent_hard_marker_on_leaf_guard_flip(self):
        # 任一 sourceGuards 叶子翻假，差异表必须标 [HARD] 而不是 [REVIEW]/未知。
        self._replace("effects.js",
                      'if (url.protocol !== "https:") return bad("link.url must be https");',
                      'if (url.protocol !== "https:" && url.protocol !== "http:") return bad("link.url must be https");')
        r = self._assert_reject("硬红线失守")
        self.assertIn("[HARD] sourceGuards.linkHttpsOnly:", r.stdout)
        self.assertNotIn("[REVIEW] sourceGuards.linkHttpsOnly", r.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
