import 'dart:async';
import 'dart:io';

import 'package:ads_charger/application/session/charger_session_actor.dart';
import 'package:ads_charger/domain/charger_models/lock_target.dart';
import 'package:ads_charger/domain/charger_protocol/charger_protocol.dart';
import 'package:ads_charger/domain/charger_protocol/crc8.dart';
import 'package:ads_charger/infrastructure/storage/parameter_write_journal.dart';
import 'package:ads_charger/ports/ble_driver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('scan only exposes current generation observations', () async {
    final driver = _FakeBleDriver();
    final directory = await Directory.systemTemp.createTemp('ads-session-');
    addTearDown(() => directory.delete(recursive: true));
    final actor = ChargerSessionActor(
      driver: driver,
      journal: await ParameterWriteJournal.create(directory: directory),
    );
    await actor.initialize();

    await actor.startScan(duration: const Duration(seconds: 2));
    driver.scanController.add(_device(generation: actor.scanGeneration - 1));
    driver.scanController.add(_device(generation: actor.scanGeneration));
    await _pumpEvents();

    expect(actor.devices, hasLength(1));
    expect(actor.devices.single.generation, actor.scanGeneration);
    actor.dispose();
  });

  test(
    'valid 02 enables guarded parameter writing for the discovered profile',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      await fixture.connect();

      expect(fixture.actor.isReadVerified, isTrue);
      expect(fixture.actor.isWriteVerified, isTrue);
      expect(fixture.actor.parameters?.voltageHundredths, 5460);
      await _waitUntil(() => fixture.actor.status != null);
      expect(fixture.driver.statusQueryCount, greaterThanOrEqualTo(1));
    },
  );

  test('initial connection timeout exposes a manual retry state', () async {
    final directory = await Directory.systemTemp.createTemp('ads-timeout-');
    final driver = _FakeBleDriver(autoConnect: false);
    final actor = ChargerSessionActor(
      driver: driver,
      journal: await ParameterWriteJournal.create(directory: directory),
      connectionTimeout: const Duration(milliseconds: 30),
    );
    addTearDown(() async {
      actor.dispose();
      await driver.dispose();
      await directory.delete(recursive: true);
    });
    await actor.initialize();

    await actor.connectKnownDevice(
      deviceId: 'AA:BB:CC:DD:EE:01',
      deviceName: 'ADS Charger',
    );
    await _waitUntil(() => actor.phase == ChargerSessionPhase.failed);

    expect(actor.errorMessage, contains('请点击重连'));
    expect(actor.connectedDeviceId, 'AA:BB:CC:DD:EE:01');
  });

  test(
    'default binding is blocked until a valid 02 reply is accepted',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      expect(fixture.actor.ensureDefaultBindingAllowed, throwsStateError);
      await fixture.connect();
      expect(fixture.actor.ensureDefaultBindingAllowed, returnsNormally);
    },
  );

  test(
    'journal recovery connects only exact device and never resends 03',
    () async {
      final directory = await Directory.systemTemp.createTemp('ads-recovery-');
      addTearDown(() => directory.delete(recursive: true));
      final journal = await ParameterWriteJournal.create(directory: directory);
      await journal.write(
        ParameterWriteJournalEntry(
          operationId: 'recovery-op',
          targetDeviceKey: 'AA:BB:CC:DD:EE:01',
          profileFingerprint: 'fixture-profile',
          targetVoltageHundredthsVolts: 5460,
          targetCurrentTenthsAmps: 30,
          stage: ParameterWriteStage.applied,
          updatedAt: DateTime.now(),
        ),
      );
      final driver = _FakeBleDriver();
      final actor = ChargerSessionActor(driver: driver, journal: journal);
      addTearDown(() async {
        actor.dispose();
        await driver.dispose();
      });
      await actor.initialize();
      await actor.startScan(duration: const Duration(seconds: 2));
      driver.scanController.add(_device(generation: actor.scanGeneration));
      await _waitUntil(
        () => actor.lastWriteResult?.outcome == ParameterWriteOutcome.verified,
      );
      expect(driver.setWriteCount, 0);
      expect(actor.connectedDeviceId, 'AA:BB:CC:DD:EE:01');
      expect(await journal.recover(), isNull);
    },
  );

  test(
    'late target-looking 02 replies are drained before fresh verification',
    () async {
      final fixture = await _Fixture.create(applySet: false);
      addTearDown(fixture.dispose);
      await fixture.connect();
      fixture.driver.emitStaleTargetAfterSet = true;
      final result = await fixture.actor.writeLithiumParameters(
        voltageHundredths: 5800,
        currentTenths: 120,
      );
      expect(fixture.driver.setWriteCount, 1);
      expect(result.outcome, ParameterWriteOutcome.mismatch);
      expect(result.actual?.voltageHundredths, 5460);
    },
  );

  test(
    'one confirmation sends one 03 and succeeds only after two new 02 replies',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      await fixture.connect();

      final result = await fixture.actor.writeLithiumParameters(
        voltageHundredths: 5800,
        currentTenths: 120,
      );

      expect(result.outcome, ParameterWriteOutcome.verified);
      expect(fixture.driver.setWriteCount, 1);
      expect(fixture.driver.parameterQueryCount, greaterThanOrEqualTo(3));
      expect(await fixture.journal.recover(), isNull);
    },
  );

  group('mini program home page control writes', () {
    test(
      'force activation sends one 04 and is never reported as verified',
      () async {
        final fixture = await _Fixture.create();
        addTearDown(fixture.dispose);
        await fixture.connect();
        final queriesBefore = fixture.driver.parameterQueryCount;

        final result = await fixture.actor.operateControl(
          operationId: 'activate-op',
          settleDelay: Duration.zero,
        );

        expect(fixture.driver.activateWriteCount, 1);
        expect(fixture.driver.lockWriteCount, 0);
        expect(result.outcome, ControlWriteOutcome.acknowledgedUnverified);
        expect(result.isAcknowledged, isTrue);
        expect(result.isVerified, isFalse);
        expect(result.parameters, isNull);
        // The charger does not expose an activation field in 02, so no readback
        // is attempted and no success is claimed.
        expect(fixture.driver.parameterQueryCount, queriesBefore);
        expect(fixture.actor.lastControlResult, isNotNull);
      },
    );

    test(
      'lock adjustment is verified only by the fresh 02 lock flag',
      () async {
        final fixture = await _Fixture.create();
        addTearDown(fixture.dispose);
        await fixture.connect();
        expect(fixture.actor.currentLockTarget, LockTarget.unlock);

        final result = await fixture.actor.operateControl(
          operationId: 'lock-op',
          targetLock: LockTarget.lock,
          settleDelay: Duration.zero,
        );

        expect(fixture.driver.lockWriteCount, 1);
        expect(result.outcome, ControlWriteOutcome.acknowledged);
        expect(result.targetLock, LockTarget.lock);
        expect(result.parameters?.lockRaw, 0xA0);
        expect(fixture.actor.parameters?.lockRaw, 0xA0);
        expect(fixture.actor.currentLockTarget, LockTarget.lock);
      },
    );

    test('unlock adjustment waits for the 06 acknowledgement', () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      fixture.driver.lockRaw = 0xA0;
      await fixture.connect();
      expect(fixture.actor.currentLockTarget, LockTarget.lock);

      final result = await fixture.actor.operateControl(
        operationId: 'unlock-op',
        targetLock: LockTarget.unlock,
        settleDelay: Duration.zero,
      );

      expect(fixture.driver.lockWriteCount, 1);
      expect(result.outcome, ControlWriteOutcome.acknowledged);
      expect(result.targetLock, LockTarget.unlock);
      expect(result.parameters?.lockRaw, 0x0A);
      expect(result.message, contains('06 应答帧'));
      expect(fixture.actor.currentLockTarget, LockTarget.unlock);
    });

    test(
      'same lock target is refused before any control frame is sent',
      () async {
        final fixture = await _Fixture.create();
        addTearDown(fixture.dispose);
        fixture.driver.lockRaw = 0xA0;
        await fixture.connect();

        final result = await fixture.actor.operateControl(
          operationId: 'repeat-lock-op',
          targetLock: LockTarget.lock,
          settleDelay: Duration.zero,
        );

        expect(fixture.driver.lockWriteCount, 0);
        expect(result.outcome, ControlWriteOutcome.unacknowledged);
        expect(result.message, contains('未发送控制帧'));
        expect(result.message, contains('已与目标一致'));
      },
    );

    test(
      'a 05 acknowledgement without a matching readback stays unconfirmed',
      () async {
        final fixture = await _Fixture.create(applyLock: false);
        addTearDown(fixture.dispose);
        await fixture.connect();

        final result = await fixture.actor.operateControl(
          operationId: 'lock-op',
          targetLock: LockTarget.lock,
          settleDelay: Duration.zero,
        );

        expect(fixture.driver.lockWriteCount, 1);
        expect(result.outcome, ControlWriteOutcome.unacknowledged);
        expect(result.targetLock, LockTarget.lock);
        // The device acknowledged with 05 but never applied the requested flag, so
        // no verified readback is reported. The observed 0x0A still reaches the
        // UI through the session's published parameters.
        expect(result.isVerified, isFalse);
        expect(result.message, contains('但新 02 读回锁定标志'));
        expect(fixture.actor.parameters?.lockRaw, 0x0A);
      },
    );

    test('a missing acknowledgement never resends the control frame', () async {
      final fixture = await _Fixture.create(emitAck: false);
      addTearDown(fixture.dispose);
      await fixture.connect();

      final result = await fixture.actor.operateControl(
        operationId: 'lock-op',
        targetLock: LockTarget.lock,
        settleDelay: Duration.zero,
      );

      expect(fixture.driver.lockWriteCount, 1);
      expect(result.outcome, ControlWriteOutcome.unacknowledged);
      expect(result.message, contains('已发送一次控制帧'));
      expect(result.message, contains('未取得属于本次操作的有效应答'));
    });

    test('control writes are refused before a valid 02 reply', () async {
      final directory = await Directory.systemTemp.createTemp('ads-control-');
      final driver = _FakeBleDriver();
      final actor = ChargerSessionActor(
        driver: driver,
        journal: await ParameterWriteJournal.create(directory: directory),
      );
      addTearDown(() async {
        actor.dispose();
        await driver.dispose();
        await directory.delete(recursive: true);
      });
      await actor.initialize();

      expect(actor.canOperateControl, isFalse);
      final result = await actor.operateControl(
        operationId: 'activate-op',
        settleDelay: Duration.zero,
      );
      expect(result.outcome, ControlWriteOutcome.unacknowledged);
      expect(driver.activateWriteCount, 0);
      expect(driver.lockWriteCount, 0);
    });

    test('an empty operation id sends nothing', () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      await fixture.connect();

      expect(
        () => fixture.actor.operateControl(operationId: '   '),
        throwsStateError,
      );
      await _pumpEvents();
      expect(fixture.driver.activateWriteCount, 0);
      expect(fixture.driver.lockWriteCount, 0);
    });
  });
}

