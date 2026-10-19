import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../domain/charger_models/charger_parameters.dart';
import '../../domain/charger_models/charger_status.dart';
import '../../domain/charger_models/lock_target.dart';
import '../../domain/charger_protocol/charger_protocol.dart';
import '../../infrastructure/diagnostics/diagnostic_log.dart';
import '../../infrastructure/storage/parameter_write_journal.dart';
import '../../ports/ble_driver.dart';

enum ChargerSessionPhase {
  idle,
  scanning,
  connecting,
  discoveringServices,
  subscribing,
  linkReady,
  readProtocolVerified,
  writeCompatibilityVerified,
  reconnecting,
  disconnected,
  failed,
}

enum ParameterWriteOutcome { verified, mismatch, inconclusive }

/// Outcome of a command `04`/`09` control write.
///
/// [acknowledged] means the device echoed the expected `04`/`05`/`06`
/// acknowledgement and the requested state was confirmed by a fresh 02
/// readback. [acknowledgedUnverified] means the acknowledgement arrived but the
/// command has no 02 field that can prove execution (force activation).
/// [unacknowledged] means the write may have reached the device but no usable
/// evidence came back; the app must not claim success.
enum ControlWriteOutcome {
  acknowledged,
  acknowledgedUnverified,
  unacknowledged,
}

class ControlWriteResult {
  const ControlWriteResult({
    required this.operationId,
    required this.outcome,
    required this.label,
    this.targetLock,
    this.parameters,
    this.message,
  });

  final String operationId;
  final ControlWriteOutcome outcome;
  final String label;

  /// Requested direction for command 09, or `null` for force activation.
  final LockTarget? targetLock;

  /// Latest 02 parameters accepted during this operation, when available.
  final ChargerParameters? parameters;
  final String? message;

  bool get isVerified => outcome == ControlWriteOutcome.acknowledged;

  /// Force activation cannot be read back from 02. It is still a delivered,
  /// acknowledged request, but the app must not label it as verified.
  bool get isAcknowledged => outcome != ControlWriteOutcome.unacknowledged;
}

class ParameterWriteResult {
  const ParameterWriteResult({
    required this.outcome,
    required this.targetVoltageHundredths,
    required this.targetCurrentTenths,
    this.actual,
    this.message,
  });

  final ParameterWriteOutcome outcome;
  final int targetVoltageHundredths;
  final int targetCurrentTenths;
  final ChargerParameters? actual;
  final String? message;
}

class ChargerSessionActor extends ChangeNotifier {
  ChargerSessionActor({
    required this._driver,
    required this._journal,
    DiagnosticLog? diagnostics,
    this._connectionTimeout = const Duration(seconds: 10),
  }) : diagnostics = diagnostics ?? DiagnosticLog();

  final BleDriver _driver;
  final ParameterWriteJournal _journal;
  final DiagnosticLog diagnostics;
  final Duration _connectionTimeout;
  final Map<String, BleScanDevice> _devices = <String, BleScanDevice>{};

  StreamSubscription<BleScanDevice>? _scanSubscription;
  StreamSubscription<BleConnectionEvent>? _connectionSubscription;
  StreamSubscription<List<int>>? _notificationSubscription;
  Timer? _scanTimer;
  Timer? _pollTimer;
  Timer? _connectionAttemptTimer;
  Future<void> _serial = Future<void>.value();
  Completer<List<int>>? _replyCompleter;
  int? _expectedReplyCommand;
  int _scanGeneration = 0;
  int _connectionEpoch = 0;
  bool _intentionalDisconnect = false;
  bool _disposed = false;
  bool _commandBusy = false;
  bool _writeOperationActive = false;
  bool _controlWriteActive = false;
  bool _statusPollingEnabled = false;
  int _reconnectAttempts = 0;
  DateTime? _lastNotificationAt;
  ParameterWriteJournalEntry? _pendingRecovery;
  bool _recoveryConnectScheduled = false;
  bool _hasEstablishedLink = false;

  ChargerSessionPhase phase = ChargerSessionPhase.idle;
  BleAdapterState adapterState = BleAdapterState.unknown;
  String? errorMessage;
  String? connectedDeviceId;
  String? connectedDeviceName;
  BleProfile? profile;
  ChargerStatus? status;
  ChargerParameters? parameters;
  DateTime? statusUpdatedAt;
  DateTime? parametersUpdatedAt;
  ParameterWriteResult? lastWriteResult;
  ControlWriteResult? lastControlResult;

  ParameterWriteJournalEntry? get pendingRecovery => _pendingRecovery;

