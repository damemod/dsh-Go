// Intent tests for the whole-draft replace write gate (native_taps.dart).
//
// The state-layer scoping lives in native_replace_permission_test.dart; here a
// real capsule tap drives the replace-confirm dialog so the security
// invariants are checked end to end:
//   - "once" is this write only and is not remembered; cancel writes nothing;
//   - a session allowance skips ONLY the dialog, never the unchanged-draft
//     fingerprint (D2) or the compose authorization (D1);
//   - the ＋ panel permission card lists grants and revokes both stores.
//
// The compose want is pre-acknowledged through SharedPreferences so these tests
// focus on the replace gate (the want-ack flow has its own tests elsewhere).

import 'package:dsh_app/plugins/native/native_capabilities.dart';
import 'package:dsh_app/plugins/native/native_state.dart';
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

const _confirmTitle = '让「替换助手」替换你输入的文字？当前文字会被覆盖，且无法撤销。';
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

// These prefs-backed providers build empty and load asynchronously on first
// read. The composer reads the wants only at tap time, and the permission card
// reads grants at build time; force both loads before interacting so the mock
// prefs are visible — otherwise the wants dialog appears instead of the
// replace gate, or the card renders empty.
Future<void> _primeGrants(WidgetTester tester) async {
  final container = ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
  container.read(nativeWantsAcksProvider);
  container.read(nativeVoiceConsentProvider);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({NativeWantsAcks.prefsKey: [_wantsKey]}));

  testWidgets('once writes this time only; cancel writes nothing', (tester) async {
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

    await tester.tap(find.text('替换'));
    await tester.pumpAndSettle();
    expect(find.text(_confirmTitle), findsOneWidget, reason: 'compose want already acknowledged');
    await tester.tap(find.text('仅这次'));
    await tester.pumpAndSettle();
    expect(composer.draft, 'NEW');

    // "once" is NOT remembered: the dialog comes back on the next tap.
    await tester.tap(find.text('替换'));
    await tester.pumpAndSettle();
    expect(find.text(_confirmTitle), findsOneWidget, reason: 'once is not a session allowance');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(composer.draft, 'NEW', reason: 'cancel leaves the draft untouched');
  });

  testWidgets('session allow skips only the dialog; D2 still refuses a changed draft', (tester) async {
    usePhoneView(tester);
    final composer = FakeComposer(draft: 'A');
    final bridge = FakeBridge(contributions([_replacePlugin()]))
      ..answer = (_) => DshGoInvokeResult.fromJson({
        'v': 1,
        'effects': [
          {'type': 'replace', 'text': 'B'},
        ],
      });
    await tester.pumpWidget(_bar(bridge, composer));
    await pumpFrames(tester);
    await _primeGrants(tester);

    // Establish the session allowance through the dialog.
    await tester.tap(find.text('替换'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('本对话内不再提示'));
    await tester.pumpAndSettle();
    expect(composer.draft, 'B');

    // Same session, unchanged draft: the dialog is skipped, replace still runs.
    await tester.tap(find.text('替换'));
    await pumpFrames(tester);
    expect(find.text(_confirmTitle), findsNothing, reason: 'session allowance skips the dialog');

    // A deferred result arriving after the person edited the draft must not
    // overwrite it: the session allowance never bypasses D2.
    bridge.answer = (_) => DshGoInvokeResult.fromJson({
      'v': 1,
      'effects': [],
      'pending': {'id': 'p1', 'label': '替换中', 'timeoutMs': 30000},
    });
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

    await tester.tap(find.text('替换'));
    await pumpFrames(tester);
    expect(find.text(_confirmTitle), findsNothing, reason: 'D1 refuses before any confirm dialog');
    expect(composer.draft, 'KEEP', reason: 'compose authorization is required for replace');
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
