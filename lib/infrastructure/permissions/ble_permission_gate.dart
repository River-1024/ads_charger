import 'dart:io';

import 'package:permission_handler/permission_handler.dart';

enum BlePermissionResult { granted, denied, permanentlyDenied }

abstract interface class BlePermissionGate {
  Future<BlePermissionResult> requestForScan();

  Future<void> openSettings();
}

class MobileBlePermissionGate implements BlePermissionGate {
  const MobileBlePermissionGate();

  @override
  Future<BlePermissionResult> requestForScan() async {
    if (Platform.isAndroid) {
      final statuses = await <Permission>[
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
      ].request();
      return classifyBlePermissionStatuses(statuses.values);
    }
    if (Platform.isIOS) {
      return classifyBlePermissionStatuses(<PermissionStatus>[
        await Permission.bluetooth.request(),
      ]);
    }
    return BlePermissionResult.granted;
  }

  @override
  Future<void> openSettings() => openAppSettings();
}

BlePermissionResult classifyBlePermissionStatuses(
  Iterable<PermissionStatus> statuses,
) {
  final values = statuses.toList(growable: false);
  if (values.any(
    (status) => status.isPermanentlyDenied || status.isRestricted,
  )) {
    return BlePermissionResult.permanentlyDenied;
  }
  if (values.any((status) => !status.isGranted && !status.isLimited)) {
    return BlePermissionResult.denied;
  }
  return BlePermissionResult.granted;
}
