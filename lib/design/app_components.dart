import 'package:flutter/material.dart';

import 'app_tokens.dart';

/// 统一的描边卡片。替代裸 `Card`，保证全 app 的圆角、描边与内边距一致。
///
/// [padding] 传 `EdgeInsets.zero` 用于包 `ListTile` —— `ListTile` 自带
/// 内容内边距，再叠一层会让内容离边框过远。
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.lg),
    this.margin = EdgeInsets.zero,
    this.color,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final Color? color;

  @override
  Widget build(BuildContext context) => Card(
    margin: margin,
    color: color,
    child: Padding(padding: padding, child: child),
  );
}

/// 分区标题：图标 + 标题，右侧可放状态或操作。
class AppSectionHeader extends StatelessWidget {
  const AppSectionHeader({
    super.key,
    required this.title,
    this.icon,
    this.trailing,
  });

  final String title;
  final IconData? icon;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: <Widget>[
        if (icon != null) ...<Widget>[
          Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: AppSpacing.sm),
        ],
        Expanded(
          child: Text(
            title,
            style: theme.textTheme.titleSmall,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (trailing case final Widget widget) widget,
      ],
    );
  }
}

/// 主读数：标签 + 大号数值 + 单位。
///
/// 数值与单位分两个 widget，单位用较小的字号，避免「13.85 V」里的单位
/// 参与等宽数字计算后把数值挤偏。
class AppHeroMetric extends StatelessWidget {
  const AppHeroMetric({
    super.key,
    required this.label,
    required this.value,
    this.unit,
  });

  final String label;
  final String value;
  final String? unit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          label,
          style: AppText.label(context).copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: AppSpacing.xs),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: <Widget>[
            Flexible(
              child: Text(
                value,
                style: AppText.hero(context).copyWith(
                  color: theme.colorScheme.onSurface,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (unit != null) ...<Widget>[
              const SizedBox(width: AppSpacing.xs),
              Text(
                unit!,
                style: AppText.unit(context).copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

/// 次级读数格。
class AppMetricTile extends StatelessWidget {
  const AppMetricTile({
    super.key,
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.md,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.inset,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            label,
            style: AppText.label(context).copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.3,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            value,
            style: AppText.metric(context).copyWith(
              color: theme.colorScheme.onSurface,
              height: 1.2,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

/// 指标网格：两列排布的低频读数。
///
/// 行高按当前文字缩放系数计算。系统放大字体时若沿用固定行高，标签与数值
/// 会被裁切并抛出 overflow 异常，因此这里把缩放带来的额外高度显式算进去。
class AppMetricGrid extends StatelessWidget {
  const AppMetricGrid({super.key, required this.items});

  final List<(String, String)> items;

  @override
  Widget build(BuildContext context) {
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    // 基准 88 覆盖「两行标签 + 一行数值 + 内边距」在 1.0 缩放下的高度；
    // 斜率 64 为每单位缩放预留约一行标签的高度。
    final itemHeight = (88 + (textScale - 1) * 64).clamp(88, 230).toDouble();
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisExtent: itemHeight,
        crossAxisSpacing: AppSpacing.sm,
        mainAxisSpacing: AppSpacing.sm,
      ),
      itemCount: items.length,
      itemBuilder: (_, index) => AppMetricTile(
        label: items[index].$1,
        value: items[index].$2,
      ),
    );
  }
}

/// 提示条：承载安全语义说明。
///
/// 改造前这些说明是裸露的段落文字，与读数混在同一层级；放进提示条后
/// 它们在视觉上明确降级为「注意事项」，但文案本身保持原样。
class AppNotice extends StatelessWidget {
  const AppNotice({
    super.key,
    required this.text,
    this.title,
    this.tone = AppNoticeTone.info,
    this.icon,
  });

  final String text;

  /// 可选标题。安全提示常常是「一句结论 + 一句限定」两段结构，
  /// 合并成一句话会丢掉原有的语义边界，因此标题与正文分开保留。
  final String? title;
  final AppNoticeTone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (background, foreground, fallbackIcon) = switch (tone) {
      AppNoticeTone.info => (
        scheme.surfaceContainerHigh,
        scheme.onSurfaceVariant,
        Icons.info_outline,
      ),
      AppNoticeTone.caution => (
        scheme.warningContainer,
        scheme.warning,
        Icons.warning_amber_rounded,
      ),
      AppNoticeTone.danger => (
        scheme.errorContainer,
        scheme.onErrorContainer,
        Icons.error_outline,
      ),
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon ?? fallbackIcon, size: 18, color: foreground),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (title case final String heading) ...<Widget>[
                  Text(
                    heading,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: foreground,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                ],
                Text(
                  text,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: foreground,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 提示条语气。
enum AppNoticeTone {
  /// 中性说明。
  info,

  /// 需要留意的限制条件。
  caution,

  /// 危险操作提示。
  danger,
}

/// 折叠区：承载低频数据（例如尚未标定单位的原始值）。
class AppDisclosure extends StatelessWidget {
  const AppDisclosure({
    super.key,
    required this.title,
    required this.child,
    this.initiallyExpanded = false,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final Widget child;
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Theme(
        // 折叠箭头自带一条分隔线，与卡片的描边重复。
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: initiallyExpanded,
          tilePadding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.xs,
          ),
          childrenPadding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            0,
            AppSpacing.lg,
            AppSpacing.lg,
          ),
          shape: const Border(),
          collapsedShape: const Border(),
          title: Text(
            title,
            style: theme.textTheme.titleSmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: subtitle == null
              ? null
              : Text(
                  subtitle!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
          children: <Widget>[child],
        ),
      ),
    );
  }
}

/// 空态：图标 + 说明文字。
class AppEmptyState extends StatelessWidget {
  const AppEmptyState({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxl),
    child: Column(
      children: <Widget>[
        Icon(icon, size: 52, color: Theme.of(context).colorScheme.outline),
        const SizedBox(height: AppSpacing.md),
        Text(
          text,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
      ],
    ),
  );
}

/// 带图标标题的信息卡。
class AppInfoCard extends StatelessWidget {
  const AppInfoCard({
    super.key,
    required this.title,
    required this.icon,
    required this.child,
  });

  final String title;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleSmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          child,
        ],
      ),
    );
  }
}
