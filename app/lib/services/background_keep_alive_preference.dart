import 'package:shared_preferences/shared_preferences.dart';

/// Persisted user preference for iOS background keep-alive (continuous
/// transfer while the app is in the background).
///
/// Defaults to `false` so the app keeps its original behaviour (iOS suspends
/// the app shortly after it leaves the foreground). When the user manually
/// enables it, the native iOS layer requests background execution time and
/// plays a silent audio loop so active file transfers can continue.
class BackgroundKeepAlivePreference {
  BackgroundKeepAlivePreference._();

  static final BackgroundKeepAlivePreference instance =
      BackgroundKeepAlivePreference._();

  static const String _prefKey = 'ios_background_keep_alive_enabled';

  bool _value = false;
  bool _loaded = false;

  /// Whether the user has enabled background continuous transfer.
  bool get enabled => _value;

  /// Load the persisted value from SharedPreferences. Safe to call multiple
  /// times; subsequent calls are no-ops.
  Future<void> load() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _value = prefs.getBool(_prefKey) ?? false;
    } catch (_) {
      _value = false;
    }
    _loaded = true;
  }

  /// Persist a new value and return it.
  Future<bool> setEnabled(bool enabled) async {
    _value = enabled;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefKey, enabled);
    } catch (_) {
      // Best-effort persistence; in-memory value still applies for this
      // session.
    }
    return enabled;
  }
}
