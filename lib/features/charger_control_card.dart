import 'dart:async';

import 'package:flutter/material.dart';

import '../application/session/charger_session_actor.dart';
import '../design/app_components.dart';
import '../design/app_tokens.dart';
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
///
/// The layout mirrors that split on purpose. The lock direction is an ordinary
/// setting and lives in one inset group, while force activation is a one-shot
/// wake-up of a sleeping charger and gets its own alert-coloured block. Every
/// safety sentence is rendered as an [AppNotice], so "read this before
/// writing" never blends into "these are the buttons".
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
    builder: (context) {
      final theme = Theme.of(context);
      final scheme = theme.colorScheme;
      return AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(
                    Icons.link,
                    size: 14,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Expanded(
                    child: Text(
                      '目标设备：${widget.session.connectedDeviceName} · ${widget.session.deviceSuffix}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
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
            // A confirmed write reaches real hardware, so the affirmative
            // action is tinted with the error palette instead of the calm
            // primary colour.
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            child: Text(confirmLabel),
          ),
        ],
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final reported = session.currentLockTarget;
    final enabled = session.canOperateControl && !_busy;
    final selected = _selected;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const AppSectionHeader(
            title: '充电器控制',
            icon: Icons.power_settings_new,
          ),
          const SizedBox(height: AppSpacing.md),
          AppNotice(
            text:
                '对应小程序首页的两项控制写入。写入前会二次确认，'
                '一次确认只发送一帧，且不会被周期查询穿插。',
          ),
          const SizedBox(height: AppSpacing.lg),
          _LockDirectionGroup(
            reported: reported,
            selected: selected,
            enabled: enabled,
            onDirectionChanged: (target) => setState(() => _selected = target),
            onSend: _applyLock,
          ),
          const SizedBox(height: AppSpacing.lg),
          const Divider(height: AppSpacing.xl),
          const SizedBox(height: AppSpacing.lg),
          AppNotice(
            tone: AppNoticeTone.caution,
            text:
                '电池处于休眠状态时，需长按 3 秒充电器强制输出。'
                '设备可能以 HCI 0x13 主动断开，App 不会因此自动重发本次控制帧。',
          ),
          const SizedBox(height: AppSpacing.md),
          _ForceActivationButton(
            holdActive: _holdActive,
            busy: _busy,
            canOperate: session.canOperateControl,
            onLongPressStart: enabled ? (_) => _startHold() : null,
            onLongPressEnd: enabled ? (_) => _cancelHold() : null,
            onLongPressCancel: enabled ? _cancelHold : null,
          ),
          if (session.lastControlResult != null) ...<Widget>[
            const SizedBox(height: AppSpacing.lg),
            _ControlResultCard(result: session.lastControlResult!),
          ],
        ],
      ),
    );
  }
}

/// Lock-direction group: device readback, direction picker and send button.
///
/// The three pieces are drawn inside one inset panel so they read as a single
/// "read the device, pick a direction, send it" control instead of three
/// unrelated widgets, and so the group stays visually apart from the
/// force-activation action below it.
class _LockDirectionGroup extends StatelessWidget {
  const _LockDirectionGroup({
    required this.reported,
    required this.selected,
    required this.enabled,
    required this.onDirectionChanged,
    required this.onSend,
  });

  /// Direction reported by the latest accepted 02 reply.
  final LockTarget? reported;

  /// Direction the user is aiming at; `null` means "nothing picked yet".
  final LockTarget? selected;

  /// Whether a control write may be issued at all right now.
  final bool enabled;

  final ValueChanged<LockTarget?> onDirectionChanged;
  final ValueChanged<LockTarget> onSend;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final current = reported;
    final target = selected;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: scheme.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: AppSpacing.sm,
                height: AppSpacing.sm,
                decoration: BoxDecoration(
                  color: current == null ? scheme.outline : scheme.accent,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  current == null
                      ? '锁定状态：尚未取得 02 读回值'
                      : '锁定状态：${current.label}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: current == null
                        ? scheme.onSurfaceVariant
                        : scheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          SegmentedButton<LockTarget>(
            segments: <ButtonSegment<LockTarget>>[
              for (final direction in LockTarget.values)
                ButtonSegment<LockTarget>(
                  value: direction,
                  label: Text(direction == LockTarget.lock ? '锁定' : '开启'),
                ),
            ],
            selected: <LockTarget>{?target},
            emptySelectionAllowed: true,
            expandedInsets: EdgeInsets.zero,
            onSelectionChanged: enabled
                ? (selection) => onDirectionChanged(selection.firstOrNull)
                : null,
          ),
          const SizedBox(height: AppSpacing.md),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: enabled && target != null ? () => onSend(target) : null,
              icon: const Icon(Icons.lock_outline),
              label: Text(
                target == null ? '请选择目标状态' : '发送 ${target.label}',
              ),
            ),
          ),
          if (target != null && current == target) ...<Widget>[
            const SizedBox(height: AppSpacing.md),
            const AppNotice(text: '设备读回已是该状态，发送按钮会拒绝重复写入。'),
          ],
        ],
      ),
    );
  }
}