  /// Whether the charger-control writes ported from the mini program home page
  /// (command 04 force activation and command 09 lock adjustment) may be sent.
  ///
  /// This gate is deliberately separate from [isWriteVerified]: that flag is the
  ///型号 allowlist for the lithium 03 parameter write, while 04/09 are fixed
  /// one-byte control frames whose result is verified against the lock flag of a
  /// fresh 02 reply instead of a fingerprint allowlist.
  bool get canOperateControl => isReadVerified && !_commandBusy;

  /// The lock direction the latest valid 02 reply reports. The UI preselects
  /// this so the user always picks an explicit target instead of toggling a
  /// local guess.
  LockTarget? get currentLockTarget {
    final value = parameters;
    if (value == null) return null;
    return LockTarget.fromLockRaw(value.lockRaw);
  }

  UnmodifiableListView<BleScanDevice> get devices => UnmodifiableListView(
    _devices.values.toList()..sort((a, b) => b.rssi.compareTo(a.rssi)),
  );

  int get scanGeneration => _scanGeneration;
  int get connectionEpoch => _connectionEpoch;
  bool get isScanning => phase == ChargerSessionPhase.scanning;
  bool get isConnected => connectedDeviceId != null && profile != null;
  bool get isReadVerified =>
      phase == ChargerSessionPhase.readProtocolVerified ||
      phase == ChargerSessionPhase.writeCompatibilityVerified;
  bool get isWriteVerified => profile != null && isReadVerified;
  String? get profileFingerprint => profile?.fingerprint;
  void ensureDefaultBindingAllowed() {
    if (!isReadVerified || connectedDeviceId == null || profile == null) {
      throw StateError('默认设备只能在有效 02 参数验证后保存。');
    }
  }

  String? get deviceSuffix {
    final value = connectedDeviceId;
    if (value == null || value.isEmpty) return null;
    final compact = value.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    final suffix = compact.length <= 6
        ? compact
        : compact.substring(compact.length - 6);
    return suffix.toUpperCase();
  }

  Future<void> initialize() async {
    adapterState = _driver.adapterState;
    _driver.adapterStateChanges.listen((value) {
      _enqueue(() async {
        adapterState = value;
        diagnostics.add(DiagnosticKind.adapter, value.name);
        notifyListeners();
      });
    });
    final pending = await _journal.recover();
    _pendingRecovery = pending;
    _recoveryConnectScheduled = false;
    if (pending != null) {
      lastWriteResult = ParameterWriteResult(
        outcome: ParameterWriteOutcome.inconclusive,
        targetVoltageHundredths: pending.targetVoltageHundredthsVolts,
        targetCurrentTenths: pending.targetCurrentTenthsAmps,
        message: '检测到上次未完成的修改，仅会连接同一设备查询，不会自动重发。',
      );
    }
    notifyListeners();
  }

  Future<void> startScan({Duration duration = const Duration(seconds: 8)}) {
    return _enqueue(() async {
      await _stopScanInternal();
      await _disconnectInternal(intentional: true);
      _scanGeneration += 1;
      final generation = _scanGeneration;
      _devices.clear();
      errorMessage = null;
      phase = ChargerSessionPhase.scanning;
      diagnostics.add(
        DiagnosticKind.scan,
        'scan started generation=$generation',
      );
      notifyListeners();
      _scanSubscription = _driver
          .scan(generation: generation)
          .listen(
            (device) {
              _enqueue(() async {
                if (phase != ChargerSessionPhase.scanning ||
                    device.generation != _scanGeneration) {
                  return;
                }
                final isNewDevice = !_devices.containsKey(device.id);
                _devices[device.id] = device;
                if (_pendingRecovery?.targetDeviceKey == device.id &&
                    !_recoveryConnectScheduled) {
                  _recoveryConnectScheduled = true;
                  final recoveryDevice = device;
                  scheduleMicrotask(() => connect(recoveryDevice));
                }
                if (isNewDevice) {
                  diagnostics.add(
                    DiagnosticKind.scan,
                    'Bluetooth device discovered name=${device.name.isEmpty ? '[unnamed]' : device.name} rssi=${device.rssi}',
                    deviceKey: device.id,
                  );
                }
                notifyListeners();
              });
            },
            onError: (Object error) {
              _enqueue(() async {
                phase = ChargerSessionPhase.failed;
                errorMessage = _scanErrorText(error);
                diagnostics.add(DiagnosticKind.scan, 'scan failed: $error');
                notifyListeners();
              });
            },
          );
      _scanTimer = Timer(duration, () {
        _enqueue(() async {
          if (generation != _scanGeneration) return;
          await _stopScanInternal();
          phase = ChargerSessionPhase.idle;
          if (_devices.isEmpty) errorMessage = '本轮扫描未发现蓝牙设备。';
          notifyListeners();
        });
      });
    });
  }

