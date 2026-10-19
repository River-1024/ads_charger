import 'dart:async';
import 'dart:io';

import 'package:ads_charger/application/presets/preset_service.dart';
import 'package:ads_charger/application/session/charger_session_actor.dart';
import 'package:ads_charger/domain/charger_models/charger_models.dart';
import 'package:ads_charger/features/app_shell.dart';
import 'package:ads_charger/features/charger_control_card.dart';
import 'package:ads_charger/infrastructure/diagnostics/diagnostic_log.dart';
import 'package:ads_charger/infrastructure/permissions/ble_permission_gate.dart';
import 'package:ads_charger/infrastructure/storage/key_value_store.dart';
import 'package:ads_charger/infrastructure/storage/parameter_write_journal.dart';
import 'package:ads_charger/ports/ble_driver.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows five user surfaces and current-scan empty state', (
    tester,
  ) async {
    final directory = Directory('build/widget-test-journal')
      ..createSync(recursive: true);
    addTearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });
    final actor = await tester.runAsync(() async {
      final value = ChargerSessionActor(
        driver: _IdleDriver(),
        journal: await ParameterWriteJournal.create(directory: directory),
      );
      await value.initialize();
      return value;
    });
    final session = actor!;
    addTearDown(session.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: AppShell(
          session: session,
          presets: PresetService(_MemoryStore()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('搜索蓝牙设备'), findsOneWidget);
    expect(find.textContaining('不按设备名称过滤'), findsOneWidget);
    expect(find.text('设备'), findsWidgets);
    expect(find.text('状态'), findsOneWidget);
    expect(find.text('参数'), findsOneWidget);
    expect(find.text('预设'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);

    session.diagnostics.add(DiagnosticKind.scan, 'scan started');
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(find.text('运行日志'), findsOneWidget);
    await tester.tap(find.text('运行日志'));
    await tester.pumpAndSettle();
    expect(find.textContaining('运行日志 ('), findsOneWidget);
    expect(find.byTooltip('复制全部'), findsOneWidget);
    expect(find.byTooltip('下载日志'), findsOneWidget);
    expect(find.byTooltip('清空日志'), findsOneWidget);
    expect(find.text('scan started'), findsOneWidget);
  });

  testWidgets(
    'default device hides device tab and starts an exact auto connection',
    (tester) async {
      final directory = Directory('build/widget-default-journal')
        ..createSync(recursive: true);
      addTearDown(() {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      final driver = _IdleDriver();
      final actor = await tester.runAsync(() async {
        final value = ChargerSessionActor(
          driver: driver,
          journal: await ParameterWriteJournal.create(directory: directory),
          connectionTimeout: const Duration(milliseconds: 30),
        );
        await value.initialize();
        return value;
      });
      final session = actor!;
      final store = _MemoryStore();
      final presets = PresetService(store);
      await presets.setDefaultDevice(
        DefaultDeviceRecord(
          deviceKey: 'AA:BB:CC:DD:EE:01',
          name: 'ADS Charger',
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: AppShell(
            session: session,
            presets: presets,
            permissionGate: const _GrantedPermissionGate(),
          ),
        ),
      );
      await tester.pump();
      await tester.runAsync(() async {
        final deadline = DateTime.now().add(const Duration(seconds: 2));
        while (driver.lastConnectedDeviceId == null &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('设备'), findsNothing);
      expect(find.text('状态'), findsWidgets);
      expect(driver.lastConnectedDeviceId, 'AA:BB:CC:DD:EE:01');
      expect(find.text('重连默认设备'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
    },
  );

  testWidgets('status metric cards do not overflow with enlarged text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    tester.platformDispatcher.textScaleFactorTestValue = 1.4;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });
    final directory = Directory('build/widget-overflow-journal')
      ..createSync(recursive: true);
    addTearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });
    final actor = await tester.runAsync(() async {
      final value = ChargerSessionActor(
        driver: _IdleDriver(),
        journal: await ParameterWriteJournal.create(directory: directory),
      );
      await value.initialize();
      return value;
    });
    final session = actor!;
    addTearDown(session.dispose);
    session.phase = ChargerSessionPhase.writeCompatibilityVerified;
    session.status = const ChargerStatus(
      voltageHundredths: 8653,
      currentTenths: 1,
      percentRaw: 100,
      timeRaw: 0,
      powerRaw: 8,
      capacityRaw: 0,
      temperatureRaw: 40,
      batteryStateRaw: 0,
      faultRaw: 0,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: AppShell(
          session: session,
          presets: PresetService(_MemoryStore()),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('状态'));
    await tester.pumpAndSettle();

    expect(find.text('输出电压'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('mini program home page control card', () {
    testWidgets(
      'preselects the lock direction reported by 02 and refuses a repeat send',
      (tester) async {
        final session = (await tester.runAsync(
          () => _verifiedSession(lockRaw: 0xA0),
        ))!;
        addTearDown(session.dispose);
        await _pumpControlCard(tester, session);

        expect(find.text('充电器控制'), findsOneWidget);
        expect(find.text('锁定状态：${LockTarget.lock.label}'), findsOneWidget);
        // The reported direction is preselected, so the button already targets it
        // and must refuse rather than repeat a same-direction write.
        expect(find.text('发送 ${LockTarget.lock.label}'), findsOneWidget);
        expect(find.text('设备读回已是该状态，发送按钮会拒绝重复写入。'), findsOneWidget);
        // The session actor independently enforces the same-target refusal;
        // this widget check verifies that the UI surfaces the guard before a tap.
        expect(find.text('确认发送一次'), findsNothing);
      },
    );

    testWidgets('lock adjustment requires an explicit confirmation dialog', (
      tester,
    ) async {
      final session = (await tester.runAsync(
        () => _verifiedSession(lockRaw: 0x0A),
      ))!;
      addTearDown(session.dispose);
      await _pumpControlCard(tester, session);

      expect(find.text('锁定状态：${LockTarget.unlock.label}'), findsOneWidget);
      await tester.tap(find.text('锁定'));
      await tester.pumpAndSettle();
      expect(find.text('发送 ${LockTarget.lock.label}'), findsOneWidget);

      await tester.tap(find.text('发送 ${LockTarget.lock.label}'));
      await tester.pumpAndSettle();
      expect(find.text('${LockTarget.lock.label}？'), findsOneWidget);
      expect(find.textContaining('数据字节 0xA0'), findsOneWidget);
      expect(find.textContaining('只发送一次'), findsOneWidget);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('${LockTarget.lock.label}？'), findsNothing);
    });

    testWidgets('force activation needs the full 3 second hold and confirms', (
      tester,
    ) async {
      final session = (await tester.runAsync(
        () => _verifiedSession(lockRaw: 0x0A),
      ))!;
      addTearDown(session.dispose);
      await _pumpControlCard(tester, session);

      expect(find.text('长按 3 秒强制激活'), findsOneWidget);

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('长按 3 秒强制激活')),
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('继续按住…'), findsOneWidget);
      await gesture.up();
      await tester.pumpAndSettle();
      // Released early: no dialog, nothing sent.
      expect(find.text('确认发送一次'), findsNothing);

      final held = await tester.startGesture(
        tester.getCenter(find.text('长按 3 秒强制激活')),
      );
      // First cross Flutter's long-press recognizer threshold, then hold for
      // the product's additional three-second activation timer.
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(ChargerControlCard.forceActivateHold);
      await tester.pump();
      expect(find.text('强制激活充电器？'), findsOneWidget);
      expect(find.textContaining('固定 04 帧'), findsOneWidget);
      await held.up();
      await tester.pumpAndSettle();

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('强制激活充电器？'), findsNothing);
    });

    testWidgets('control is blocked before a valid 02 reply', (tester) async {
      final session = (await tester.runAsync(
        () => _verifiedSession(lockRaw: 0x0A, verified: false),
      ))!;
      addTearDown(session.dispose);
      await _pumpControlCard(tester, session);

      expect(find.text('强制激活（需先取得有效 02）'), findsOneWidget);
      expect(find.text('请选择目标状态'), findsOneWidget);
      expect(find.text('锁定状态：尚未取得 02 读回值'), findsOneWidget);
    });
  });
}

Future<void> _pumpControlCard(
  WidgetTester tester,
  ChargerSessionActor session,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: ChargerControlCard(session: session)),
    ),
  );
  // The control card needs only bounded initial layout pumping here.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

/// Builds a session that is already read-verified so the control card is
/// enabled. No BLE traffic is possible: the single-write path throws before it
/// reaches a driver because this fixture has no resolved GATT profile.
Future<ChargerSessionActor> _verifiedSession({
  required int lockRaw,
  bool verified = true,
}) async {
  final directory = Directory('build/widget-control-journal')
    ..createSync(recursive: true);
  final actor = ChargerSessionActor(
    driver: _IdleDriver(),
    journal: await ParameterWriteJournal.create(directory: directory),
  );
  await actor.initialize();
  if (verified) actor.phase = ChargerSessionPhase.writeCompatibilityVerified;
  if (verified) {
    actor.parameters = ChargerParameters(
      voltageHundredths: 5460,
      currentTenths: 30,
      modeRaw: 1,
      language: 0,
      maxCurrentRaw: 30,
      lockRaw: lockRaw,
      versionRaw: 60,
    );
  }
  return actor;
}

class _MemoryStore implements KeyValueStore {
  final Map<String, String> values = <String, String>{};
  @override
  Future<String?> getString(String key) async => values[key];
  @override
  Future<void> remove(String key) async => values.remove(key);
  @override
  Future<void> setString(String key, String value) async {
    values[key] = value;
  }
}

class _IdleDriver implements BleDriver {
  String? lastConnectedDeviceId;

  @override
  BleAdapterState get adapterState => BleAdapterState.ready;
  @override
  Stream<BleAdapterState> get adapterStateChanges =>
      const Stream<BleAdapterState>.empty();
  @override
  Stream<BleScanDevice> scan({required int generation}) =>
      const Stream<BleScanDevice>.empty();
  @override
  Stream<BleConnectionEvent> connect({
    required String deviceId,
    Duration? timeout,
  }) {
    lastConnectedDeviceId = deviceId;
    return const Stream<BleConnectionEvent>.empty();
  }

  @override
  Future<BleProfileResolution> discoverProfile(String deviceId) async =>
      BleProfileResolution.unsupported();
  @override
  Stream<List<int>> notifications({
    required String deviceId,
    required BleCharacteristicRef characteristic,
  }) => const Stream<List<int>>.empty();
  @override
  Future<int?> requestMtu(String deviceId, {int desiredMtu = 247}) async => 247;
  @override
  Future<void> writeWithResponse({
    required String deviceId,
    required BleCharacteristicRef characteristic,
    required List<int> value,
  }) async {}
  @override
  Future<void> writeWithoutResponse({
    required String deviceId,
    required BleCharacteristicRef characteristic,
    required List<int> value,
  }) async {}
}

class _GrantedPermissionGate implements BlePermissionGate {
  const _GrantedPermissionGate();

  @override
  Future<void> openSettings() async {}

  @override
  Future<BlePermissionResult> requestForScan() async =>
      BlePermissionResult.granted;
}