class _Fixture {
  _Fixture(this.driver, this.actor, this.journal, this.directory);

  final _FakeBleDriver driver;
  final ChargerSessionActor actor;
  final ParameterWriteJournal journal;
  final Directory directory;

  static Future<_Fixture> create({
    bool applySet = true,
    bool applyLock = true,
    bool emitAck = true,
  }) async {
    final directory = await Directory.systemTemp.createTemp('ads-session-');
    final journal = await ParameterWriteJournal.create(directory: directory);
    final driver = _FakeBleDriver(
      applySet: applySet,
      applyLock: applyLock,
      emitAck: emitAck,
    );
    final actor = ChargerSessionActor(driver: driver, journal: journal);
    await actor.initialize();
    return _Fixture(driver, actor, journal, directory);
  }

  Future<void> connect() async {
    await actor.connect(_device(generation: 1));
    await _waitUntil(() => actor.isReadVerified);
  }

  Future<void> dispose() async {
    actor.dispose();
    await driver.dispose();
    await directory.delete(recursive: true);
  }
}

class _FakeBleDriver implements BleDriver {
  _FakeBleDriver({
    this.applySet = true,
    this.autoConnect = true,
    this.applyLock = true,
    this.emitAck = true,
  });

  final bool applySet;
  final bool autoConnect;