  Future<void> connect(BleScanDevice device) =>
      connectKnownDevice(deviceId: device.id, deviceName: device.name);

  Future<void> connectKnownDevice({
    required String deviceId,
    required String deviceName,
  }) {
    return _enqueue(() async {
      await _stopScanInternal();
      await _disconnectInternal(intentional: true);
      _intentionalDisconnect = false;
      _reconnectAttempts = 0;
      _hasEstablishedLink = false;
      errorMessage = null;
      connectedDeviceId = deviceId;
      connectedDeviceName = deviceName;
      await _startConnection(deviceId, reconnecting: false);
    });
  }

  Future<void> disconnect() => _enqueue(() async {
    await _disconnectInternal(intentional: true);
    phase = ChargerSessionPhase.disconnected;
    notifyListeners();
  });

  Future<void> refreshParameters() => _enqueue(() async {
    final reply = await _query(0x02, ChargerProtocol.encodeParametersRequest());
    _acceptParameters(reply);
  });

  Future<void> refreshStatus() => _enqueue(_refreshStatusInternal);

  Future<void> _refreshStatusInternal() async {
    final reply = await _query(0x01, ChargerProtocol.encodeStatusRequest());
    status = ChargerProtocol.parseStatusReply(reply);
    statusUpdatedAt = DateTime.now();
    errorMessage = null;
    diagnostics.add(
      DiagnosticKind.command,
      'valid 01 reply',
      deviceKey: connectedDeviceId,
      connectionEpoch: _connectionEpoch,
    );
    notifyListeners();
  }

