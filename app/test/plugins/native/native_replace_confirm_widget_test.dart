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
// The confirm dialog is deliberately not driven: the session allowance skips
// it, and the wants dialog is avoided by seeding the wants/voice notifiers with
// a fixed state. Both providers otherwise build empty and load SharedPreferences
// asynchronously (native_state.dart:341-352, native_capabilities.dart:691-708);
// if that load has not flushed at tap time, runNativeTap opens the wants dialog
// (native_taps.dart:322-323) and waits for a tap that never comes -> 10-min test
// timeout. Fixed notifiers make the grant state synchronous and deterministic.

import 'package:dsh_app/plugins/native/native_capabilities.dart';
import 'package:dsh_app/plugins/native/native_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/chat/widgets/plus_panel.dart';
import 'package:dsh_app/ui/common/list_page_row.dart';
import 'package:dsh_app/ui/plugins/native/native_composer_bar.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../chat/support/harness.dart';
import 'support.dart';

const _wantsKey = 'local:local|replace-helper|compose';
const _voiceKey = 'local:local|replace-helper';

/// A wants notifier with a fixed, synchronous state — no async prefs load.
class _FixedWants extends NativeWantsAcks {
  _FixedWants(this.initial);
  final Set<String> initial;
  @override
  Set<String> build() => initial;
}

/// A voice-consent notifier with a fixed, synchronous state.
class _FixedVoice extends NativeVoiceConsents {
  _FixedVoice(this.initial);
  final Map<String, bool> initial;
  @override
  Map<String, bool> build() => initial;
}

Map<String, Object?> _replacePlugin({List<String> wants = const ['compose']}) => plugin(
  'replace-helper',
  title: '替换助手',
  icon: 'bolt',
  wants: wants,
  composer: [
    {'id': 'go', 'label': '替换'},
  ],
);

/// Overrides that seed the wants/voice grants synchronously for the harness.
List<Override> _grants({Set<String> wants = const {_wantsKey}, Map<String, bool> voice = const {}}) => [
  nativeWantsAcksProvider.overrideWith(() => _FixedWants(wants)),
  nativeVoiceConsentProvider.overrideWith(() => _FixedVoice(voice)),
];

Widget _bar(FakeBridge bridge, FakeComposer composer, {List<Override> grants = const []}) {
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
    overrides: [...nativeOverrides(bridge), ...grants],
  );
}

/// Seed a session allowance for 's1' so the confirm dialog is skipped but every
/// write gate in `_runEffect` still runs.
Future<void> _allowSession(WidgetTester tester) async {
  final container = ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
  container.read(nativeReplaceSessionAllowProvider.notifier).allow('s1', HostRef.local, 'replace-helper');
  await pumpFrames(tester, 2);
}

void main() {
  setUpAll(loadTestFonts);

  testWidgets('session allowance writes once with no dialog; D2 still refuses a changed draft', (tester) async {
    SharedPreferences.setMockInitialValues({});
    usePhoneView(tester);
    final composer = FakeComposer(draft: 'ORIGINAL');
    final bridge = FakeBridge(contributions([_replacePlugin()]))
      ..answer = (_) => DshGoInvokeResult.fromJson({
        'v': 1,
        'effects': [
          {'type': 'replace', 'text': 'NEW'},
        ],
      });
    await tester.pumpWidget(_bar(bridge, composer, grants: _grants()));
    await pumpFrames(tester);
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
    // No compose grant: the plugin has no wants, so composeAuthorized is false.
    await tester.pumpWidget(_bar(bridge, composer, grants: _grants(wants: const {})));
    await pumpFrames(tester);

    await tester.tap(find.text('替换'));
    await pumpFrames(tester);
    expect(composer.draft, 'KEEP', reason: 'D1: compose authorization is required for replace');
  });

  testWidgets('permission card lists grants and revoking clears both stores', (tester) async {
    SharedPreferences.setMockInitialValues({});
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
        overrides: _grants(voice: const {_voiceKey: true}),
      ),
    );
    await pumpFrames(tester, 10);
    await tester.tap(find.text('打开'));
    await pumpFrames(tester, 10);

    expect(find.text('插件权限'), findsWidgets, reason: 'card shows when a grant exists');
    await tester.tap(find.widgetWithText(ListPageRow, '插件权限'));
    await pumpFrames(tester);
    expect(find.text('replace-helper'), findsOneWidget, reason: 'granted plugin is listed');

    await tester.tap(find.text('撤销'));
    await pumpFrames(tester, 10);
    // revokeWants/revokeVoice update their in-memory state synchronously before
    // the async prefs write. Read that state directly: a bare Future.delayed
    // scheduled after the last pump never fires under the widget tester's fake
    // clock, and prefs persistence is covered by native_replace_permission_test.
    final container = ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
    expect(container.read(nativeWantsAcksProvider), isEmpty, reason: 'wants revoked');
    expect(container.read(nativeVoiceConsentProvider), isEmpty, reason: 'voice revoked');
    expect(find.text('没有已授权的插件'), findsOneWidget, reason: 'empty state after revoke');
  });
}
