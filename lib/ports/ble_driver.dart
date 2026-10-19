import 'dart:typed_data';

enum BleAdapterState {
  unknown,
  unsupported,
  unauthorized,
  poweredOff,
  locationServicesDisabled,
  ready,
}

enum BleConnectionState { connecting, connected, disconnecting, disconnected }

class BleScanDevice {
  BleScanDevice({
    required this.generation,
    required this.id,
    required this.name,
    required this.rssi,
    required List<int> manufacturerData,
    required List<String> advertisedServiceUuids,
  }) : manufacturerData = Uint8List.fromList(manufacturerData),
       advertisedServiceUuids = List.unmodifiable(advertisedServiceUuids);

  final int generation;
  final String id;
  final String name;
  final int rssi;
  final Uint8List manufacturerData;
  final List<String> advertisedServiceUuids;
}

class BleConnectionEvent {
  const BleConnectionEvent({
    required this.deviceId,
    required this.state,
    this.error,
  });

  final String deviceId;
  final BleConnectionState state;
  final Object? error;
}

class BleCharacteristicRef {
  const BleCharacteristicRef({
    required this.serviceUuid,
    required this.characteristicUuid,
  });

  final String serviceUuid;
  final String characteristicUuid;

  @override
  bool operator ==(Object other) =>
      other is BleCharacteristicRef &&
      serviceUuid == other.serviceUuid &&
      characteristicUuid == other.characteristicUuid;

  @override
  int get hashCode => Object.hash(serviceUuid, characteristicUuid);
}

class BleGattCharacteristic {
  const BleGattCharacteristic({
    required this.uuid,
    this.canNotify = false,
    this.canIndicate = false,
    this.canWriteWithResponse = false,
    this.canWriteWithoutResponse = false,
  });

  final String uuid;
  final bool canNotify;
  final bool canIndicate;
  final bool canWriteWithResponse;
  final bool canWriteWithoutResponse;

  bool get canEmitValues => canNotify || canIndicate;
  bool get canWrite => canWriteWithResponse || canWriteWithoutResponse;
}

class BleGattService {
  BleGattService({
    required this.uuid,
    required List<BleGattCharacteristic> characteristics,
  }) : characteristics = List.unmodifiable(characteristics);

  final String uuid;
  final List<BleGattCharacteristic> characteristics;
}

class BleProfile {
  const BleProfile({
    required this.notificationCharacteristic,
    required this.writeCharacteristic,
    required this.canWriteWithResponse,
    required this.canWriteWithoutResponse,
    required this.fingerprint,
  });

  final BleCharacteristicRef notificationCharacteristic;
  final BleCharacteristicRef writeCharacteristic;
  final bool canWriteWithResponse;
  final bool canWriteWithoutResponse;
  final String fingerprint;
}

enum BleProfileResolutionStatus { ready, ambiguous, unsupported }

class BleProfileResolution {
  BleProfileResolution._({
    required this.status,
    required List<BleProfile> candidates,
  }) : candidates = List.unmodifiable(candidates);

  factory BleProfileResolution.ready(BleProfile profile) =>
      BleProfileResolution._(
        status: BleProfileResolutionStatus.ready,
        candidates: [profile],
      );

  factory BleProfileResolution.ambiguous(List<BleProfile> candidates) =>
      BleProfileResolution._(
        status: BleProfileResolutionStatus.ambiguous,
        candidates: candidates,
      );

  factory BleProfileResolution.unsupported() => BleProfileResolution._(
    status: BleProfileResolutionStatus.unsupported,
    candidates: const [],
  );

  final BleProfileResolutionStatus status;
  final List<BleProfile> candidates;

  BleProfile? get profile =>
      status == BleProfileResolutionStatus.ready ? candidates.single : null;
}

abstract interface class BleDriver {
  BleAdapterState get adapterState;
  Stream<BleAdapterState> get adapterStateChanges;

  /// Starts a new scan session for [generation]. Implementations must only emit
  /// observations produced by that session; previously cached scan results must
  /// never be replayed as current evidence.
  Stream<BleScanDevice> scan({required int generation});

  /// Cancelling the subscription disconnects the peripheral.
  Stream<BleConnectionEvent> connect({
    required String deviceId,
    Duration? timeout,
  });

  Future<BleProfileResolution> discoverProfile(String deviceId);

  /// Returns the negotiated MTU, or null on platforms where the driver does not
  /// actively request one.
  Future<int?> requestMtu(String deviceId, {int desiredMtu = 247});

  Stream<List<int>> notifications({
    required String deviceId,
    required BleCharacteristicRef characteristic,
  });

  Future<void> writeWithoutResponse({
    required String deviceId,
    required BleCharacteristicRef characteristic,
    required List<int> value,
  });

  Future<void> writeWithResponse({
    required String deviceId,
    required BleCharacteristicRef characteristic,
    required List<int> value,
  });
}
