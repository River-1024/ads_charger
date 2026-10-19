import 'dart:async';

import 'package:flutter/material.dart';

import '../application/session/charger_session_actor.dart';
import '../domain/charger_models/lock_target.dart';

/// Home-page charger control ported from the mini program `pages/index`:
/// long-press force activation (command 04) and explicit manual button lock
/// adjustment (command 09).
///
/// Two safety properties come straight from the mini program's home page and
/// the repository's write rules:
///
/// * The lock direction is never toggled from a local optimistic guess. The
///   user picks 锁定 or 开启, preselected from the lock flag of the latest valid
///   02 reply, and the app refuses to send command 09 when the target already
///   matches the device readback.
/// * The force-activation button keeps the mini program's 3 second long press,
///   and moving the finger away cancels it before anything is sent.
///
/// Every send additionally requires an explicit confirmation dialog, and one
/// confirmation issues exactly one control frame.
class ChargerControlCard extends StatefulWidget {
  const ChargerControlCard({super.key, required this.session});

  final ChargerSessionActor session;

  /// The mini program's activation hold duration.
  static const Duration forceActivateHold = Duration(seconds: 3);

  @override
  State<ChargerControlCard> createState() => _ChargerControlCardState();
}

class _ChargerControlCardState extends State<ChargerControlCard> {
  LockTarget? _selected;
  LockTarget? _selectionSyncedFrom;
  Timer? _holdTimer;
  bool _holdActive = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _syncSelectionFromDevice();
  }

  @override
  void didUpdateWidget(ChargerControlCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncSelectionFromDevice();
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    super.dispose();
  }

  /// Preselects the direction the device currently reports, and re-syncs after
  /// every new accepted 02 so the UI cannot keep showing a stale intent.
  void _syncSelectionFromDevice() {
    final reported = widget.session.currentLockTarget;
    if (reported == null || identical(reported, _selectionSyncedFrom)) {
      return;
    }
    _selectionSyncedFrom = reported;
    _selected = reported;
  }

  void _startHold() {
    if (_busy || !widget.session.canOperateControl) return;
    _holdTimer?.cancel();
    setState(() => _holdActive = true);
    _holdTimer = Timer(ChargerControlCard.forceActivateHold, () {
      _holdTimer = null;
      if (!mounted) return;
      setState(() => _holdActive = false);
      unawaited(_activate());
    });
  }

  void _cancelHold() {
    if (_holdTimer == null && !_holdActive) return;
    _holdTimer?.cancel();
    _holdTimer = null;
    if (mounted) setState(() => _holdActive = false);
  }

  Future<void> _activate() async {
    final confirmed = await _confirm(
      title: '强制激活充电器？',
      body:
          '将向设备发送一次固定 04 帧（小程序为长按 3 秒触发）。\n\n'
          '协议 02 回包没有可核对的激活字段，App 只能把 04 应答帧记录为'
          '“设备已回包”，不会显示为已验证。\n\n'
          '本次确认只发送一次，不会自动重发。',
      confirmLabel: '确认发送一次',
    );
    if (confirmed != true || !mounted) return;
    await _runControlWrite(targetLock: null);
  }

  Future<void> _applyLock(LockTarget target) async {
    final reported = widget.session.currentLockTarget;
    if (reported == target) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('设备当前已是「${target.label}」，未发送任何写入。')),
      );
      return;
    }
    final wire = target.wireByte.toRadixString(16).padLeft(2, '0').toUpperCase();
    final confirmed = await _confirm(
      title: '${target.label}？',
      body:
          '将向设备发送一次固定 09 帧，数据字节 0x$wire。\n\n'
          '${reported == null ? '尚未取得设备当前锁定状态。' : '设备当前读回为「${reported.label}」。'}\n\n'
          '发送后会重新查询 02，只有锁定标志读回与目标一致，App 才显示为已验证。\n'
          '本次确认只发送一次，不会自动重发。',
      confirmLabel: '确认发送一次',
    );
    if (confirmed != true || !mounted) return;
    await _runControlWrite(targetLock: target);
  }

  Future<void> _runControlWrite({required LockTarget? targetLock}) async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final operationId = DateTime.now()
          .toUtc()
          .microsecondsSinceEpoch
          .toString();
      final result = await widget.session.operateControl(
        operationId: operationId,
        targetLock: targetLock,
      );
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(_snackText(result))));
    } catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('未发送：$error')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _snackText(ControlWriteResult result) =>
      switch (result.outcome) {
        ControlWriteOutcome.acknowledged => '${result.label}已由 02 读回确认',
        ControlWriteOutcome.acknowledgedUnverified =>
          '${result.label}：设备已回 04 应答帧，但无法用 02 读回核验',
        ControlWriteOutcome.unacknowledged =>
          '${result.label}未确认：${result.message ?? '无有效应答'}',
      };

  Future<bool?> _confirm({
    required String title,
    required String body,
    required String confirmLabel,
  }) => showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '目标设备：${widget.session.connectedDeviceName} · ${widget.session.deviceSuffix}',
            ),
            const SizedBox(height: 12),
            Text(body),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final reported = session.currentLockTarget;
    final enabled = session.canOperateControl && !_busy;
    final selected = _selected;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.power_settings_new),
                const SizedBox(width: 8),
                Text(
                  '充电器控制',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '对应小程序首页的两项控制写入。写入前会二次确认，'
              '一次确认只发送一帧，且不会被周期查询穿插。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const Divider(height: 24),
            Text(
              reported == null
                  ? '锁定状态：尚未取得 02 读回值'
                  : '锁定状态：${reported.label}',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            SegmentedButton<LockTarget>(
              segments: <ButtonSegment<LockTarget>>[
                for (final target in LockTarget.values)
                  ButtonSegment<LockTarget>(
                    value: target,
                    label: Text(target == LockTarget.lock ? '锁定' : '开启'),
                  ),
              ],
              selected: <LockTarget>{?selected},
              emptySelectionAllowed: true,
              onSelectionChanged: enabled
                  ? (selection) {
                      setState(() => _selected = selection.firstOrNull);
                    }
                  : null,
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: enabled && selected != null
                  ? () => _applyLock(selected)
                  : null,
              icon: const Icon(Icons.lock_outline),
              label: Text(
                selected == null ? '请选择目标状态' : '发送 ${selected.label}',
              ),
            ),
            if (selected != null && reported == selected)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('设备读回已是该状态，发送按钮会拒绝重复写入。'),
              ),
            const Divider(height: 24),
            GestureDetector(
              onLongPressStart: enabled ? (_) => _startHold() : null,
              onLongPressEnd: enabled ? (_) => _cancelHold() : null,
              onLongPressCancel: enabled ? _cancelHold : null,
              child: FilledButton.icon(
                onPressed: null,
                icon: Icon(
                  _holdActive ? Icons.hourglass_top : Icons.bolt_outlined,
                ),
                label: Text(
                  !session.canOperateControl
                      ? '强制激活（需先取得有效 02）'
                      : _busy
                      ? '控制写入核验中…'
                      : _holdActive
                      ? '继续按住…'
                      : '长按 3 秒强制激活',
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                '电池处于休眠状态时，需长按 3 秒充电器强制输出。'
                '设备可能以 HCI 0x13 主动断开，App 不会因此自动重发本次控制帧。',
              ),
            ),
            if (session.lastControlResult != null) ...<Widget>[
              const SizedBox(height: 12),
              _ControlResultCard(result: session.lastControlResult!),
            ],
          ],
        ),
      ),
    );
  }
}

class _ControlResultCard extends StatelessWidget {
  const _ControlResultCard({required this.result});
  final ControlWriteResult result;

  @override
  Widget build(BuildContext context) {
    final (icon, headline) = switch (result.outcome) {
      ControlWriteOutcome.acknowledged => (
        Icons.verified,
        '${result.label}·已验证',
      ),
      ControlWriteOutcome.acknowledgedUnverified => (
        Icons.help_outline,
        '${result.label}·已回包未核验',
      ),
      ControlWriteOutcome.unacknowledged => (
        Icons.error_outline,
        '${result.label}·未确认',
      ),
    };
    final parameters = result.parameters;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon),
      title: Text(headline),
      subtitle: Text(
        '${result.message ?? ''}'
        '${parameters == null ? '' : '\n新 02 读回锁定标志：0x${parameters.lockRaw.toRadixString(16).padLeft(2, '0').toUpperCase()}'}',
      ),
      isThreeLine: parameters != null,
    );
  }
}
