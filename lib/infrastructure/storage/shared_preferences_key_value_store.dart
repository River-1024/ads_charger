import 'package:shared_preferences/shared_preferences.dart';

import 'key_value_store.dart';

final class SharedPreferencesKeyValueStore implements KeyValueStore {
  SharedPreferencesKeyValueStore(this._preferences);

  final SharedPreferences _preferences;

  static Future<SharedPreferencesKeyValueStore> create() async {
    return SharedPreferencesKeyValueStore(
      await SharedPreferences.getInstance(),
    );
  }

  @override
  Future<String?> getString(String key) async => _preferences.getString(key);

  @override
  Future<void> remove(String key) async {
    final removed = await _preferences.remove(key);
    if (!removed) {
      throw StateError('SharedPreferences failed to remove "$key".');
    }
  }

  @override
  Future<void> setString(String key, String value) async {
    final saved = await _preferences.setString(key, value);
    if (!saved) {
      throw StateError('SharedPreferences failed to save "$key".');
    }
  }
}
