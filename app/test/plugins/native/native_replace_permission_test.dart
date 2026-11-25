// Intent tests for the replace "don't ask again this chat" allowance and the
// revocable plugin-grant APIs used by the ＋ panel's permission page.
//
// These exercise the state layer directly. The confirm dialog and the
// post-dialog write gate are covered end to end in
// native_replace_confirm_widget_test.dart.

import 'package:dsh_app/plugins/native/native_capabilities.dart';
import 'package:dsh_app/plugins/native/native_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _tick() => Future<void>.delayed(Duration.zero);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('session replace allowance', () {
    test('scoped to session + host + plugin, and dropped on revoke', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final allow = c.read(nativeReplaceSessionAllowProvider.notifier);
      final host = HostRef.local;

      expect(allow.allows('s1', host, 'polish'), isFalse);
      allow.allow('s1', host, 'polish');
      expect(allow.allows('s1', host, 'polish'), isTrue);
      // Other session / host / plugin never inherit the allowance.
      expect(allow.allows('s2', host, 'polish'), isFalse);
      expect(allow.allows('s1', HostRef.ssh('x'), 'polish'), isFalse);
      expect(allow.allows('s1', host, 'other'), isFalse);

      allow.revoke('local:local', 'polish');
      expect(allow.allows('s1', host, 'polish'), isFalse);
    });

    test('revoking one plugin leaves another plugin\'s allowance intact', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final allow = c.read(nativeReplaceSessionAllowProvider.notifier);
      allow.allow('s1', HostRef.local, 'a');
      allow.allow('s1', HostRef.local, 'b');
      allow.revoke('local:local', 'a');
      expect(allow.allows('s1', HostRef.local, 'a'), isFalse);
      expect(allow.allows('s1', HostRef.local, 'b'), isTrue);
    });

    test('a fresh container (process restart) has no allowance', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(nativeReplaceSessionAllowProvider.notifier).allow('s1', HostRef.local, 'polish');
      final fresh = ProviderContainer();
      addTearDown(fresh.dispose);
      expect(fresh.read(nativeReplaceSessionAllowProvider.notifier).allows('s1', HostRef.local, 'polish'), isFalse);
    });
  });

  group('wants grants', () {
    test('grantedWants parses keys, skips malformed, and revoke persists + clears session allow', () async {
      SharedPreferences.setMockInitialValues({
        NativeWantsAcks.prefsKey: [
          'local:local|polish|compose+draft',
          'ssh:x|translate|message',
          'garbage-no-separator',
        ],
      });
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(nativeWantsAcksProvider);
      await _tick();
      final acks = c.read(nativeWantsAcksProvider.notifier);

      final granted = acks.grantedWants();
      expect(granted.length, 2);
      final polish = granted.firstWhere((g) => g.package == 'polish');
      expect(polish.hostKey, 'local:local');
      expect(polish.wants, {'compose', 'draft'});
      expect(granted.any((g) => g.package == 'garbage-no-separator'), isFalse);

      c.read(nativeReplaceSessionAllowProvider.notifier).allow('s1', HostRef.local, 'polish');
      await acks.revokeWants('local:local', 'polish');
      expect(acks.grantedWants().any((g) => g.package == 'polish'), isFalse);
      expect(acks.grantedWants().any((g) => g.package == 'translate'), isTrue);
      expect(c.read(nativeReplaceSessionAllowProvider.notifier).allows('s1', HostRef.local, 'polish'), isFalse);

      final prefs = await SharedPreferences.getInstance();
      // The malformed key is never shown but is harmlessly preserved.
      expect(prefs.getStringList(NativeWantsAcks.prefsKey), contains('ssh:x|translate|message'));
      expect(prefs.getStringList(NativeWantsAcks.prefsKey), isNot(contains('local:local|polish|compose+draft')));
    });

    test('revoked wants stay revoked after a restart', () async {
      SharedPreferences.setMockInitialValues({
        NativeWantsAcks.prefsKey: ['local:local|polish|compose'],
      });
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(nativeWantsAcksProvider);
      await _tick();
      await c.read(nativeWantsAcksProvider.notifier).revokeWants('local:local', 'polish');

      final fresh = ProviderContainer();
      addTearDown(fresh.dispose);
      fresh.read(nativeWantsAcksProvider);
      await _tick();
      expect(fresh.read(nativeWantsAcksProvider.notifier).grantedWants(), isEmpty);
    });
  });

  group('voice grants', () {
    test('grantedVoice lists only explicit allows; revoke returns to never-asked and persists', () async {
      SharedPreferences.setMockInitialValues({
        NativeVoiceConsents.prefsKey: [
          '1:local:local|polish',
          '0:local:local|declined',
        ],
      });
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(nativeVoiceConsentProvider);
      await _tick();
      final consents = c.read(nativeVoiceConsentProvider.notifier);

      final granted = consents.grantedVoice();
      expect(granted.length, 1);
      expect(granted.single.package, 'polish');
      expect(granted.single.hostKey, 'local:local');

      await consents.revokeVoice('local:local', 'polish');
      expect(consents.of(HostRef.local, 'polish'), isNull, reason: 'revoked = never asked, not declined');
      expect(consents.grantedVoice(), isEmpty);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(NativeVoiceConsents.prefsKey), ['0:local:local|declined']);
    });
  });
}
