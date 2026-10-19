import 'dart:convert';

import '../../domain/validation/charger_parameter_validator.dart';
import '../../infrastructure/storage/key_value_store.dart';

final class DefaultDeviceRecord {
  DefaultDeviceRecord({
    required String deviceKey,
    required String name,
    String? profileFingerprint,
  }) : deviceKey = _requiredText(deviceKey, 'deviceKey'),
       name = _requiredText(name, 'name'),
       profileFingerprint = profileFingerprint == null
           ? null
           : _requiredText(profileFingerprint, 'profileFingerprint');

  final String deviceKey;
  final String name;
  final String? profileFingerprint;

  Map<String, Object> toJson() => <String, Object>{
    'deviceKey': deviceKey,
    'name': name,
    ...profileFingerprint == null
        ? const <String, Object>{}
        : <String, Object>{'profileFingerprint': profileFingerprint!},
  };

  static DefaultDeviceRecord? tryFromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      return null;
    }
    final deviceKey = value['deviceKey'];
    final name = value['name'];
    final profileFingerprint = value['profileFingerprint'];
    if (deviceKey is! String ||
        name is! String ||
        deviceKey.trim().isEmpty ||
        name.trim().isEmpty ||
        (profileFingerprint != null &&
            (profileFingerprint is! String ||
                profileFingerprint.trim().isEmpty))) {
      return null;
    }
    return DefaultDeviceRecord(
      deviceKey: deviceKey,
      name: name,
      profileFingerprint: profileFingerprint as String?,
    );
  }
}

final class UserPreset {
  UserPreset({
    required String id,
    required String name,
    required this.voltageHundredthsVolts,
    required this.currentTenthsAmps,
  }) : id = _requiredText(id, 'id'),
       name = _requiredText(name, 'name') {
    if (voltageHundredthsVolts < 0) {
      throw ArgumentError.value(
        voltageHundredthsVolts,
        'voltageHundredthsVolts',
        'Must not be negative.',
      );
    }
    if (currentTenthsAmps < 0) {
      throw ArgumentError.value(
        currentTenthsAmps,
        'currentTenthsAmps',
        'Must not be negative.',
      );
    }
  }

  final String id;
  final String name;
  final int voltageHundredthsVolts;
  final int currentTenthsAmps;

  Map<String, Object> toJson() => <String, Object>{
    'id': id,
    'name': name,
    'voltageHundredthsVolts': voltageHundredthsVolts,
    'currentTenthsAmps': currentTenthsAmps,
  };

  static UserPreset? tryFromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      return null;
    }
    final id = value['id'];
    final name = value['name'];
    final voltage = value['voltageHundredthsVolts'];
    final current = value['currentTenthsAmps'];
    if (id is! String ||
        name is! String ||
        voltage is! int ||
        current is! int ||
        id.trim().isEmpty ||
        name.trim().isEmpty ||
        voltage < 0 ||
        current < 0) {
      return null;
    }
    return UserPreset(
      id: id,
      name: name,
      voltageHundredthsVolts: voltage,
      currentTenthsAmps: current,
    );
  }
}

final class PresetService {
  PresetService(this._store, {String Function()? createId})
    : _createId = createId ?? _defaultId;

  static const String _defaultDeviceKey = 'presets.defaultDevice.v1';
  static const String _userPresetsKey = 'presets.userPresets.v1';

  final KeyValueStore _store;
  final String Function() _createId;

  Future<DefaultDeviceRecord?> getDefaultDevice() async {
    final raw = await _store.getString(_defaultDeviceKey);
    if (raw == null) {
      return null;
    }
    try {
      return DefaultDeviceRecord.tryFromJson(jsonDecode(raw));
    } on FormatException {
      return null;
    }
  }

  Future<void> setDefaultDevice(DefaultDeviceRecord device) async {
    await _store.setString(_defaultDeviceKey, jsonEncode(device.toJson()));
  }

  Future<void> clearDefaultDevice() => _store.remove(_defaultDeviceKey);

  Future<List<UserPreset>> getUserPresets() async {
    final raw = await _store.getString(_userPresetsKey);
    if (raw == null) {
      return const <UserPreset>[];
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List<dynamic>) {
        return const <UserPreset>[];
      }
      return decoded
          .map(UserPreset.tryFromJson)
          .whereType<UserPreset>()
          .toList(growable: false);
    } on FormatException {
      return const <UserPreset>[];
    }
  }

  Future<UserPreset> createUserPreset({
    required String name,
    required int voltageHundredthsVolts,
    required int currentTenthsAmps,
  }) async {
    ChargerParameterValidator.validateStatic(
      voltageHundredths: voltageHundredthsVolts,
      currentTenths: currentTenthsAmps,
    );
    final normalizedName = name.trim().toLowerCase();
    final presets = await getUserPresets();
    if (presets.any(
      (existing) => existing.name.trim().toLowerCase() == normalizedName,
    )) {
      throw StateError('Preset name already exists: $name');
    }
    final preset = UserPreset(
      id: _createId(),
      name: name,
      voltageHundredthsVolts: voltageHundredthsVolts,
      currentTenthsAmps: currentTenthsAmps,
    );
    if (presets.any((existing) => existing.id == preset.id)) {
      throw StateError('Preset id already exists: ${preset.id}');
    }
    await _saveUserPresets(<UserPreset>[...presets, preset]);
    return preset;
  }

  Future<void> updateUserPreset(UserPreset preset) async {
    ChargerParameterValidator.validateStatic(
      voltageHundredths: preset.voltageHundredthsVolts,
      currentTenths: preset.currentTenthsAmps,
    );
    final presets = await getUserPresets();
    final index = presets.indexWhere((existing) => existing.id == preset.id);
    if (index < 0) {
      throw StateError('Preset not found: ${preset.id}');
    }
    if (presets.any(
      (existing) =>
          existing.id != preset.id &&
          existing.name.trim().toLowerCase() ==
              preset.name.trim().toLowerCase(),
    )) {
      throw StateError('Preset name already exists: ${preset.name}');
    }
    final updated = presets.toList(growable: false);
    updated[index] = preset;
    await _saveUserPresets(updated);
  }

  Future<void> deleteUserPreset(String id) async {
    final presets = await getUserPresets();
    final updated = presets.where((preset) => preset.id != id).toList();
    if (updated.length == presets.length) {
      throw StateError('Preset not found: $id');
    }
    await _saveUserPresets(updated);
  }

  Future<void> reorderUserPreset(String id, int newIndex) async {
    final presets = (await getUserPresets()).toList();
    final oldIndex = presets.indexWhere((preset) => preset.id == id);
    if (oldIndex < 0) {
      throw StateError('Preset not found: $id');
    }
    if (newIndex < 0 || newIndex >= presets.length) {
      throw RangeError.range(newIndex, 0, presets.length - 1, 'newIndex');
    }
    final item = presets.removeAt(oldIndex);
    presets.insert(newIndex, item);
    await _saveUserPresets(presets);
  }

  Future<void> _saveUserPresets(List<UserPreset> presets) {
    return _store.setString(
      _userPresetsKey,
      jsonEncode(presets.map((preset) => preset.toJson()).toList()),
    );
  }

  static String _defaultId() =>
      DateTime.now().toUtc().microsecondsSinceEpoch.toString();
}

String _requiredText(String value, String name) {
  if (value.trim().isEmpty) {
    throw ArgumentError.value(value, name, 'Must not be empty.');
  }
  return value;
}
