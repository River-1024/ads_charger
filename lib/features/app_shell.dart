import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../application/presets/preset_service.dart';
import '../application/session/charger_session_actor.dart';
import '../domain/charger_models/charger_parameters.dart';
import '../domain/validation/charger_parameter_validator.dart';
import '../infrastructure/diagnostics/diagnostic_log.dart';
import '../infrastructure/permissions/ble_permission_gate.dart';
import 'charger_control_card.dart';

class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.session,
    required this.presets,
    this.permissionGate = const MobileBlePermissionGate(),
  });

  final ChargerSessionActor session;
  final PresetService presets;
  final BlePermissionGate permissionGate;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  int _index = 0;
  DefaultDeviceRecord? _defaultDevice;
  List<UserPreset> _presets = const <UserPreset>[];
  bool _startupDefaultSearchPending = true;
  String? _permissionMessage;
  bool _permissionNeedsSettings = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _reloadLocal();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.session.setStatusPolling(false);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    widget.session.setStatusPolling(
      state == AppLifecycleState.resumed && _index == _statusPageIndex,
    );
  }

  int get _statusPageIndex => _defaultDevice == null ? 1 : 0;

  bool get _connectionBusy => switch (widget.session.phase) {
    ChargerSessionPhase.connecting ||
    ChargerSessionPhase.discoveringServices ||
    ChargerSessionPhase.subscribing ||
    ChargerSessionPhase.reconnecting => true,
    _ => false,
  };

  Future<void> _reloadLocal() async {
    final values = await Future.wait<Object?>(<Future<Object?>>[
      widget.presets.getDefaultDevice(),
      widget.presets.getUserPresets(),
    ]);
    if (!mounted) return;
    final previousDefault = _defaultDevice;
    final loadedDefault = values[0] as DefaultDeviceRecord?;
    final defaultAddedOrChanged =
        loadedDefault != null &&
        previousDefault?.deviceKey != loadedDefault.deviceKey;
    setState(() {
      if (previousDefault == null && loadedDefault != null) {
        _index = _index == 0 ? 0 : _index - 1;
      } else if (previousDefault != null && loadedDefault == null) {
        _index += 1;
      }
      _defaultDevice = loadedDefault;
      _presets = values[1]! as List<UserPreset>;
    });
    widget.session.setStatusPolling(_index == _statusPageIndex);
    if (loadedDefault == null) {
      _startupDefaultSearchPending = false;
      return;
    }
    if ((_startupDefaultSearchPending || defaultAddedOrChanged) &&
        !widget.session.isConnected &&
        !_connectionBusy) {
      _startupDefaultSearchPending = false;
      await _connectDefaultDevice();
    }
  }

  Future<void> _connectDefaultDevice() async {
    final device = _defaultDevice;
    if (device == null || _connectionBusy) return;
    final permission = await widget.permissionGate.requestForScan();
    if (!mounted) return;
    if (permission == BlePermissionResult.granted) {
      setState(() {
        _permissionMessage = null;
        _permissionNeedsSettings = false;
      });
      await widget.session.connectKnownDevice(
        deviceId: device.deviceKey,
        deviceName: device.name,
      );
      return;
    }
    setState(() {
      _permissionNeedsSettings =
          permission == BlePermissionResult.permanentlyDenied;
      _permissionMessage = _permissionNeedsSettings
          ? '蓝牙权限已被永久拒绝，请在系统设置中允许后重试。'
          : '需要蓝牙和附近设备权限才能连接默认设备。';
    });
  }

  Future<void> _requestScan() async {
    final permission = await widget.permissionGate.requestForScan();
    if (!mounted) return;
    if (permission == BlePermissionResult.granted) {
      setState(() {
        _permissionMessage = null;
        _permissionNeedsSettings = false;
      });
      await widget.session.startScan();
      return;
    }
    setState(() {
      _permissionNeedsSettings =
          permission == BlePermissionResult.permanentlyDenied;
      _permissionMessage = _permissionNeedsSettings
          ? '蓝牙权限已被永久拒绝，请在系统设置中允许后重试。'
          : '需要蓝牙和附近设备权限才能扫描，可再次点击搜索重试。';
    });
  }

  void _selectPage(int value) {
    setState(() => _index = value);
    widget.session.setStatusPolling(value == _statusPageIndex);
  }

  @override
  Widget build(BuildContext context) {
    final hasDefault = _defaultDevice != null;
    return AnimatedBuilder(
      animation: widget.session,
      // The page widgets must be constructed inside this listener. If they
      // were built in build() and captured by this closure, every session
      // notification would hand Flutter the exact same widget instances and
      // Element.updateChild would skip those subtrees entirely — the status
      // page would stay frozen on its pre-connection empty state until an
      // unrelated setState (e.g. a tab switch) rebuilt it.
      builder: (context, _) {
        final titles = <String>[if (!hasDefault) '设备', '状态', '参数', '预设', '设置'];
        final pages = <Widget>[
          if (!hasDefault)
            _DevicesPage(
              session: widget.session,
              defaultDevice: _defaultDevice,
              onLocalChanged: _reloadLocal,
              presets: widget.presets,
              permissionMessage: _permissionMessage,
              permissionNeedsSettings: _permissionNeedsSettings,
              onScan: _requestScan,
              onOpenSettings: widget.permissionGate.openSettings,
            ),
          _StatusPage(
            session: widget.session,
            onReconnect: hasDefault ? _connectDefaultDevice : null,
          ),
          _ParametersPage(session: widget.session),
          _PresetsPage(
            session: widget.session,
            service: widget.presets,
            presets: _presets,
            onChanged: _reloadLocal,
          ),
          _SettingsPage(
            session: widget.session,
            defaultDevice: _defaultDevice,
            service: widget.presets,
            onChanged: _reloadLocal,
          ),
        ];
        final safeIndex = _index.clamp(0, pages.length - 1);
        return Scaffold(
          appBar: AppBar(
            title: Text(titles[safeIndex]),
            actions: <Widget>[
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Center(
                  child: _ConnectionChip(
                    session: widget.session,
                    onReconnect: hasDefault ? _connectDefaultDevice : null,
                  ),
                ),
              ),
            ],
          ),
          body: SafeArea(
            child: IndexedStack(index: safeIndex, children: pages),
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: safeIndex,
            onDestinationSelected: _selectPage,
            destinations: <NavigationDestination>[
              if (!hasDefault)
                const NavigationDestination(
                  icon: Icon(Icons.bluetooth_searching),
                  label: '设备',
                ),
              const NavigationDestination(icon: Icon(Icons.speed), label: '状态'),
              const NavigationDestination(icon: Icon(Icons.tune), label: '参数'),
              const NavigationDestination(
                icon: Icon(Icons.bookmarks_outlined),
                label: '预设',
              ),
              const NavigationDestination(
                icon: Icon(Icons.settings_outlined),
                label: '设置',
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ConnectionChip extends StatelessWidget {
  const _ConnectionChip({required this.session, this.onReconnect});
  final ChargerSessionActor session;
  final Future<void> Function()? onReconnect;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (session.phase) {
      ChargerSessionPhase.writeCompatibilityVerified => ('可安全修改', Colors.green),
      ChargerSessionPhase.readProtocolVerified => ('只读已验证', Colors.blue),
      ChargerSessionPhase.scanning => ('扫描中', Colors.orange),
      ChargerSessionPhase.connecting ||
      ChargerSessionPhase.discoveringServices ||
      ChargerSessionPhase.subscribing ||
      ChargerSessionPhase.reconnecting => ('连接中', Colors.orange),
      ChargerSessionPhase.failed => ('失败', Colors.red),
      _ => ('未连接', Colors.grey),
    };
    final canReconnect =
        onReconnect != null &&
        !session.isScanning &&
        switch (session.phase) {
          ChargerSessionPhase.idle ||
          ChargerSessionPhase.disconnected ||
          ChargerSessionPhase.failed => true,
          _ => false,
        };
    if (canReconnect) {
      return ActionChip(
        visualDensity: VisualDensity.compact,
        avatar: Icon(Icons.refresh, size: 18, color: color),
        label: const Text('重连'),
        onPressed: onReconnect,
      );
    }
    return Chip(
      visualDensity: VisualDensity.compact,
      avatar: Icon(Icons.circle, size: 10, color: color),
      label: Text(label),
    );
  }
}

class _DevicesPage extends StatelessWidget {
  const _DevicesPage({
    required this.session,
    required this.defaultDevice,
    required this.onLocalChanged,
    required this.presets,
    required this.permissionMessage,
    required this.permissionNeedsSettings,
    required this.onScan,
    required this.onOpenSettings,
  });

  final ChargerSessionActor session;
  final DefaultDeviceRecord? defaultDevice;
  final Future<void> Function() onLocalChanged;
  final PresetService presets;
  final String? permissionMessage;
  final bool permissionNeedsSettings;
  final Future<void> Function() onScan;
  final Future<void> Function() onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final defaultSeen =
        defaultDevice != null &&
        session.devices.any((device) => device.id == defaultDevice!.deviceKey);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        _InfoCard(
          title: '本机默认设备',
          icon: Icons.push_pin_outlined,
          child: defaultDevice == null
              ? const Text('尚未绑定。绑定只保存在本机，不会向充电器发送解绑命令。')
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '${defaultDevice!.name} · ${_suffix(defaultDevice!.deviceKey)}',
                    ),
                    Text(defaultSeen ? '本轮扫描已发现' : '本轮扫描未出现（离线）'),
                  ],
                ),
        ),
        FilledButton.icon(
          onPressed: session.isScanning ? null : onScan,
          icon: const Icon(Icons.radar),
          label: Text(session.isScanning ? '正在扫描附近设备…' : '搜索蓝牙设备'),
        ),
        if (permissionMessage != null)
          Card(
            child: ListTile(
              leading: const Icon(Icons.lock_outline),
              title: Text(permissionMessage!),
              trailing: permissionNeedsSettings
                  ? TextButton(
                      onPressed: onOpenSettings,
                      child: const Text('打开设置'),
                    )
                  : null,
            ),
          ),
        if (session.errorMessage != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              session.errorMessage!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        const SizedBox(height: 8),
        if (!session.isScanning && session.devices.isEmpty)
          const _EmptyState(
            icon: Icons.bluetooth_disabled,
            text: '暂无本轮扫描结果。搜索不按设备名称过滤，也不会显示历史缓存设备。',
          ),
        ...session.devices.map(
          (device) => Card(
            child: ListTile(
              leading: const CircleAvatar(child: Icon(Icons.ev_station)),
              title: Text(device.name.isEmpty ? '未命名蓝牙设备' : device.name),
              subtitle: Text(
                '设备后缀 ${_suffix(device.id)} · RSSI ${device.rssi} dBm',
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  IconButton(
                    tooltip: defaultDevice?.deviceKey == device.id
                        ? '当前默认设备'
                        : '设为默认设备',
                    onPressed: () async {
                      await presets.setDefaultDevice(
                        DefaultDeviceRecord(
                          deviceKey: device.id,
                          name: device.name.isEmpty ? '未命名蓝牙设备' : device.name,
                        ),
                      );
                      await onLocalChanged();
                    },
                    icon: Icon(
                      defaultDevice?.deviceKey == device.id
                          ? Icons.push_pin
                          : Icons.push_pin_outlined,
                    ),
                  ),
                  FilledButton(
                    onPressed: () => session.connect(device),
                    child: const Text('连接'),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (session.isConnected) ...<Widget>[
          const Divider(height: 32),
          Text('已连接 ${session.connectedDeviceName} · ${session.deviceSuffix}'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: <Widget>[
              OutlinedButton.icon(
                onPressed: session.isReadVerified
                    ? () async {
                        session.ensureDefaultBindingAllowed();
                        await presets.setDefaultDevice(
                          DefaultDeviceRecord(
                            deviceKey: session.connectedDeviceId!,
                            name: session.connectedDeviceName ?? '未命名蓝牙设备',
                            profileFingerprint: session.profileFingerprint!,
                          ),
                        );
                        await onLocalChanged();
                      }
                    : null,
                icon: const Icon(Icons.push_pin),
                label: const Text('设为默认设备'),
              ),
              TextButton(
                onPressed: session.disconnect,
                child: const Text('断开'),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _StatusPage extends StatelessWidget {
  const _StatusPage({required this.session, this.onReconnect});
  final ChargerSessionActor session;
  final Future<void> Function()? onReconnect;

  @override
  Widget build(BuildContext context) {
    final value = session.status;
    return RefreshIndicator(
      onRefresh: session.refreshStatus,
      child: ListView(
        padding: const EdgeInsets.all(16),
        physics: const AlwaysScrollableScrollPhysics(),
        children: <Widget>[
          if (!session.isReadVerified) ...<Widget>[
            const _EmptyState(
              icon: Icons.query_stats,
              text: '连接设备并通过 02 参数验证后，才开始查询实时状态。',
            ),
            if (session.errorMessage != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  session.errorMessage!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (onReconnect != null &&
                !session.isScanning &&
                switch (session.phase) {
                  ChargerSessionPhase.idle ||
                  ChargerSessionPhase.disconnected ||
                  ChargerSessionPhase.failed => true,
                  _ => false,
                })
              FilledButton.icon(
                onPressed: onReconnect,
                icon: const Icon(Icons.refresh),
                label: const Text('重连默认设备'),
              ),
          ] else ...<Widget>[
            ChargerControlCard(session: session),
            const SizedBox(height: 16),
            if (value == null)
              FilledButton.icon(
                onPressed: session.refreshStatus,
                icon: const Icon(Icons.refresh),
                label: const Text('查询实时状态'),
              )
            else ...<Widget>[
              _MetricGrid(
                items: <(String, String)>[
                  ('输出电压', _voltage(value.voltageHundredths)),
                  ('输出电流', _current(value.currentTenths)),
                  ('电量原始值', '${value.percentRaw}'),
                  ('时间原始值', '${value.timeRaw}'),
                  ('功率原始值', '${value.powerRaw}'),
                  ('容量原始值', '${value.capacityRaw}'),
                  ('温度原始值', '${value.temperatureRaw}'),
                  ('充电状态码', '${value.batteryStateRaw}'),
                  (
                    '故障码',
                    '0x${value.faultRaw.toRadixString(16).padLeft(2, '0')}',
                  ),
                ],
              ),
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text('除电压、电流外，其余字段单位尚需真实充电器核对，因此显示原始值。'),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _ParametersPage extends StatelessWidget {
  const _ParametersPage({required this.session});
  final ChargerSessionActor session;

  @override
  Widget build(BuildContext context) {
    final value = session.parameters;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        if (value == null)
          const _EmptyState(icon: Icons.tune, text: '连接后自动查询 02 参数。')
        else ...<Widget>[
          _MetricGrid(
            items: <(String, String)>[
              ('设定电压', _voltage(value.voltageHundredths)),
              ('设定电流', _current(value.currentTenths)),
              ('模式', value.modeRaw == 1 ? '锂电模式' : '非锂电模式 (${value.modeRaw})'),
              ('最大电流', '${value.maxCurrentRaw} A (设备原始限制)'),
              (
                '锁定状态',
                value.lockRaw == 0xA0
                    ? '已锁定'
                    : '未锁定 / 0x${value.lockRaw.toRadixString(16)}',
              ),
              ('设备版本', '${value.versionRaw}'),
            ],
          ),
          if (value.modeRaw != 1)
            const Card(
              child: ListTile(
                leading: Icon(Icons.warning_amber),
                title: Text('设备当前不是锂电模式'),
                subtitle: Text('App 写入时会固定使用锂电模式，但不会在未确认前自动修改。'),
              ),
            ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: session.isWriteVerified
                ? () => _showParameterEditor(context, session, value)
                : null,
            icon: const Icon(Icons.edit),
            label: const Text('修改电压和电流'),
          ),
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('取得有效 02 参数后即可修改；每次确认只发送一次 03，并用两次新的 02 读回核验结果。'),
          ),
          if (session.lastWriteResult != null)
            _WriteResultCard(result: session.lastWriteResult!),
        ],
      ],
    );
  }
}

class _PresetsPage extends StatelessWidget {
  const _PresetsPage({
    required this.session,
    required this.service,
    required this.presets,
    required this.onChanged,
  });
  final ChargerSessionActor session;
  final PresetService service;
  final List<UserPreset> presets;
  final Future<void> Function() onChanged;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        FilledButton.icon(
          onPressed: () => _editPreset(context),
          icon: const Icon(Icons.add),
          label: const Text('新建自定义预设'),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text('仅保存名称、电压和电流；应用仍需读取最新设备参数并再次确认。'),
        ),
        if (presets.isEmpty)
          const _EmptyState(
            icon: Icons.bookmarks_outlined,
            text: '没有内置模板，也没有自定义预设。',
          ),
        ...presets.asMap().entries.map((entry) {
          final index = entry.key;
          final preset = entry.value;
          return Card(
            child: ListTile(
              title: Text(preset.name),
              subtitle: Text(
                '${_voltage(preset.voltageHundredthsVolts)} · ${_current(preset.currentTenthsAmps)}',
              ),
              onTap: session.parameters == null
                  ? null
                  : () => _showParameterEditor(
                      context,
                      session,
                      session.parameters!,
                      initialVoltage: preset.voltageHundredthsVolts,
                      initialCurrent: preset.currentTenthsAmps,
                    ),
              trailing: PopupMenuButton<String>(
                onSelected: (action) async {
                  if (action == 'edit') {
                    await _editPreset(context, existing: preset);
                  } else if (action == 'up' && index > 0) {
                    await service.reorderUserPreset(preset.id, index - 1);
                    await onChanged();
                  } else if (action == 'down' && index < presets.length - 1) {
                    await service.reorderUserPreset(preset.id, index + 1);
                    await onChanged();
                  } else if (action == 'delete') {
                    await service.deleteUserPreset(preset.id);
                    await onChanged();
                  }
                },
                itemBuilder: (_) => <PopupMenuEntry<String>>[
                  const PopupMenuItem(value: 'edit', child: Text('编辑 / 重命名')),
                  PopupMenuItem(
                    value: 'up',
                    enabled: index > 0,
                    child: const Text('上移'),
                  ),
                  PopupMenuItem(
                    value: 'down',
                    enabled: index < presets.length - 1,
                    child: const Text('下移'),
                  ),
                  const PopupMenuItem(value: 'delete', child: Text('删除')),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }

  Future<void> _editPreset(BuildContext context, {UserPreset? existing}) async {
    final name = TextEditingController(text: existing?.name ?? '');
    final voltage = TextEditingController(
      text: existing == null
          ? ''
          : (existing.voltageHundredthsVolts / 100).toStringAsFixed(2),
    );
    final current = TextEditingController(
      text: existing == null
          ? ''
          : (existing.currentTenthsAmps / 10).toStringAsFixed(1),
    );
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(existing == null ? '新建预设' : '编辑预设'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: '名称'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: voltage,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(labelText: '电压 (V)'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: current,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(labelText: '电流 (A)'),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (accepted != true || !context.mounted) return;
    try {
      final v = ((double.parse(voltage.text) * 100).round());
      final c = ((double.parse(current.text) * 10).round());
      ChargerParameterValidator.validateStatic(
        voltageHundredths: v,
        currentTenths: c,
      );
      if (existing == null) {
        await service.createUserPreset(
          name: name.text,
          voltageHundredthsVolts: v,
          currentTenthsAmps: c,
        );
      } else {
        await service.updateUserPreset(
          UserPreset(
            id: existing.id,
            name: name.text,
            voltageHundredthsVolts: v,
            currentTenthsAmps: c,
          ),
        );
      }
      await onChanged();
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('无法保存：$error')));
      }
    }
  }
}

class _SettingsPage extends StatelessWidget {
  const _SettingsPage({
    required this.session,
    required this.defaultDevice,
    required this.service,
    required this.onChanged,
  });
  final ChargerSessionActor session;
  final DefaultDeviceRecord? defaultDevice;
  final PresetService service;
  final Future<void> Function() onChanged;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        if (defaultDevice != null)
          ListTile(
            title: const Text('解除本机默认设备'),
            subtitle: Text(
              '${defaultDevice!.name} · ${_suffix(defaultDevice!.deviceKey)}',
            ),
            trailing: TextButton(
              onPressed: () async {
                await service.clearDefaultDevice();
                await onChanged();
              },
              child: const Text('解除'),
            ),
          ),
        ListTile(
          leading: const Icon(Icons.receipt_long_outlined),
          title: const Text('运行日志'),
          subtitle: Text(
            '${session.diagnostics.entries.length} 条；支持复制、下载和清空，内容已脱敏',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _showDiagnosticLog(context, session.diagnostics),
        ),
        const AboutListTile(
          applicationName: 'ADS 充电器',
          applicationVersion: '1.0.0',
          applicationLegalese: 'Android / iOS BLE 直连控制端',
        ),
      ],
    );
  }
}

Future<void> _showDiagnosticLog(BuildContext context, DiagnosticLog log) async {
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => Dialog.fullscreen(
      child: AnimatedBuilder(
        animation: log,
        builder: (context, _) {
          final entries = log.entries.reversed.toList(growable: false);
          return Scaffold(
            appBar: AppBar(
              title: Text('运行日志 (${entries.length})'),
              leading: IconButton(
                onPressed: () => Navigator.pop(dialogContext),
                icon: const Icon(Icons.close),
              ),
              actions: <Widget>[
                IconButton(
                  tooltip: '复制全部',
                  onPressed: entries.isEmpty
                      ? null
                      : () async {
                          await Clipboard.setData(
                            ClipboardData(text: log.exportText()),
                          );
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('日志已复制到剪贴板')),
                            );
                          }
                        },
                  icon: const Icon(Icons.copy_all_outlined),
                ),
                IconButton(
                  tooltip: '下载日志',
                  onPressed: () async {
                    try {
                      final file = await const DiagnosticExporter().download(
                        log,
                      );
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('日志已保存：${file.path}')),
                        );
                      }
                    } catch (error) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(
                          context,
                        ).showSnackBar(SnackBar(content: Text('下载失败：$error')));
                      }
                    }
                  },
                  icon: const Icon(Icons.download_outlined),
                ),
                IconButton(
                  tooltip: '清空日志',
                  onPressed: entries.isEmpty
                      ? null
                      : () async {
                          final confirmed = await showDialog<bool>(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: const Text('清空运行日志？'),
                              content: const Text('此操作只清空本次 App 运行期间的诊断记录。'),
                              actions: <Widget>[
                                TextButton(
                                  onPressed: () =>
                                      Navigator.pop(context, false),
                                  child: const Text('取消'),
                                ),
                                FilledButton(
                                  onPressed: () => Navigator.pop(context, true),
                                  child: const Text('清空'),
                                ),
                              ],
                            ),
                          );
                          if (confirmed == true) log.clear();
                        },
                  icon: const Icon(Icons.delete_sweep_outlined),
                ),
              ],
            ),
            body: entries.isEmpty
                ? const _EmptyState(
                    icon: Icons.receipt_long_outlined,
                    text: '暂无运行日志。扫描、连接、查询和参数写入过程会记录在这里。',
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(12),
                    itemCount: entries.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final entry = entries[index];
                      return ListTile(
                        dense: true,
                        title: Text(entry.message),
                        subtitle: Text(
                          '${entry.at.toLocal().toIso8601String()} · ${_diagnosticKindLabel(entry.kind)}'
                          '${entry.deviceAlias == null ? '' : ' · ${entry.deviceAlias}'}',
                        ),
                      );
                    },
                  ),
          );
        },
      ),
    ),
  );
}

String _diagnosticKindLabel(DiagnosticKind kind) => switch (kind) {
  DiagnosticKind.adapter => '蓝牙状态',
  DiagnosticKind.scan => '扫描',
  DiagnosticKind.connection => '连接',
  DiagnosticKind.profile => '服务发现',
  DiagnosticKind.command => '命令',
  DiagnosticKind.timeout => '超时',
  DiagnosticKind.disconnect => '断开',
  DiagnosticKind.parseFailure => '解析失败',
  DiagnosticKind.verification => '写入核验',
};

Future<void> _showParameterEditor(
  BuildContext context,
  ChargerSessionActor session,
  ChargerParameters current, {
  int? initialVoltage,
  int? initialCurrent,
}) async {
  // Refresh first so unchanged fields and language always come from a fresh 02.
  try {
    await session.refreshParameters();
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('无法取得最新设备参数：$error')));
    }
    return;
  }
  if (!context.mounted) return;
  final latest = session.parameters!;
  final voltage = TextEditingController(
    text: ((initialVoltage ?? latest.voltageHundredths) / 100).toStringAsFixed(
      2,
    ),
  );
  final amperage = TextEditingController(
    text: ((initialCurrent ?? latest.currentTenths) / 10).toStringAsFixed(1),
  );
  final target = await showDialog<(int, int)?>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('确认修改充电参数'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('目标设备：${session.connectedDeviceName} · ${session.deviceSuffix}'),
          Text(
            '当前：${_voltage(latest.voltageHundredths)} / ${_current(latest.currentTenths)}',
          ),
          const Text('写入模式：锂电模式（固定）'),
          const SizedBox(height: 12),
          TextField(
            controller: voltage,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: '目标电压 (V)'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: amperage,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: '目标电流 (A)'),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            try {
              final v = (double.parse(voltage.text) * 100).round();
              final a = (double.parse(amperage.text) * 10).round();
              ChargerParameterValidator.validateForCharger(
                voltageHundredths: v,
                currentTenths: a,
                maxCurrentRaw: latest.maxCurrentRaw,
              );
              Navigator.pop(context, (v, a));
            } catch (error) {
              ScaffoldMessenger.of(context)
                  .showSnackBar(SnackBar(content: Text('输入无效：$error')));
            }
          },
          child: const Text('确认并发送一次'),
        ),
      ],
    ),
  );
  if (target == null || !context.mounted) return;
  try {
    final result = await session.writeLithiumParameters(
      voltageHundredths: target.$1,
      currentTenths: target.$2,
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.outcome == ParameterWriteOutcome.verified
                ? '修改成功：设备读回一致'
                : '未确认生效：${result.message}',
          ),
        ),
      );
    }
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('修改未发送：$error')));
    }
  }
}

