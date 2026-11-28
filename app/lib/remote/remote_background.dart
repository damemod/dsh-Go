import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/android_features.dart';
import '../state/connection_state.dart';
import '../state/hosts_state.dart';

const _channel = MethodChannel('io.github.ccch1mneyyy.dsh_app/remote_background');

typedef RemoteBackgroundOptions = ({bool enabled, bool audio, bool location});

final remoteBackgroundOptionsProvider = AsyncNotifierProvider<RemoteBackgroundPreferences, RemoteBackgroundOptions>(
  RemoteBackgroundPreferences.new,
);

class RemoteBackgroundPreferences extends AsyncNotifier<RemoteBackgroundOptions> {
  static const _enabledKey = 'remote_background_enabled';
  static const _audioKey = 'remote_background_audio';
  static const _locationKey = 'remote_background_location';

  static RemoteBackgroundOptions _read(SharedPreferences prefs) => (
        enabled: prefs.getBool(_enabledKey) ?? false,
        audio: prefs.getBool(_audioKey) ?? false,
        location: prefs.getBool(_locationKey) ?? false,
      );

  @override
  Future<RemoteBackgroundOptions> build() async => _read(await SharedPreferences.getInstance());

  Future<void> setEnabled(bool value) => _set(_enabledKey, value);
  Future<void> setAudio(bool enabled) => _set(_audioKey, enabled);
  Future<void> setLocation(bool enabled) => _set(_locationKey, enabled);

  Future<void> _set(String key, bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setBool(key, enabled)) throw StateError('remote_background_preference_write_failed');
    if (ref.mounted) state = AsyncData(_read(prefs));
  }
}

Future<bool> requestRemoteBackgroundLocation() async =>
    await _channel.invokeMethod<bool>('requestRemoteLocation') ?? false;

final _remotePhaseProvider = Provider.autoDispose((ref) {
  final host = ref.watch(activeHostProvider);
  final phase = host.isLocal
      ? null
      : ref.watch(hostLinkStatusProvider(host).select((s) => s.isLoading || s.hasError ? null : s.value?.phase));
  return (host, phase);
});

/// Reports the active link independently of the UI route and the local engine.
final remoteBackgroundProvider = Provider.autoDispose<void>((ref) {
  final os = ref.watch(operatingSystemProvider);
  if (os != 'android' && os != 'ohos') return;

  Future<void> report(String method, bool enabled) async {
    try {
      await _channel.invokeMethod<void>(method, enabled);
    } on PlatformException catch (error) {
      debugPrint('Remote background protection: ${error.code}');
    }
  }

  ref.listen(remoteBackgroundOptionsProvider.select((s) => s.value?.audio ?? false), (previous, enabled) {
    if (previous != null || enabled) unawaited(report('setRemoteAudio', enabled));
  }, fireImmediately: true);
  if (os == 'android') {
    ref.listen(remoteBackgroundOptionsProvider.select((s) => s.value?.location ?? false), (previous, enabled) {
      if (previous != null || enabled) unawaited(report('setRemoteLocation', enabled));
    }, fireImmediately: true);
  }

  var active = false;
  // Master switch: remote background stays off until the user explicitly opts in.
  // Turning it off releases the foreground service and wake lock immediately.
  ref.listen(remoteBackgroundOptionsProvider.select((s) => s.value?.enabled ?? false), (previous, enabled) {
    final (_, phase) = ref.read(_remotePhaseProvider);
    final armed = enabled && (phase == HostLinkPhase.connected || phase == HostLinkPhase.reconnecting && active);
    if (active == armed) return;
    active = armed;
    unawaited(report('setRemoteActive', active));
  }, fireImmediately: true);
  ref.listen(_remotePhaseProvider, (previous, next) {
    final (host, phase) = next;
    final enabled = ref.read(remoteBackgroundOptionsProvider).value?.enabled ?? false;
    // Keep protection through recovery on the same host, not through an initial dial.
    final armed =
        enabled && (phase == HostLinkPhase.connected || phase == HostLinkPhase.reconnecting && active && previous?.$1 == host);
    if (active == armed) return;
    active = armed;
    unawaited(report('setRemoteActive', active));
  }, fireImmediately: true);
  ref.onDispose(() {
    if (active) unawaited(report('setRemoteActive', false));
  });
});
