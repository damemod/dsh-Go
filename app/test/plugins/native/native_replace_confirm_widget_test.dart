// Intent tests for the whole-draft replace write gate (native_taps.dart).
//
// The state-layer scoping lives in native_replace_permission_test.dart; here a
// real capsule tap drives the write gate so the security invariants are checked
// end to end:
//   - a session allowance skips ONLY the dialog, never the unchanged-draft
//     fingerprint (D2) or the compose authorization (D1);
//   - a deferred result arriving after the person edited the draft cannot
//     overwrite it even with a session allowance;
//   - without the compose want no replace can happen at all;
//   - the ＋ panel permission card lists grants and revokes both stores.
//
// The confirm dialog is deliberately not driven here: it is a modal route whose
// Future only completes when the person taps a button, and driving it from a
// widget test makes the test body park on that Future. The allowance is seeded
// through its provider instead, which exercises exactly the write-gate path
// this file is about (session allowance still passes through D1 and D2).
//
// The compose want and the session allowance are pre-acknowledged through
// SharedPreferences / the provider so these tests focus on the replace gate.

import 'package:dsh_app/plugins/native/native_capabilities.dart';
import 'package:dsh_app/plugins/native/native_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/chat/widgets/plus_panel.dart';
import 'package:dsh_app/ui/common/list_page_row.dart';
import 'package:dsh_app/ui/plugins/native/native_composer_bar.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../chat/support/harness.dart';
import 'support.dart';

const _wantsKey = 'local:local|replace-helper|compose';

Map<String, Object?> _replacePlugin({List<String> wants = const ['compose']}) => plugin(
  'replace-helper',
  title: '替换助手',
  icon: 'bolt',
  wants: wants,
  composer: [
    {'id': 'go', 'label': '替换'},
  ],
);

Widget _bar(FakeBridge bridge, FakeComposer composer) {
  return testApp(
    Scaffold(
      backgroundColor: Colors.transparent,
      body: withComposer(
        composer,
        Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const NativeComposerBar(sessionId: 's1', visible: true),
                const SizedBox(key: ValueKey('composer'), height: 56),
              ],
            ),
          ),
        ),
      ),
    ),
    overrides: [...nativeOverrides(bridge)],
  );
}

// The wants provider builds empty and loads asynchronously on first read. The
// composer reads the wants only at tap time; force the load before tapping so
// the mock prefs are visible and the wants dialog does not appear instead of
// the replace gate.
Future<void> _primeGrants(WidgetTester tester) async {
  final container = ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
  container.read(nativeWantsAcksProvider);
  container.read(nativeVoiceConsentProvider);
  await Future<void>.delayed(Duration.zero);
}

/// Seed a session allowance for 's1' so the confirm dialog is skipped but every
/// write gate in `_runEffect` still runs.
Future<void> _allowSession(WidgetTester tester) async {
  final container = ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
  container.read(nativeReplaceSessionAllowProvider.notifier).allow('s1', HostRef.local, 'replace-helper');
  await Future<void>.delayed(Duration.zero);
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({NativeWantsAcks.prefsKey: [_wantsKey]}));

  testWidgets('session allowance writes once with no dialog; D2 still refuses a changed draft', (tester) async {
    usePhoneView(tester);
    final composer = FakeComposer(draft: 'ORIGINAL');
    final bridge = FakeBridge(contributions([_replacePlugin()]))
      ..answer = (_) => DshGoInvokeResult.fromJson({
        'v': 1,
        'effects': [
          {'type': 'replace', 'text': 'NEW'},
        ],
      });
    await tester.pumpWidget(_bar(bridge, composer));
    await pumpFrames(tester);
    await _primeGrants(tester);
    await _allowSession(tester);

    // With a session allowance the dialog is skipped and the immediate result
    // is written, because the draft is still exactly the one tapped.
    await tester.tap(find.text('替换'));
    await pumpFrames(tester);
    expect(composer.draft, 'NEW');

    // Higher-value invariant: a deferred result arriving after the person
    // edited the draft must not overwrite it. The session allowance never
    // bypasses D2.
    bridge.answer = (_) => DshGoInvokeResult.fromJson({
      'v': 1,
      'effects': [],
      'pending': {'id': 'p1', 'label': '替换中', 'timeoutMs': 30000},
    });
    composer.draft = 'A';
    await tester.tap(find.text('替换'));
    await pumpFrames(tester, 3);
    composer.draft = 'EDITED BY PERSON';
    bridge.socket.push({
      't': 'done',
      'pending': 'p1',
      'effects': [
        {'type': 'replace', 'text': 'SNEAKY'},
      ],
    });
    await pumpFrames(tester, 3);
    expect(composer.draft, 'EDITED BY PERSON', reason: 'D2 survives the session allowance on the deferred path');
  });

  testWidgets('a plugin without the compose want cannot replace', (tester) async {
    SharedPreferences.setMockInitialValues({});
    usePhoneView(tester);
    final composer = FakeComposer(draft: 'KEEP');
    final bridge = FakeBridge(contributions([_replacePlugin(wants: const [])]))
      ..answer = (_) => DshGoInvokeResult.fromJson({
        'v': 1,
        'effects': [
          {'type': 'replace', 'text': 'OVERWRITE'},
        ],
      });
    await tester.pumpWidget(_bar(bridge, composer));
    await pumpFrames(tester);
    await _primeGrants(tester);

    await tester.tap(find.text('替换'));
    await pumpFrames(tester);
    expect(composer.draft, 'KEEP', reason: 'D1: compose authorization is required for replace');
  });

  testWidgets('permission card lists grants and revoking clears both stores', (tester) async {
    SharedPreferences.setMockInitialValues({
      NativeWantsAcks.prefsKey: [_wantsKey],
      NativeVoiceConsents.prefsKey: ['1:local:local|replace-helper'],
    });
    usePhoneView(tester);
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: Center(
            child: Builder(
              builder: (context) => TextButton(
                onPressed: () => showPlusPanel(context, sessionId: 's1'),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    await pumpFrames(tester, 10);
    await _primeGrants(tester);
    await tester.tap(find.text('打开'));
    await pumpFrames(tester, 10);

    expect(find.text('插件权限'), findsWidgets, reason: 'card shows when a grant exists');
    await tester.tap(find.widgetWithText(ListPageRow, '插件权限'));
    await pumpFrames(tester);
    expect(find.text('replace-helper'), findsOneWidget, reason: 'granted plugin is listed');

    await tester.tap(find.text('撤销'));
    await pumpFrames(tester, 10);
    await Future<void>.delayed(Duration.zero);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList(NativeWantsAcks.prefsKey), isEmpty, reason: 'wants revoked');
    expect(prefs.getStringList(NativeVoiceConsents.prefsKey), isEmpty, reason: 'voice revoked');
    expect(find.text('没有已授权的插件'), findsOneWidget, reason: 'empty state after revoke');
  });
}