  /// Whether a command 09 write actually changes the 02 lock flag, so tests can
  /// tell "acknowledged and confirmed" from "acknowledged but not applied".
  final bool applyLock;

  /// Whether command 04/09 produce the mini program's `04`/`05`/`06`
  /// acknowledgement at all.
  final bool emitAck;
  bool emitStaleTargetAfterSet = false;
  final StreamController<BleScanDevice> scanController =
      StreamController<BleScanDevice>.broadcast();
  final StreamController<BleConnectionEvent> connectionController =
      StreamController<BleConnectionEvent>.broadcast();
  final StreamController<List<int>> notificationController =
      StreamController<List<int>>.broadcast();

  final BleProfile profile = const BleProfile(
    notificationCharacteristic: BleCharacteristicRef(
      serviceUuid: '1000',
      characteristicUuid: '1001',
    ),
    writeCharacteristic: BleCharacteristicRef(
      serviceUuid: '1000',
      characteristicUuid: '1002',
    ),
    canWriteWithResponse: false,
    canWriteWithoutResponse: true,
    fingerprint: 'fixture-profile',
  );

  int setWriteCount = 0;
  int parameterQueryCount = 0;
  int statusQueryCount = 0;
  int activateWriteCount = 0;
  int lockWriteCount = 0;
  int voltage = 5460;
  int current = 30;
  int lockRaw = 0x0A;

