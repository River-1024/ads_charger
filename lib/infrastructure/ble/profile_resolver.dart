import '../../ports/ble_driver.dart';

BleProfileResolution resolveBleProfile(Iterable<BleGattService> services) {
  final notificationEndpoints = <BleCharacteristicRef>{};
  final writeEndpoints = <BleCharacteristicRef, BleGattCharacteristic>{};

  for (final service in services) {
    final serviceUuid = normalizeBleUuid(service.uuid);
    for (final characteristic in service.characteristics) {
      final characteristicUuid = normalizeBleUuid(characteristic.uuid);
      final endpoint = BleCharacteristicRef(
        serviceUuid: serviceUuid,
        characteristicUuid: characteristicUuid,
      );
      if (characteristic.canEmitValues) {
        notificationEndpoints.add(endpoint);
      }
      if (characteristic.canWrite) {
        final existing = writeEndpoints[endpoint];
        writeEndpoints[endpoint] = existing == null
            ? characteristic
            : BleGattCharacteristic(
                uuid: characteristicUuid,
                canWriteWithResponse:
                    existing.canWriteWithResponse ||
                    characteristic.canWriteWithResponse,
                canWriteWithoutResponse:
                    existing.canWriteWithoutResponse ||
                    characteristic.canWriteWithoutResponse,
              );
      }
    }
  }

  if (notificationEndpoints.isEmpty || writeEndpoints.isEmpty) {
    return BleProfileResolution.unsupported();
  }

  final candidates = <BleProfile>[];
  for (final notification in notificationEndpoints) {
    for (final entry in writeEndpoints.entries) {
      candidates.add(
        BleProfile(
          notificationCharacteristic: notification,
          writeCharacteristic: entry.key,
          canWriteWithResponse: entry.value.canWriteWithResponse,
          canWriteWithoutResponse: entry.value.canWriteWithoutResponse,
          fingerprint: buildBleProfileFingerprint(
            notificationCharacteristic: notification,
            writeCharacteristic: entry.key,
          ),
        ),
      );
    }
  }
  candidates.sort(
    (left, right) => left.fingerprint.compareTo(right.fingerprint),
  );

  return candidates.length == 1
      ? BleProfileResolution.ready(candidates.single)
      : BleProfileResolution.ambiguous(candidates);
}

String buildBleProfileFingerprint({
  required BleCharacteristicRef notificationCharacteristic,
  required BleCharacteristicRef writeCharacteristic,
}) {
  final notifyService = normalizeBleUuid(
    notificationCharacteristic.serviceUuid,
  );
  final notifyCharacteristic = normalizeBleUuid(
    notificationCharacteristic.characteristicUuid,
  );
  final writeService = normalizeBleUuid(writeCharacteristic.serviceUuid);
  final writeCharacteristicUuid = normalizeBleUuid(
    writeCharacteristic.characteristicUuid,
  );
  return 'notify:$notifyService/$notifyCharacteristic;'
      'write:$writeService/$writeCharacteristicUuid';
}

String normalizeBleUuid(String value) {
  var uuid = value.trim().toLowerCase();
  if (uuid.startsWith('{') && uuid.endsWith('}')) {
    uuid = uuid.substring(1, uuid.length - 1);
  }
  final compact = uuid.replaceAll('-', '');
  if (!RegExp(r'^[0-9a-f]+$').hasMatch(compact)) {
    return uuid;
  }
  if (compact.length == 4) {
    return '0000$compact-0000-1000-8000-00805f9b34fb';
  }
  if (compact.length == 8) {
    return '$compact-0000-1000-8000-00805f9b34fb';
  }
  if (compact.length == 32) {
    return '${compact.substring(0, 8)}-'
        '${compact.substring(8, 12)}-'
        '${compact.substring(12, 16)}-'
        '${compact.substring(16, 20)}-'
        '${compact.substring(20)}';
  }
  return uuid;
}