/// Force-activation control: the one-shot wake-up of a sleeping charger.
///
/// The Material button itself stays permanently disabled — the enclosing
/// [GestureDetector] owns the 3 second hold — so the button is tinted with
/// the error palette to read as a distinct, higher-consequence action rather
/// than as a second primary button. The tint also carries the "held" state,
/// because a disabled button has no other way to show it.
class _ForceActivationButton extends StatelessWidget {
  const _ForceActivationButton({
    required this.holdActive,
    required this.busy,
    required this.canOperate,
    required this.onLongPressStart,
    required this.onLongPressEnd,
    required this.onLongPressCancel,
  });

  /// Whether the 3 second hold is currently running.
  final bool holdActive;

  /// Whether a control write is still being verified.
  final bool busy;

  /// Whether the session has a valid 02 reply to write against.
  final bool canOperate;

  final GestureLongPressStartCallback? onLongPressStart;
  final GestureLongPressEndCallback? onLongPressEnd;
  final VoidCallback? onLongPressCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final label = !canOperate
        ? '强制激活（需先取得有效 02）'
        : busy
        ? '控制写入核验中…'
        : holdActive
        ? '继续按住…'
        : '长按 3 秒强制激活';
    return SizedBox(
      width: double.infinity,
      child: GestureDetector(
        onLongPressStart: onLongPressStart,
        onLongPressEnd: onLongPressEnd,
        onLongPressCancel: onLongPressCancel,
        child: FilledButton.icon(
          onPressed: null,
          style: ButtonStyle(
            // Shape, padding and type come from the app's filledButtonTheme,
            // so only the two colours are restated here.
            backgroundColor: WidgetStateProperty.resolveWith<Color?>(
              (_) => holdActive ? scheme.error : scheme.errorContainer,
            ),
            foregroundColor: WidgetStateProperty.resolveWith<Color?>(
              (_) => holdActive ? scheme.onError : scheme.onErrorContainer,
            ),
          ),
          icon: Icon(holdActive ? Icons.hourglass_top : Icons.bolt_outlined),
          label: Text(label),
        ),
      ),
    );
  }
}

/// Result of the last control write.
///
/// The outcome drives the whole card's colour, because the three outcomes
/// mean very different things: verified, delivered but unverifiable, and not
/// confirmed at all.
class _ControlResultCard extends StatelessWidget {
  const _ControlResultCard({required this.result});
  final ControlWriteResult result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final parameters = result.parameters;
    final (icon, headline, background, foreground) = switch (result.outcome) {
      ControlWriteOutcome.acknowledged => (
        Icons.verified,
        '${result.label}·已验证',
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
      ),
      ControlWriteOutcome.acknowledgedUnverified => (
        Icons.help_outline,
        '${result.label}·已回包未核验',
        scheme.warningContainer,
        scheme.warning,
      ),
      ControlWriteOutcome.unacknowledged => (
        Icons.error_outline,
        '${result.label}·未确认',
        scheme.errorContainer,
        scheme.onErrorContainer,
      ),
    };
    final message = result.message ?? '';
    return AppCard(
      color: background,
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 18, color: foreground),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  headline,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: foreground,
                  ),
                ),
                if (message.isNotEmpty) ...<Widget>[
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    message,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: foreground,
                      height: 1.5,
                    ),
                  ),
                ],
                if (parameters != null) ...<Widget>[
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    '新 02 读回锁定标志：0x${parameters.lockRaw.toRadixString(16).padLeft(2, '0').toUpperCase()}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: foreground,
                      height: 1.5,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