class _WriteResultCard extends StatelessWidget {
  const _WriteResultCard({required this.result});
  final ParameterWriteResult result;
  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      leading: Icon(
        result.outcome == ParameterWriteOutcome.verified
            ? Icons.verified
            : Icons.help_outline,
      ),
      title: Text(
        result.outcome == ParameterWriteOutcome.verified ? '修改成功' : '未确认生效',
      ),
      subtitle: Text(
        '${result.message ?? ''}\n目标 ${_voltage(result.targetVoltageHundredths)} / ${_current(result.targetCurrentTenths)}${result.actual == null ? '\n未取得设备读回值' : '\n实际 ${_voltage(result.actual!.voltageHundredths)} / ${_current(result.actual!.currentTenths)} / mode=${result.actual!.modeRaw}'}',
      ),
      isThreeLine: true,
    ),
  );
}

class _MetricGrid extends StatelessWidget {
  const _MetricGrid({required this.items});
  final List<(String, String)> items;
  @override
  Widget build(BuildContext context) {
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    final itemHeight = (104 + (textScale - 1) * 44).clamp(104, 148).toDouble();
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisExtent: itemHeight,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: items.length,
      itemBuilder: (_, index) => Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Text(
                items[index].$1,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium,
              ),
              const SizedBox(height: 4),
              Flexible(
                child: Text(
                  items[index].$2,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.title,
    required this.icon,
    required this.child,
  });
  final String title;
  final IconData icon;
  final Widget child;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(icon),
              const SizedBox(width: 8),
              Text(title, style: Theme.of(context).textTheme.titleMedium),
            ],
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    ),
  );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 36),
    child: Column(
      children: <Widget>[
        Icon(icon, size: 52, color: Theme.of(context).colorScheme.outline),
        const SizedBox(height: 12),
        Text(text, textAlign: TextAlign.center),
      ],
    ),
  );
}

String _voltage(int hundredths) => '${(hundredths / 100).toStringAsFixed(2)} V';
String _current(int tenths) => '${(tenths / 10).toStringAsFixed(1)} A';
String _suffix(String id) {
  final compact = id.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
  return (compact.length <= 6 ? compact : compact.substring(compact.length - 6))
      .toUpperCase();
}