  void setStatusPolling(bool enabled) {
    _statusPollingEnabled = enabled;
    _pollTimer?.cancel();
    _pollTimer = null;
    if (!enabled) return;
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_commandBusy && isReadVerified) {
        refreshStatus().catchError((Object _) {});
      }
    });
  }

  Future<ParameterWriteResult> writeLithiumParameters({
    required int voltageHundredths,
    required int currentTenths,
  }) async {
    if (_writeOperationActive) {
      throw StateError('已有参数修改正在验证，请勿重复发送。');
    }
    _writeOperationActive = true;
    String? operationId;
    String? targetDeviceId;
    String? targetFingerprint;
    try {
      await _enqueue(() async {
        if (!isWriteVerified) {
          throw StateError('需要先连接设备并取得有效的 02 参数回复。');
        }
        final current = parameters;
        final currentProfile = profile;
        final deviceId = connectedDeviceId;
        if (current == null || currentProfile == null || deviceId == null) {
          throw StateError('需要最新设备参数和已连接设备。');
        }
        operationId = DateTime.now().toUtc().microsecondsSinceEpoch.toString();
        targetDeviceId = deviceId;
        targetFingerprint = currentProfile.fingerprint;
        final frame = ChargerProtocol.encodeLithiumParameters(
          voltageHundredths: voltageHundredths,
          currentTenths: currentTenths,
          currentParameters: current,
        );
        final entry = ParameterWriteJournalEntry(
          operationId: operationId!,
          targetDeviceKey: deviceId,
          profileFingerprint: currentProfile.fingerprint,
          targetVoltageHundredthsVolts: voltageHundredths,
          targetCurrentTenthsAmps: currentTenths,
          stage: ParameterWriteStage.prepared,
          updatedAt: DateTime.now(),
        );
        await _journal.write(entry);
        diagnostics.add(
          DiagnosticKind.command,
          '03 write attempted once',
          deviceKey: deviceId,
          connectionEpoch: _connectionEpoch,
          operationId: operationId,
        );
        // One confirmation issues exactly one BLE write. Recovery never resends.
        if (currentProfile.canWriteWithoutResponse) {
          await _driver.writeWithoutResponse(
            deviceId: deviceId,
            characteristic: currentProfile.writeCharacteristic,
            value: frame,
          );
        } else {
          await _driver.writeWithResponse(
            deviceId: deviceId,
            characteristic: currentProfile.writeCharacteristic,
            value: frame,
          );
        }
        await _journal.write(
          ParameterWriteJournalEntry(
            operationId: operationId!,
            targetDeviceKey: deviceId,
            profileFingerprint: currentProfile.fingerprint,
            targetVoltageHundredthsVolts: voltageHundredths,
            targetCurrentTenthsAmps: currentTenths,
            stage: ParameterWriteStage.applied,
            updatedAt: DateTime.now(),
          ),
        );
      });

      await Future<void>.delayed(const Duration(milliseconds: 600));
      await _waitForConnectionReady(targetDeviceId!);
      await _awaitNotificationQuiet();
      if (connectedDeviceId != targetDeviceId ||
          profile?.fingerprint != targetFingerprint) {
        throw StateError('重连设备或 GATT Profile 与原修改目标不一致');
      }
      final first = await _verificationParametersQuery();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final second = await _verificationParametersQuery();
      final same = first == second;
      final targetMatches =
          second.modeRaw == 1 &&
          second.voltageHundredths == voltageHundredths &&
          second.currentTenths == currentTenths;
      final result = ParameterWriteResult(
        outcome: same && targetMatches
            ? ParameterWriteOutcome.verified
            : ParameterWriteOutcome.mismatch,
        targetVoltageHundredths: voltageHundredths,
        targetCurrentTenths: currentTenths,
        actual: second,
        message: same && targetMatches ? '设备两次新 02 读回一致。' : '设备读回与目标不一致。',
      );
      await _enqueue(() async {
        parameters = second;
        parametersUpdatedAt = DateTime.now();
        lastWriteResult = result;
        if (result.outcome == ParameterWriteOutcome.verified) {
          await _journal.clear();
        }
        diagnostics.add(
          DiagnosticKind.verification,
          '03 verification ${result.outcome.name}',
          deviceKey: targetDeviceId,
          connectionEpoch: _connectionEpoch,
          operationId: operationId,
        );
        notifyListeners();
      });
      return result;
    } catch (error) {
      final result = ParameterWriteResult(
        outcome: ParameterWriteOutcome.inconclusive,
        targetVoltageHundredths: voltageHundredths,
        targetCurrentTenths: currentTenths,
        message: '未取得属于本次修改的完整设备读回：$error',
      );
      await _enqueue(() async {
        lastWriteResult = result;
        diagnostics.add(
          DiagnosticKind.verification,
          '03 verification inconclusive',
          deviceKey: targetDeviceId,
          connectionEpoch: _connectionEpoch,
          operationId: operationId,
        );
        notifyListeners();
      });
      return result;
    } finally {
      _writeOperationActive = false;
    }
  }

  Future<ChargerParameters> _verificationParametersQuery() {
    return _enqueue(() async {
      final reply = await _query(
        0x02,
        ChargerProtocol.encodeParametersRequest(),
      );
      return ChargerProtocol.parseParametersReply(reply);
    });
  }

  /// Runs one force-activation (command 04) or lock-adjustment (command 09)
  /// control write, ported from the mini program home page.
  ///
  /// [operationId] must be a non-empty, caller-generated identifier that only
  /// exists once the user has explicitly confirmed this exact operation. A
  /// single call sends exactly one frame and never resends it.
  ///
  /// [targetLock] is required for command 09 and must be null for command 04.
  /// The acknowledgement (`04`/`05`/`06`) is recorded as a UI hint only. Lock
  /// changes additionally require the lock flag of a fresh 02 reply to match
  /// the requested direction before the result is reported as verified.
  Future<ControlWriteResult> operateControl({
    required String operationId,
    LockTarget? targetLock,
    Duration settleDelay = const Duration(milliseconds: 600),
  }) async {
    final trimmedOperationId = operationId.trim();
    if (trimmedOperationId.isEmpty) {
      throw StateError('缺少本次控制操作的标识，未发送任何写入。');
    }
    if (_controlWriteActive) {
      throw StateError('已有控制写入正在核验，请勿重复发送。');
    }
    _controlWriteActive = true;
    final label = targetLock?.label ?? '强制激活';
    final expectedCommand = switch (targetLock) {
      null => ChargerProtocol.activateAckCommand,
      LockTarget.lock => ChargerProtocol.lockAckCommand,
      LockTarget.unlock => ChargerProtocol.unlockAckCommand,
    };
    String? targetDeviceId;
    String? targetFingerprint;
    bool writeAttempted = false;
    Completer<List<int>>? pendingReply;
    try {
      pendingReply = await _enqueue(() async {
        if (!isReadVerified) {
          throw StateError('需要先连接设备并取得有效的 02 参数回复。');
        }
        if (_commandBusy) {
          throw StateError('命令通道忙，请稍后重试。');
        }
        final currentProfile = profile;
        final deviceId = connectedDeviceId;
        if (currentProfile == null || deviceId == null) {
          throw StateError('设备未连接。');
        }
        if (targetLock != null && currentLockTarget == targetLock) {
          throw StateError('设备当前锁定状态已与目标一致，未发送任何写入。');
        }
        targetDeviceId = deviceId;
        targetFingerprint = currentProfile.fingerprint;
        final frame = targetLock == null
            ? ChargerProtocol.encodeActivateRequest()
            : ChargerProtocol.encodeLockRequest(targetLock);
        // The reply slot is claimed *before* the write so an acknowledgement
        // that arrives immediately after the write cannot be dropped as an
        // unsolicited notification. The frame is written exactly once here and
        // is never re-sent while waiting for the reply.
        final completer = Completer<List<int>>();
        _replyCompleter = completer;
        _expectedReplyCommand = expectedCommand;
        diagnostics.add(
          DiagnosticKind.command,
          targetLock == null
              ? '04 activate write attempted once'
              : '09 lock write attempted once target=${targetLock.name}',
          deviceKey: deviceId,
          connectionEpoch: _connectionEpoch,
          operationId: trimmedOperationId,
        );
        writeAttempted = true;
        // One confirmation issues exactly one BLE write; nothing resends it.
        if (currentProfile.canWriteWithoutResponse) {
          await _driver.writeWithoutResponse(
            deviceId: deviceId,
            characteristic: currentProfile.writeCharacteristic,
            value: frame,
          );
        } else {
          await _driver.writeWithResponse(
            deviceId: deviceId,
            characteristic: currentProfile.writeCharacteristic,
            value: frame,
          );
        }
        return completer;
      });

      await Future<void>.delayed(settleDelay);
      await _waitForConnectionReady(targetDeviceId!);
      if (connectedDeviceId != targetDeviceId ||
          profile?.fingerprint != targetFingerprint) {
        throw StateError('当前连接设备或 GATT Profile 已不是本次控制的目标。');
      }

      final acknowledgement = await _awaitControlAcknowledgement(
        expectedCommand,
        pendingReply,
      );

      if (targetLock == null) {
        final result = ControlWriteResult(
          operationId: trimmedOperationId,
          outcome: ControlWriteOutcome.acknowledgedUnverified,
          label: label,
          message:
              '设备回了 ${_ackLabel(acknowledgement.command)} 应答帧，'
              '已按小程序语义记录为已发送请求。'
              '协议 02 回包没有可核对的强制激活字段，因此本机不判定为已验证。',
        );
        return await _publishControlResult(
          result,
          targetDeviceId,
          trimmedOperationId,
        );
      }

      await _awaitNotificationQuiet();
      final readback = await _verificationParametersQuery();
      final achieved = readback.lockRaw == targetLock.wireByte;
      final result = ControlWriteResult(
        operationId: trimmedOperationId,
        outcome: achieved
            ? ControlWriteOutcome.acknowledged
            : ControlWriteOutcome.unacknowledged,
        label: label,
        targetLock: targetLock,
        parameters: readback,
        message: achieved
            ? '设备回了 ${_ackLabel(expectedCommand)} 应答帧，且新 02 读回锁定标志为 '
                  '0x${_hexLock(readback.lockRaw)}，与目标一致。'
            : '设备回了 ${_ackLabel(expectedCommand)} 应答帧，但新 02 读回锁定标志为 '
                  '0x${_hexLock(readback.lockRaw)}，与目标 0x${_hexLock(targetLock.wireByte)} 不一致。',
      );
      return await _publishControlResult(
        result,
        targetDeviceId,
        trimmedOperationId,
      );
    } catch (error) {
      final result = ControlWriteResult(
        operationId: trimmedOperationId,
        outcome: ControlWriteOutcome.unacknowledged,
        label: label,
        targetLock: targetLock,
        message: writeAttempted
            ? '已发送一次控制帧，但未取得属于本次操作的有效应答：$error'
            : '未发送控制帧：$error',
      );
      return await _publishControlResult(
        result,
        targetDeviceId,
        trimmedOperationId,
      );
    } finally {
      _controlWriteActive = false;
    }
  }

  Future<ControlWriteResult> _publishControlResult(
    ControlWriteResult result,
    String? targetDeviceId,
    String operationId,
  ) async {
    await _enqueue(() async {
      lastControlResult = result;
      if (result.parameters != null) {
        parameters = result.parameters;
        parametersUpdatedAt = DateTime.now();
      }
      diagnostics.add(
        DiagnosticKind.verification,
        '${result.targetLock == null ? '04 activate' : '09 lock'} '
        'control ${result.outcome.name}',
        deviceKey: targetDeviceId,
        connectionEpoch: _connectionEpoch,
        operationId: operationId,
      );
      notifyListeners();
    });
    return result;
  }

  /// Waits for the `04`/`05`/`06` acknowledgement of the frame that was already
  /// written.
  ///
  /// This deliberately does not reuse `_query`: `_query` writes the frame it is
  /// given, and re-sending a 04/09 frame would violate the "one confirmation,
  /// one write" rule. The caller claims the single-in-flight slot before the
  /// write; this method only consumes the reply that arrives on it.
  Future<ChargerControlAcknowledgement> _awaitControlAcknowledgement(
    int expectedCommand,
    Completer<List<int>>? completer,
  ) {
    if (completer == null) {
      throw StateError('控制写入未取得在途应答槽');
    }
    return completer.future
        .timeout(const Duration(seconds: 3))
        .then(
          (reply) => ChargerProtocol.parseControlAcknowledgement(
            reply,
            expectedCommand: expectedCommand,
          ),
        )
        .whenComplete(() {
          if (identical(_replyCompleter, completer)) {
            _replyCompleter = null;
            _expectedReplyCommand = null;
          }
          _commandBusy = false;
        });
  }

  static String _ackLabel(int command) =>
      command.toRadixString(16).padLeft(2, '0').toUpperCase();

  static String _hexLock(int value) =>
      value.toRadixString(16).padLeft(2, '0').toUpperCase();

  Future<void> _startConnection(
    String deviceId, {
    required bool reconnecting,
  }) async {
    _connectionEpoch += 1;
    final epoch = _connectionEpoch;
    _hasEstablishedLink = false;
    phase = reconnecting
        ? ChargerSessionPhase.reconnecting
        : ChargerSessionPhase.connecting;
    notifyListeners();
    _connectionAttemptTimer?.cancel();
    _connectionAttemptTimer = Timer(_connectionTimeout, () {
      _enqueue(() async {
        if (epoch != _connectionEpoch ||
            deviceId != connectedDeviceId ||
            _hasEstablishedLink) {
          return;
        }
        await _connectionSubscription?.cancel();
        _connectionSubscription = null;
        phase = ChargerSessionPhase.failed;
        errorMessage = '连接超时（${_connectionTimeout.inSeconds} 秒），请点击重连。';
        diagnostics.add(
          DiagnosticKind.connection,
          'connection timeout after ${_connectionTimeout.inMilliseconds} ms',
          deviceKey: deviceId,
          connectionEpoch: epoch,
        );
        notifyListeners();
      });
    });
    _connectionSubscription = _driver
        .connect(deviceId: deviceId, timeout: _connectionTimeout)
        .listen(
          (event) {
            if (event.state == BleConnectionState.disconnected) {
              final pending = _replyCompleter;
              if (pending != null && !pending.isCompleted) {
                pending.completeError(StateError('connection disconnected'));
              }
            }
            _enqueue(() async {
              if (epoch != _connectionEpoch ||
                  event.deviceId != connectedDeviceId) {
                return;
              }
              if (event.state == BleConnectionState.connected) {
                await _onConnected(event.deviceId, epoch);
              } else if (event.state == BleConnectionState.disconnected) {
                await _onDisconnected(event.error);
              }
            });
          },
          onError: (Object error) {
            _enqueue(() async {
              if (epoch != _connectionEpoch || deviceId != connectedDeviceId) {
                return;
              }
              await _onDisconnected(error);
            });
          },
        );
  }

  Future<void> _onConnected(String deviceId, int epoch) async {
    _connectionAttemptTimer?.cancel();
    _connectionAttemptTimer = null;
    _hasEstablishedLink = true;
    phase = ChargerSessionPhase.discoveringServices;
    notifyListeners();
    final resolution = await _driver.discoverProfile(deviceId);
    if (epoch != _connectionEpoch) return;
    if (resolution.status != BleProfileResolutionStatus.ready) {
      phase = ChargerSessionPhase.failed;
      errorMessage = resolution.status == BleProfileResolutionStatus.ambiguous
          ? '发现多个可写/通知 Profile，已安全停止，未尝试写入。'
          : '未发现兼容的可写和通知特征。';
      diagnostics.add(
        DiagnosticKind.profile,
        errorMessage!,
        deviceKey: deviceId,
      );
      notifyListeners();
      return;
    }
    profile = resolution.profile;
    final mtu = await _driver.requestMtu(deviceId, desiredMtu: 247);
    if (mtu != null && mtu < 30) {
      phase = ChargerSessionPhase.failed;
      errorMessage = '协商 MTU=$mtu，无法容纳 27 字节参数回复。';
      notifyListeners();
      return;
    }
    phase = ChargerSessionPhase.subscribing;
    notifyListeners();
    await _notificationSubscription?.cancel();
    _notificationSubscription = _driver
        .notifications(
          deviceId: deviceId,
          characteristic: profile!.notificationCharacteristic,
        )
        .listen(
          _onNotification,
          onError: (Object error) {
            diagnostics.add(
              DiagnosticKind.parseFailure,
              'notification error: $error',
            );
          },
        );
    phase = ChargerSessionPhase.linkReady;
    notifyListeners();
    try {
      final reply = await _query(
        0x02,
        ChargerProtocol.encodeParametersRequest(),
      );
      _acceptParameters(reply);
      _reconnectAttempts = 0;
      await _resolvePendingRecovery(deviceId);
      try {
        await _refreshStatusInternal();
      } catch (error) {
        errorMessage = '参数已读取，但实时状态自动查询失败：$error';
        diagnostics.add(
          DiagnosticKind.command,
          'automatic 01 query failed: $error',
          deviceKey: deviceId,
          connectionEpoch: epoch,
        );
        notifyListeners();
      }
      if (_statusPollingEnabled) {
        setStatusPolling(true);
      }
    } catch (error) {
      phase = ChargerSessionPhase.failed;
      errorMessage = '链路已连接，但 02 参数查询失败：$error';
      notifyListeners();
    }
  }

  void _acceptParameters(List<int> reply) {
    parameters = ChargerProtocol.parseParametersReply(reply);
    parametersUpdatedAt = DateTime.now();
    phase = ChargerSessionPhase.writeCompatibilityVerified;
    diagnostics.add(
      DiagnosticKind.command,
      'valid 02 reply; writeGate=$isWriteVerified',
      deviceKey: connectedDeviceId,
      connectionEpoch: _connectionEpoch,
    );
    notifyListeners();
  }

  void _onNotification(List<int> bytes) {
    _lastNotificationAt = DateTime.now();
    if (bytes.length < 3 || !ChargerProtocol.hasValidEnvelope(bytes)) {
      diagnostics.add(
        DiagnosticKind.parseFailure,
        'invalid notification length=${bytes.length}',
        deviceKey: connectedDeviceId,
        connectionEpoch: _connectionEpoch,
      );
      return;
    }
    final completer = _replyCompleter;
    if (completer != null &&
        !completer.isCompleted &&
        bytes[2] == _expectedReplyCommand) {
      completer.complete(List<int>.from(bytes));
    } else {
      diagnostics.add(
        DiagnosticKind.command,
        'unsolicited command=${bytes[2]} ignored',
        deviceKey: connectedDeviceId,
        connectionEpoch: _connectionEpoch,
      );
    }
  }

  Future<void> _awaitNotificationQuiet({
    Duration quietFor = const Duration(milliseconds: 400),
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final last = _lastNotificationAt;
      if (last == null || DateTime.now().difference(last) >= quietFor) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    throw TimeoutException('notification channel did not become quiet');
  }

  Future<void> _resolvePendingRecovery(String deviceId) async {
    final pending = _pendingRecovery;
    if (pending == null || pending.targetDeviceKey != deviceId) return;
    if (profile?.fingerprint != pending.profileFingerprint) {
      lastWriteResult = ParameterWriteResult(
        outcome: ParameterWriteOutcome.inconclusive,
        targetVoltageHundredths: pending.targetVoltageHundredthsVolts,
        targetCurrentTenths: pending.targetCurrentTenthsAmps,
        message: '同一设备的 GATT Profile 已变化，不能确认上次修改。',
      );
      notifyListeners();
      return;
    }
    final actual = parameters!;
    final matches =
        actual.modeRaw == 1 &&
        actual.voltageHundredths == pending.targetVoltageHundredthsVolts &&
        actual.currentTenths == pending.targetCurrentTenthsAmps;
    lastWriteResult = ParameterWriteResult(
      outcome: matches
          ? ParameterWriteOutcome.verified
          : ParameterWriteOutcome.mismatch,
      targetVoltageHundredths: pending.targetVoltageHundredthsVolts,
      targetCurrentTenths: pending.targetCurrentTenthsAmps,
      actual: actual,
      message: matches
          ? '重启后仅查询原设备，设备当前参数与目标一致；未重发 03。'
          : '重启后原设备读回与目标不一致；未重发 03。',
    );
    diagnostics.add(
      DiagnosticKind.verification,
      'recovered journal ${matches ? 'verified' : 'mismatch'} without resend',
      deviceKey: deviceId,
      connectionEpoch: _connectionEpoch,
      operationId: pending.operationId,
    );
    _pendingRecovery = null;
    _recoveryConnectScheduled = false;
    await _journal.clear();
    notifyListeners();
  }

  Future<List<int>> _query(int command, List<int> frame) async {
    final deviceId = connectedDeviceId;
    final currentProfile = profile;
    if (deviceId == null || currentProfile == null) throw StateError('设备未连接');
    if (_commandBusy) throw StateError('命令通道忙');
    _commandBusy = true;
    final completer = Completer<List<int>>();
    _replyCompleter = completer;
    _expectedReplyCommand = command;
    try {
      if (currentProfile.canWriteWithoutResponse) {
        await _driver.writeWithoutResponse(
          deviceId: deviceId,
          characteristic: currentProfile.writeCharacteristic,
          value: frame,
        );
      } else {
        await _driver.writeWithResponse(
          deviceId: deviceId,
          characteristic: currentProfile.writeCharacteristic,
          value: frame,
        );
      }
      return await completer.future.timeout(const Duration(seconds: 3));
    } finally {
      if (identical(_replyCompleter, completer)) {
        _replyCompleter = null;
        _expectedReplyCommand = null;
      }
      _commandBusy = false;
    }
  }

  Future<void> _onDisconnected(Object? reason) async {
    _connectionAttemptTimer?.cancel();
    _connectionAttemptTimer = null;
    final hadEstablishedLink = _hasEstablishedLink;
    _replyCompleter?.completeError(StateError('connection disconnected'));
    profile = null;
    phase = ChargerSessionPhase.disconnected;
    diagnostics.add(
      DiagnosticKind.disconnect,
      'disconnected: ${reason ?? 'no reason'}',
      deviceKey: connectedDeviceId,
      connectionEpoch: _connectionEpoch,
    );
    notifyListeners();
    final deviceId = connectedDeviceId;
    if (!_intentionalDisconnect && !hadEstablishedLink) {
      phase = ChargerSessionPhase.failed;
      errorMessage = '连接失败或超时，请点击重连。';
      notifyListeners();
    } else if (!_intentionalDisconnect &&
        deviceId != null &&
        _reconnectAttempts < 2) {
      _reconnectAttempts += 1;
      await Future<void>.delayed(Duration(seconds: _reconnectAttempts));
      await _connectionSubscription?.cancel();
      await _startConnection(deviceId, reconnecting: true);
    } else if (!_intentionalDisconnect) {
      phase = ChargerSessionPhase.failed;
      errorMessage = '连接已断开，自动重连次数已耗尽，请重新扫描。';
      notifyListeners();
    }
  }

  Future<void> _waitForConnectionReady(String expectedDeviceId) async {
    final deadline = DateTime.now().add(const Duration(seconds: 12));
    while (DateTime.now().isBefore(deadline)) {
      if (connectedDeviceId == expectedDeviceId &&
          profile != null &&
          isReadVerified &&
          !_commandBusy) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    throw TimeoutException('reconnect/profile timeout');
  }

  Future<void> _stopScanInternal() async {
    _scanTimer?.cancel();
    _scanTimer = null;
    await _scanSubscription?.cancel();
    _scanSubscription = null;
  }

  Future<void> _disconnectInternal({required bool intentional}) async {
    _intentionalDisconnect = intentional;
    _connectionAttemptTimer?.cancel();
    _connectionAttemptTimer = null;
    _pollTimer?.cancel();
    _pollTimer = null;
    _replyCompleter?.completeError(StateError('connection cancelled'));
    _replyCompleter = null;
    await _notificationSubscription?.cancel();
    _notificationSubscription = null;
    await _connectionSubscription?.cancel();
    _connectionSubscription = null;
    profile = null;
    connectedDeviceId = null;
    connectedDeviceName = null;
  }

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _serial = _serial.then((_) async {
      if (_disposed) throw StateError('actor disposed');
      try {
        completer.complete(await action());
      } catch (error, stack) {
        if (!completer.isCompleted) completer.completeError(error, stack);
      }
    });
    return completer.future;
  }

  String _scanErrorText(Object error) => switch (adapterState) {
    BleAdapterState.unauthorized => '缺少蓝牙权限，请在系统设置中允许。',
    BleAdapterState.poweredOff => '蓝牙已关闭，请先打开蓝牙。',
    BleAdapterState.locationServicesDisabled => '定位服务关闭，旧版 Android 无法扫描 BLE。',
    BleAdapterState.unsupported => '此设备不支持低功耗蓝牙。',
    _ => '扫描失败：$error',
  };

  @override
  void dispose() {
    _disposed = true;
    _scanTimer?.cancel();
    _pollTimer?.cancel();
    _connectionAttemptTimer?.cancel();
    _scanSubscription?.cancel();
    _connectionSubscription?.cancel();
    _notificationSubscription?.cancel();
    super.dispose();
  }
}
