import 'package:ads_charger/infrastructure/permissions/ble_permission_gate.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  test('permission classification distinguishes retry and settings cases', () {
    expect(
      classifyBlePermissionStatuses(const <PermissionStatus>[
        PermissionStatus.granted,
        PermissionStatus.limited,
      ]),
      BlePermissionResult.granted,
    );
    expect(
      classifyBlePermissionStatuses(const <PermissionStatus>[
        PermissionStatus.granted,
        PermissionStatus.denied,
      ]),
      BlePermissionResult.denied,
    );
    expect(
      classifyBlePermissionStatuses(const <PermissionStatus>[
        PermissionStatus.permanentlyDenied,
      ]),
      BlePermissionResult.permanentlyDenied,
    );
  });
}
