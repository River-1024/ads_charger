import 'package:flutter/foundation.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart' as reactive;

import '../../ports/ble_driver.dart';
import 'profile_resolver.dart';

class FlutterReactiveBleDriver implements BleDriver {
  FlutterReactiveBleDriver({
    reactive.FlutterReactiveBle? ble,
    TargetPlatform? platform,
  }) : _ble = ble ?? reactive.FlutterReactiveBle(),
       _platform = platform ?? defaultTargetPlatform;

  final reactive.FlutterReactiveBle _ble;
  final TargetPlatform _platform;

  @override
  BleAdapterState get adapterState => _mapAdapterState(_ble.status);

  @override
  Stream<BleAdapterState> get adapterStateChanges =>
      _ble.statusStream.map(_mapAdapterState).distinct();

  @override
  Stream<BleScanDevice> scan({required int generation}) {
    // A new plugin scan stream is created per call. Do not use a replaying or
    // driver-owned cache: generation must describe only this physical scan.
    return _ble
        .scanForDevices(withServices: const [])
        .map(
          (device) => BleScanDevice(
            generation: generation,
            id: device.id,
            name: device.name,
            rssi: device.rssi,
            manufacturerData: device.manufacturerData,
            advertisedServiceUuids: device.serviceUuids
                .map((uuid) => uuid.expanded.toString())
                .toList(growable: false),
          ),
        );
  }

  @override
  Stream<BleConnectionEvent> connect({
    required String deviceId,
    Duration? timeout,
  }) {
    return _ble
        .connectToDevice(id: deviceId, connectionTimeout: timeout)
        .map(
          (update) => BleConnectionEvent(
            deviceId: update.deviceId,
            state: _mapConnectionState(update.connectionState),
            error: update.failure,
          ),
        );
  }

  @override
  Future<BleProfileResolution> discoverProfile(String deviceId) async {
    await _ble.discoverAllServices(deviceId);
    final services = await _ble.getDiscoveredServices(deviceId);
    return resolveBleProfile(
      services.map(
        (service) => BleGattService(
          uuid: service.id.expanded.toString(),
          characteristics: service.characteristics
              .map(
                (characteristic) => BleGattCharacteristic(
                  uuid: characteristic.id.expanded.toString(),
                  canNotify: characteristic.isNotifiable,
                  canIndicate: characteristic.isIndicatable,
                  canWriteWithResponse: characteristic.isWritableWithResponse,
                  canWriteWithoutResponse:
                      characteristic.isWritableWithoutResponse,
                ),
              )
              .toList(growable: false),
        ),
      ),
    );
  }

  @override
  Future<int?> requestMtu(String deviceId, {int desiredMtu = 247}) {
    if (_platform != TargetPlatform.android) {
      // iOS negotiates MTU implicitly; do not claim or attempt active control.
      return Future<int?>.value(null);
    }
    final requestedMtu = desiredMtu < 30 ? 30 : desiredMtu;
    return _ble.requestMtu(deviceId: deviceId, mtu: requestedMtu);
  }

  @override
  Stream<List<int>> notifications({
    required String deviceId,
    required BleCharacteristicRef characteristic,
  }) {
    return _ble.subscribeToCharacteristic(_qualified(deviceId, characteristic));
  }

  @override
  Future<void> writeWithoutResponse({
    required String deviceId,
    required BleCharacteristicRef characteristic,
    required List<int> value,
  }) {
    return _ble.writeCharacteristicWithoutResponse(
      _qualified(deviceId, characteristic),
      value: value,
    );
  }

  @override
  Future<void> writeWithResponse({
    required String deviceId,
    required BleCharacteristicRef characteristic,
    required List<int> value,
  }) {
    return _ble.writeCharacteristicWithResponse(
      _qualified(deviceId, characteristic),
      value: value,
    );
  }

  reactive.QualifiedCharacteristic _qualified(
    String deviceId,
    BleCharacteristicRef characteristic,
  ) {
    return reactive.QualifiedCharacteristic(
      deviceId: deviceId,
      serviceId: reactive.Uuid.parse(characteristic.serviceUuid),
      characteristicId: reactive.Uuid.parse(characteristic.characteristicUuid),
    );
  }
}

BleAdapterState _mapAdapterState(reactive.BleStatus status) => switch (status) {
  reactive.BleStatus.unknown => BleAdapterState.unknown,
  reactive.BleStatus.unsupported => BleAdapterState.unsupported,
  reactive.BleStatus.unauthorized => BleAdapterState.unauthorized,
  reactive.BleStatus.poweredOff => BleAdapterState.poweredOff,
  reactive.BleStatus.locationServicesDisabled =>
    BleAdapterState.locationServicesDisabled,
  reactive.BleStatus.ready => BleAdapterState.ready,
};

BleConnectionState _mapConnectionState(reactive.DeviceConnectionState state) =>
    switch (state) {
      reactive.DeviceConnectionState.connecting =>
        BleConnectionState.connecting,
      reactive.DeviceConnectionState.connected => BleConnectionState.connected,
      reactive.DeviceConnectionState.disconnecting =>
        BleConnectionState.disconnecting,
      reactive.DeviceConnectionState.disconnected =>
        BleConnectionState.disconnected,
    };
