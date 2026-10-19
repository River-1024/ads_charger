import 'package:ads_charger/infrastructure/ble/profile_resolver.dart';
import 'package:ads_charger/ports/ble_driver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BLE profile resolution', () {
    test('returns ready only for one notify/write pair', () {
      final result = resolveBleProfile([
        BleGattService(
          uuid: '180a',
          characteristics: const [
            BleGattCharacteristic(uuid: '2a56', canNotify: true),
            BleGattCharacteristic(uuid: '2a57', canWriteWithoutResponse: true),
          ],
        ),
      ]);

      expect(result.status, BleProfileResolutionStatus.ready);
      expect(result.candidates, hasLength(1));
      expect(result.profile!.canWriteWithoutResponse, isTrue);
      expect(result.profile!.canWriteWithResponse, isFalse);
    });

    test('returns unsupported when notify or write capability is absent', () {
      final notifyOnly = resolveBleProfile([
        BleGattService(
          uuid: '180a',
          characteristics: const [
            BleGattCharacteristic(uuid: '2a56', canNotify: true),
          ],
        ),
      ]);
      final writeOnly = resolveBleProfile([
        BleGattService(
          uuid: '180a',
          characteristics: const [
            BleGattCharacteristic(uuid: '2a57', canWriteWithResponse: true),
          ],
        ),
      ]);

      expect(notifyOnly.status, BleProfileResolutionStatus.unsupported);
      expect(writeOnly.status, BleProfileResolutionStatus.unsupported);
    });

    test(
      'returns ambiguous and preserves every candidate deterministically',
      () {
        final result = resolveBleProfile([
          BleGattService(
            uuid: '180a',
            characteristics: const [
              BleGattCharacteristic(uuid: '2a56', canNotify: true),
              BleGattCharacteristic(uuid: '2a57', canWriteWithResponse: true),
              BleGattCharacteristic(
                uuid: '2a58',
                canWriteWithoutResponse: true,
              ),
            ],
          ),
        ]);

        expect(result.status, BleProfileResolutionStatus.ambiguous);
        expect(result.candidates, hasLength(2));
        expect(
          result.candidates.map((candidate) => candidate.fingerprint).toList(),
          orderedEquals(
            result.candidates.map((candidate) => candidate.fingerprint).toList()
              ..sort(),
          ),
        );
      },
    );

    test('a dual-purpose characteristic creates one unique profile', () {
      final result = resolveBleProfile([
        BleGattService(
          uuid: '12345678-1234-5678-9abc-def012345678',
          characteristics: const [
            BleGattCharacteristic(
              uuid: 'abcdef01-1234-5678-9abc-def012345678',
              canNotify: true,
              canWriteWithResponse: true,
              canWriteWithoutResponse: true,
            ),
          ],
        ),
      ]);

      expect(result.status, BleProfileResolutionStatus.ready);
      expect(
        result.profile!.notificationCharacteristic,
        result.profile!.writeCharacteristic,
      );
    });
  });

  group('BLE profile fingerprint', () {
    test('is stable across UUID case, braces, and 16-bit expansion', () {
      final compact = buildBleProfileFingerprint(
        notificationCharacteristic: const BleCharacteristicRef(
          serviceUuid: '180A',
          characteristicUuid: '2A56',
        ),
        writeCharacteristic: const BleCharacteristicRef(
          serviceUuid: '{180A}',
          characteristicUuid: '2A57',
        ),
      );
      final expanded = buildBleProfileFingerprint(
        notificationCharacteristic: const BleCharacteristicRef(
          serviceUuid: '0000180a-0000-1000-8000-00805F9B34FB',
          characteristicUuid: '00002a56-0000-1000-8000-00805f9b34fb',
        ),
        writeCharacteristic: const BleCharacteristicRef(
          serviceUuid: '0000180a00001000800000805f9b34fb',
          characteristicUuid: '00002a57-0000-1000-8000-00805f9b34fb',
        ),
      );

      expect(compact, expanded);
      expect(
        compact,
        'notify:0000180a-0000-1000-8000-00805f9b34fb/'
        '00002a56-0000-1000-8000-00805f9b34fb;'
        'write:0000180a-0000-1000-8000-00805f9b34fb/'
        '00002a57-0000-1000-8000-00805f9b34fb',
      );
    });
  });
}