  @override
  BleAdapterState get adapterState => BleAdapterState.ready;

  @override
  Stream<BleAdapterState> get adapterStateChanges =>
      const Stream<BleAdapterState>.empty();

  @override
  Stream<BleScanDevice> scan({required int generation}) =>
      scanController.stream;

  @override
  Stream<BleConnectionEvent> connect({
    required String deviceId,
    Duration? timeout,
  }) {
    if (autoConnect) {
      scheduleMicrotask(
        () => connectionController.add(
          BleConnectionEvent(
            deviceId: deviceId,
            state: BleConnectionState.connected,
          ),
        ),
      );
    }
    return connectionController.stream;
  }

  @override
  Future<BleProfileResolution> discoverProfile(String deviceId) async =>
      BleProfileResolution.ready(profile);

  @override
  Future<int?> requestMtu(String deviceId, {int desiredMtu = 247}) async => 247;

  @override
  Stream<List<int>> notifications({
    required String deviceId,
    required BleCharacteristicRef characteristic,
  }) => notificationController.stream;

  @override
  Future<void> writeWithResponse({
    required String deviceId,
    required BleCharacteristicRef characteristic,
    required List<int> value,
  }) => _write(value);

  @override
  Future<void> writeWithoutResponse({
    required String deviceId,
    required BleCharacteristicRef characteristic,
    required List<int> value,
  }) => _write(value);

