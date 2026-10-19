import 'package:ads_charger/application/presets/preset_service.dart';
import 'package:ads_charger/infrastructure/storage/key_value_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PresetService default device', () {
    test('sets, replaces, and clears the local default device', () async {
      final store = MemoryKeyValueStore();
      final service = PresetService(store);
      final first = DefaultDeviceRecord(
        deviceKey: 'device-a',
        name: 'Garage charger',
        profileFingerprint: 'profile-a',
      );
      final replacement = DefaultDeviceRecord(
        deviceKey: 'device-b',
        name: 'Travel charger',
        profileFingerprint: 'profile-b',
      );

      expect(await service.getDefaultDevice(), isNull);

      await service.setDefaultDevice(first);
      expect((await service.getDefaultDevice())?.deviceKey, 'device-a');

      await service.setDefaultDevice(replacement);
      final loaded = await service.getDefaultDevice();
      expect(loaded?.deviceKey, 'device-b');
      expect(loaded?.name, 'Travel charger');
      expect(loaded?.profileFingerprint, 'profile-b');

      await service.clearDefaultDevice();
      expect(await service.getDefaultDevice(), isNull);

      await service.setDefaultDevice(
        DefaultDeviceRecord(deviceKey: 'scan-only', name: 'Unnamed device'),
      );
      final scanOnly = await service.getDefaultDevice();
      expect(scanOnly?.deviceKey, 'scan-only');
      expect(scanOnly?.profileFingerprint, isNull);
    });

    test(
      'returns null instead of throwing for damaged persisted data',
      () async {
        final store = MemoryKeyValueStore()
          ..values['presets.defaultDevice.v1'] = '{truncated';
        final service = PresetService(store);

        expect(await service.getDefaultDevice(), isNull);
      },
    );
  });

  group('PresetService user presets', () {
    test(
      'creates, reads, updates, and deletes integer-valued presets',
      () async {
        final store = MemoryKeyValueStore();
        final ids = <String>['preset-1', 'preset-2'].iterator;
        final service = PresetService(
          store,
          createId: () {
            ids.moveNext();
            return ids.current;
          },
        );

        final first = await service.createUserPreset(
          name: 'Daily',
          voltageHundredthsVolts: 5460,
          currentTenthsAmps: 125,
        );
        await service.createUserPreset(
          name: 'Storage',
          voltageHundredthsVolts: 5200,
          currentTenthsAmps: 50,
        );

        var presets = await service.getUserPresets();
        expect(presets.map((preset) => preset.id), ['preset-1', 'preset-2']);
        expect(presets.first.voltageHundredthsVolts, 5460);
        expect(presets.first.currentTenthsAmps, 125);

        await service.updateUserPreset(
          UserPreset(
            id: first.id,
            name: 'Daily updated',
            voltageHundredthsVolts: 5480,
            currentTenthsAmps: 130,
          ),
        );
        presets = await service.getUserPresets();
        expect(presets.first.name, 'Daily updated');
        expect(presets.first.voltageHundredthsVolts, 5480);

        await service.deleteUserPreset('preset-2');
        presets = await service.getUserPresets();
        expect(presets.single.id, 'preset-1');
      },
    );

    test('skips damaged entries and rejects invalid values', () async {
      final store = MemoryKeyValueStore()
        ..values['presets.userPresets.v1'] = '''
          [
            {"id":"ok","name":"Valid","voltageHundredthsVolts":5400,"currentTenthsAmps":100},
            {"id":"bad","name":"Broken","voltageHundredthsVolts":"5400","currentTenthsAmps":100},
            null
          ]
        ''';
      final service = PresetService(store, createId: () => 'new');

      final presets = await service.getUserPresets();
      expect(presets.single.id, 'ok');
      await expectLater(
        service.createUserPreset(
          name: 'Invalid',
          voltageHundredthsVolts: -1,
          currentTenthsAmps: 10,
        ),
        throwsA(isA<Exception>()),
      );
    });

    test('rejects duplicate names and persists explicit ordering', () async {
      final ids = <String>['one', 'two'].iterator;
      final service = PresetService(
        MemoryKeyValueStore(),
        createId: () {
          ids.moveNext();
          return ids.current;
        },
      );
      final first = await service.createUserPreset(
        name: 'Daily',
        voltageHundredthsVolts: 5400,
        currentTenthsAmps: 100,
      );
      final second = await service.createUserPreset(
        name: 'Storage',
        voltageHundredthsVolts: 5200,
        currentTenthsAmps: 50,
      );

      await expectLater(
        service.createUserPreset(
          name: ' daily ',
          voltageHundredthsVolts: 5400,
          currentTenthsAmps: 100,
        ),
        throwsStateError,
      );
      await service.reorderUserPreset(second.id, 0);
      expect(
        (await service.getUserPresets()).map((preset) => preset.id),
        <String>[second.id, first.id],
      );
    });

    test('reports update and delete of an unknown preset', () async {
      final service = PresetService(MemoryKeyValueStore());
      final missing = UserPreset(
        id: 'missing',
        name: 'Missing',
        voltageHundredthsVolts: 5000,
        currentTenthsAmps: 30,
      );

      await expectLater(service.updateUserPreset(missing), throwsStateError);
      await expectLater(service.deleteUserPreset('missing'), throwsStateError);
    });
  });
}

final class MemoryKeyValueStore implements KeyValueStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> getString(String key) async => values[key];

  @override
  Future<void> remove(String key) async {
    values.remove(key);
  }

  @override
  Future<void> setString(String key, String value) async {
    values[key] = value;
  }
}
