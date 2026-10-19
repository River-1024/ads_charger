import 'package:flutter/material.dart';

/// 设计层刻度：间距、圆角、动效与字阶。
///
/// 这一层存在的理由：改造前所有视觉决策都以字面量散落在各 widget 中
/// （`EdgeInsets.all(16)`、`SizedBox(height: 8)`、`BorderRadius.circular(12)`），
/// 想统一调整圆角或节奏只能逐处搜索替换。新界面沿用这里的刻度即可保持一致。
abstract final class AppSpacing {
  const AppSpacing._();

  /// 4 —— 图标与文字、标签与数值的最小间隔。
  static const double xs = 4;

  /// 8 —— 同组元素内部间距。
  static const double sm = 8;

  /// 12 —— 元素组之间。
  static const double md = 12;

  /// 16 —— 卡片内边距、页面左右边距。
  static const double lg = 16;

  /// 24 —— 区块之间。
  static const double xl = 24;

  /// 32 —— 页面分节留白。
  static const double xxl = 32;
}

/// 圆角刻度。层级越高的容器圆角越大，保持整体柔和但不失结构感。
abstract final class AppRadius {
  const AppRadius._();

  /// 8 —— 输入框、紧凑控件。
  static const double sm = 8;

  /// 12 —— 按钮、指标格。
  static const double md = 12;

  /// 16 —— 卡片。
  static const double lg = 16;

  /// 20 —— 对话框、主读数块。
  static const double xl = 20;

  /// 999 —— 胶囊（状态标签）。
  static const double pill = 999;
}

/// 动效刻度。
abstract final class AppMotion {
  const AppMotion._();

  /// 150ms —— 按下反馈、展开收起。
  static const Duration fast = Duration(milliseconds: 150);

  /// 240ms —— 常规过渡。
  static const Duration normal = Duration(milliseconds: 240);

  /// 400ms —— 强调过渡。
  static const Duration slow = Duration(milliseconds: 400);
}

/// 字阶辅助。
///
/// 仪表盘读数必须使用等宽数字（tabular figures）：等比例数字的字宽会随数值
/// 变化，遥测每次刷新都会让整行左右跳动，等宽数字则保持列对齐。
abstract final class AppText {
  const AppText._();

  static const List<FontFeature> _tabular = <FontFeature>[
    FontFeature.tabularFigures(),
  ];

  /// 主读数（Hero 区）。
  static TextStyle hero(BuildContext context) =>
      (Theme.of(context).textTheme.displayMedium ??
              const TextStyle(fontSize: 32, fontWeight: FontWeight.w600))
          .copyWith(fontFeatures: _tabular);

  /// 次级读数（指标格）。
  static TextStyle metric(BuildContext context) =>
      (Theme.of(context).textTheme.headlineSmall ??
              const TextStyle(fontSize: 20, fontWeight: FontWeight.w600))
          .copyWith(fontFeatures: _tabular);

  /// 指标单位：跟在主数值后面，不参与等宽计算。
  static TextStyle unit(BuildContext context) =>
      Theme.of(context).textTheme.titleMedium ??
      const TextStyle(fontSize: 15, fontWeight: FontWeight.w600);

  /// 分区标题 / 指标名。
  static TextStyle label(BuildContext context) =>
      Theme.of(context).textTheme.labelMedium ??
      const TextStyle(fontSize: 12, fontWeight: FontWeight.w600);

  /// 辅助说明文字。
  static TextStyle caption(BuildContext context) =>
      Theme.of(context).textTheme.bodySmall ??
      const TextStyle(fontSize: 12.5);
}

/// 语义色扩展：从 `ColorScheme` 派生，避免 widget 里出现第二套色板。
///
/// 浅色下 `surfaceContainerLowest` 是页面画布、`surface` 是卡片；
/// 深色下同一组槽位自动翻转成「近黑画布 + 略亮卡片」，因此所有页面
/// 只引用语义名，不需要为深浅两套主题各写一遍布局。
extension AppPalette on ColorScheme {
  /// 页面画布底色。
  Color get canvas => surfaceContainerLowest;

  /// 卡片底色。
  Color get card => surface;

  /// 嵌套底色（指标格、输入框、分组区块）。
  Color get inset => surfaceContainerHigh;

  /// 1px 描边色。
  Color get hairline => outlineVariant;

  /// 强调色，用于关键读数与状态。
  Color get accent => primary;

  /// 警示色。`ColorScheme` 没有 warning 槽位，这里按亮度各定义一个，
  /// 保证浅色下深字深底、深色下浅字浅底都满足对比度要求。
  Color get warning => brightness == Brightness.dark
      ? const Color(0xFFF2C879)
      : const Color(0xFF8A5600);

  /// 警示底色。
  Color get warningContainer => brightness == Brightness.dark
      ? const Color(0xFF3A2E12)
      : const Color(0xFFFFF4DA);
}