  Future<void> _write(List<int> value) async {
    if (value[2] == 0x03) {
      setWriteCount += 1;
      final targetVoltage = (value[3] << 8) | value[4];
      final targetCurrent = (value[5] << 8) | value[6];
      if (emitStaleTargetAfterSet) {
        Future<void>.delayed(
          const Duration(milliseconds: 50),
          () => notificationController.add(
            _parametersFrame(voltage: targetVoltage, current: targetCurrent),
          ),
        );
        Future<void>.delayed(
          const Duration(milliseconds: 120),
          () => notificationController.add(
            _parametersFrame(voltage: targetVoltage, current: targetCurrent),
          ),
        );
      }
      if (applySet) {
        voltage = targetVoltage;
        current = targetCurrent;
      }
      return;
    }
    if (value[2] == 0x02) {
      parameterQueryCount += 1;
      scheduleMicrotask(
        () => notificationController.add(
          _parametersFrame(
            voltage: voltage,
            current: current,
            lockRaw: lockRaw,
          ),
        ),
      );
      return;
    }
    if (value[2] == 0x04) {
      activateWriteCount += 1;
      if (emitAck) {
        scheduleMicrotask(
          () => notificationController.add(_controlAckFrame(0x04)),
        );
      }
      return;
    }
    if (value[2] == 0x09) {
      lockWriteCount += 1;
      final requested = value[3];
      if (applyLock) {
        lockRaw = requested;
      }
      if (emitAck) {
        final acknowledgement = requested == LockTarget.lock.wireByte
            ? ChargerProtocol.lockAckCommand
            : ChargerProtocol.unlockAckCommand;
        scheduleMicrotask(
          () => notificationController.add(
            _controlAckFrame(
              acknowledgement,
              timerRaw: acknowledgement == ChargerProtocol.lockAckCommand
                  ? 120
                  : null,
            ),
          ),
        );
      }
      return;
    }
    if (value[2] == 0x01) {
      statusQueryCount += 1;
      scheduleMicrotask(() => notificationController.add(_statusFrame()));
    }
  }

  Future<void> dispose() async {
    await scanController.close();
    await connectionController.close();
    await notificationController.close();
  }
}

BleScanDevice _device({required int generation}) => BleScanDevice(
  generation: generation,
  id: 'AA:BB:CC:DD:EE:01',
  name: 'ADS Charger',
  rssi: -45,
  manufacturerData: const <int>[],
  advertisedServiceUuids: const <String>[],
);

List<int> _parametersFrame({
  required int voltage,
  required int current,
  int lockRaw = 0x0A,
}) {
  final frame = List<int>.filled(27, 0);
  frame[0] = 0xA5;
  frame[1] = 0x5A;
  frame[2] = 0x02;
  frame[3] = voltage >> 8;
  frame[4] = voltage & 0xff;
  frame[5] = current >> 8;
  frame[6] = current & 0xff;
  frame[7] = 1;
  frame[8] = 0;
  frame[9] = 30;
  frame[12] = lockRaw;
  frame[24] = 0;
  frame[25] = 60;
  frame[26] = ChargerCrc8.compute(frame.take(26));
  return frame;
}

/// Builds a `04`/`05`/`06` acknowledgement. The `05` variant carries the timer
/// value at offsets 17..18 exactly where the mini program reads it.
List<int> _controlAckFrame(int command, {int? timerRaw}) {
  final frame = List<int>.filled(20, 0);
  frame[0] = 0xA5;
  frame[1] = 0x5A;
  frame[2] = command;
  if (timerRaw != null) {
    frame[17] = (timerRaw >> 8) & 0xff;
    frame[18] = timerRaw & 0xff;
  }
  frame[19] = ChargerCrc8.compute(frame.take(19));
  return frame;
}

List<int> _statusFrame() {
  final frame = List<int>.filled(18, 0);
  frame[0] = 0xA5;
  frame[1] = 0x5A;
  frame[2] = 0x01;
  frame[17] = ChargerCrc8.compute(frame.take(17));
  return frame;
}

Future<void> _pumpEvents() =>
    Future<void>.delayed(const Duration(milliseconds: 30));

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition not met');
    }
    await _pumpEvents();
  }
}
