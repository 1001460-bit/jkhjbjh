import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../logger.dart';
import 'background_keep_alive_preference.dart';

/// Flutter-side controller for the iOS background keep-alive feature.
///
/// Talks to the native `AppDelegate` over a `MethodChannel` named
/// `dev.ultrasend/background_keep_alive`. The native side is responsible for
/// calling `beginBackgroundTask` and playing a silent audio loop so the app
/// stays runnable while backgrounded.
///
/// This service is a no-op on non-iOS platforms.
class BackgroundKeepAliveService {
  BackgroundKeepAliveService._();

  static final BackgroundKeepAliveService instance =
      BackgroundKeepAliveService._();

  static const String _channelName = 'dev.ultrasend/background_keep_alive';

  MethodChannel? _channel;
  bool _initialized = false;
  bool _nativeEnabled = false;

  /// Whether the native keep-alive is currently active (only meaningful on
  /// iOS after [init]).
  bool get isNativeEnabled => _nativeEnabled;

  /// Initialise the method channel and sync the persisted preference to the
  /// native side. Call once during app startup (after
  /// `WidgetsFlutterBinding.ensureInitialized`).
  Future<void> init() async {
    if (_initialized) return;
    if (!Platform.isIOS) {
      _initialized = true;
      return;
    }

    _channel = const MethodChannel(_channelName);
    _channel!.setMethodCallHandler(_handleNativeCall);
    _initialized = true;

    await BackgroundKeepAlivePreference.instance.load();
    await _syncToNative();
  }

  /// Enable or disable the native background keep-alive. Also persists the
  /// preference so it survives restarts.
  Future<void> setEnabled(bool enabled) async {
    await BackgroundKeepAlivePreference.instance.setEnabled(enabled);
    await _syncToNative();
  }

  /// Read the current persisted preference (convenience).
  bool get enabled => BackgroundKeepAlivePreference.instance.enabled;

  Future<void> _syncToNative() async {
    if (!Platform.isIOS || _channel == null) return;
    final shouldEnable = BackgroundKeepAlivePreference.instance.enabled;
    try {
      final result = await _channel!.invokeMethod<bool>(
        'setKeepAliveEnabled',
        {'enabled': shouldEnable},
      );
      _nativeEnabled = result ?? shouldEnable;
      logBoot.info(
        'BackgroundKeepAliveService synced to native: enabled=$_nativeEnabled',
      );
    } catch (e, st) {
      logBoot.warning(
        'BackgroundKeepAliveService sync to native failed: $e',
        e,
        st,
      );
    }
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onBackgroundTaskExpiring':
        logBoot.info(
          'BackgroundKeepAliveService: native background task expiring',
        );
        return null;
      default:
        return null;
    }
  }
}
