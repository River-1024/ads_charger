import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_tokens.dart';

/// 应用主题：深浅两套色板共享 `app_tokens.dart` 的同一套刻度，
/// 由 `ThemeMode.system` 跟随系统切换。
///
/// 浅色与深色不是简单的明暗翻转：浅色用「冷灰画布 + 纯白卡片」表达层级，
/// 深色用「近黑画布 + 略亮卡片」，两者在各自的亮度区间里都保持足够的
/// 卡片/背景对比度，避免深色下卡片糊成一片。
abstract final class AppTheme {
  const AppTheme._();

  /// 品牌主色。沿用改造前的深青绿，保留品牌连续性。
  static const Color brand = Color(0xFF00695C);

  /// 浅色主题。
  static ThemeData light() => _build(_lightScheme);

  /// 深色主题。
  static ThemeData dark() => _build(_darkScheme);

  static ColorScheme _lightScheme() => ColorScheme.fromSeed(
    seedColor: brand,
    brightness: Brightness.light,
  ).copyWith(
    primary: const Color(0xFF00695C),
    onPrimary: Colors.white,
    primaryContainer: const Color(0xFFC7EDE3),
    onPrimaryContainer: const Color(0xFF00201A),
    secondary: const Color(0xFF0E7C86),
    onSecondary: Colors.white,
    secondaryContainer: const Color(0xFFC4EBF1),
    onSecondaryContainer: const Color(0xFF002023),
    tertiary: const Color(0xFF4A635F),
    surface: const Color(0xFFFFFFFF),
    onSurface: const Color(0xFF14181A),
    surfaceContainerLowest: const Color(0xFFF3F5F6),
    surfaceContainerLow: const Color(0xFFFAFBFB),
    surfaceContainer: const Color(0xFFF1F4F5),
    surfaceContainerHigh: const Color(0xFFEAEEEF),
    surfaceContainerHighest: const Color(0xFFE3E8E9),
    onSurfaceVariant: const Color(0xFF5A6366),
    outline: const Color(0xFF8A9497),
    outlineVariant: const Color(0xFFDDE3E5),
    error: const Color(0xFFB3261E),
    onError: Colors.white,
    errorContainer: const Color(0xFFF9DEDC),
    onErrorContainer: const Color(0xFF410E0B),
  );

  static ColorScheme _darkScheme() => ColorScheme.fromSeed(
    seedColor: brand,
    brightness: Brightness.dark,
  ).copyWith(
    primary: const Color(0xFF5FE3C0),
    onPrimary: const Color(0xFF00382E),
    primaryContainer: const Color(0xFF005143),
    onPrimaryContainer: const Color(0xFF7CFFE1),
    secondary: const Color(0xFF6BC9DC),
    onSecondary: const Color(0xFF00363D),
    secondaryContainer: const Color(0xFF004E58),
    onSecondaryContainer: const Color(0xFFBCEBFA),
    tertiary: const Color(0xFFB1CCC7),
    surface: const Color(0xFF171B1E),
    onSurface: const Color(0xFFE4E8EA),
    surfaceContainerLowest: const Color(0xFF0E1113),
    surfaceContainerLow: const Color(0xFF131719),
    surfaceContainer: const Color(0xFF171B1E),
    surfaceContainerHigh: const Color(0xFF1F2428),
    surfaceContainerHighest: const Color(0xFF2A3034),
    onSurfaceVariant: const Color(0xFF9BA5A9),
    outline: const Color(0xFF6E787C),
    outlineVariant: const Color(0xFF2C3337),
    error: const Color(0xFFFFB4AB),
    onError: const Color(0xFF690005),
    errorContainer: const Color(0xFF93000A),
    onErrorContainer: const Color(0xFFFFDAD6),
  );

  static ThemeData _build(ColorScheme Function() buildScheme) {
    final colors = buildScheme();

    // Typography.material2021 会按传入的 colorScheme 自动把字色调到
    // onSurface（浅色为深字、深色为浅字），因此深浅两套字阶只需各自
    // 覆盖一次尺寸与字重。
    //
    // platform 必须显式传：material2021 的默认平台是 Android，iOS 上会
    // 因此去请求系统并不存在的 Roboto，退化成系统字体后又丢掉平台自己的
    // 字族与字重。跟随目标平台才能让两端各自用上原生的字体栈。
    final typography = Typography.material2021(
      platform: defaultTargetPlatform,
      colorScheme: colors,
    );
    final base = colors.brightness == Brightness.light
        ? typography.black
        : typography.white;
    final textTheme = base.copyWith(
      displayLarge: base.displayLarge?.copyWith(
        fontSize: 44,
        fontWeight: FontWeight.w600,
        letterSpacing: -1.2,
        height: 1.06,
      ),
      displayMedium: base.displayMedium?.copyWith(
        fontSize: 32,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.8,
        height: 1.1,
      ),
      headlineMedium: base.headlineMedium?.copyWith(
        fontSize: 26,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.4,
      ),
      headlineSmall: base.headlineSmall?.copyWith(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
      ),
      titleLarge: base.titleLarge?.copyWith(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.1,
      ),
      titleMedium: base.titleMedium?.copyWith(fontSize: 15, fontWeight: FontWeight.w600),
      titleSmall: base.titleSmall?.copyWith(fontSize: 13.5, fontWeight: FontWeight.w600),
      bodyLarge: base.bodyLarge?.copyWith(fontSize: 15, height: 1.5),
      bodyMedium: base.bodyMedium?.copyWith(fontSize: 14, height: 1.5),
      bodySmall: base.bodySmall?.copyWith(fontSize: 12.5, height: 1.45),
      labelLarge: base.labelLarge?.copyWith(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.1,
      ),
      labelMedium: base.labelMedium?.copyWith(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.2,
      ),
      labelSmall: base.labelSmall?.copyWith(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.3,
      ),
    );

    final hairline = colors.outlineVariant;
    final controlRadius = BorderRadius.circular(AppRadius.md);
    final hairlineBorder = BorderSide(color: hairline);

    return ThemeData(
      useMaterial3: true,
      colorScheme: colors,
      textTheme: textTheme,
      scaffoldBackgroundColor: colors.surfaceContainerLowest,
      splashFactory: InkSparkle.splashFactory,

      appBarTheme: AppBarTheme(
        backgroundColor: colors.surface,
        foregroundColor: colors.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: textTheme.titleLarge,
        iconTheme: IconThemeData(color: colors.onSurfaceVariant),
      ),

      // 卡片用 1px 描边而不是 Material 默认阴影：浅色下阴影几乎不可见却
      // 带来脏边，深色下又会糊成一片，描边在两种亮度下都能稳定表达层级。
      cardTheme: CardThemeData(
        color: colors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          side: hairlineBorder,
        ),
      ),

      dividerTheme: DividerThemeData(color: hairline, thickness: 1, space: 1),

      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: colors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        height: 68,
        indicatorColor: colors.primaryContainer,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            size: 22,
            color: selected ? colors.onPrimaryContainer : colors.onSurfaceVariant,
          );
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return textTheme.labelMedium?.copyWith(
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? colors.onSurface : colors.onSurfaceVariant,
          );
        }),
      ),

      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll<Size>(Size(0, 48)),
          padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
            EdgeInsets.symmetric(horizontal: AppSpacing.xl),
          ),
          shape: WidgetStatePropertyAll<OutlinedBorder>(
            RoundedRectangleBorder(borderRadius: controlRadius),
          ),
          textStyle: WidgetStatePropertyAll<TextStyle?>(textTheme.labelLarge),
          // Material's disabled fill is a 12% scrim that almost vanishes on a
          // light canvas, so an unavailable control reads as "missing" rather
          // than "not yet". Resolving both states explicitly keeps the label
          // legible and makes every disabled action look the same.
          backgroundColor: WidgetStateProperty.resolveWith<Color?>((states) {
            if (states.contains(WidgetState.disabled)) {
              return colors.surfaceContainerHighest;
            }
            return colors.primary;
          }),
          foregroundColor: WidgetStateProperty.resolveWith<Color?>((states) {
            if (states.contains(WidgetState.disabled)) {
              return colors.onSurfaceVariant;
            }
            return colors.onPrimary;
          }),
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll<Size>(Size(0, 48)),
          padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
            EdgeInsets.symmetric(horizontal: AppSpacing.xl),
          ),
          shape: WidgetStatePropertyAll<OutlinedBorder>(
            RoundedRectangleBorder(
              borderRadius: controlRadius,
              side: hairlineBorder,
            ),
          ),
          textStyle: WidgetStatePropertyAll<TextStyle?>(textTheme.labelLarge),
          foregroundColor: WidgetStateProperty.resolveWith<Color?>((states) {
            if (states.contains(WidgetState.disabled)) {
              return colors.onSurfaceVariant;
            }
            return colors.onSurface;
          }),
          side: WidgetStateProperty.resolveWith<BorderSide?>((states) {
            if (states.contains(WidgetState.disabled)) {
              return BorderSide(color: colors.outlineVariant);
            }
            return hairlineBorder;
          }),
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll<OutlinedBorder>(
            RoundedRectangleBorder(borderRadius: controlRadius),
          ),
          textStyle: WidgetStatePropertyAll<TextStyle?>(textTheme.labelLarge),
        ),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colors.surfaceContainerHigh,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.md,
        ),
        border: OutlineInputBorder(
          borderRadius: controlRadius,
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: controlRadius,
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: controlRadius,
          borderSide: BorderSide(color: colors.primary, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: controlRadius,
          borderSide: BorderSide(color: colors.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: controlRadius,
          borderSide: BorderSide(color: colors.error, width: 1.5),
        ),
        labelStyle: textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
        hintStyle: textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
      ),

      chipTheme: ChipThemeData(
        backgroundColor: colors.surface,
        selectedColor: colors.primaryContainer,
        side: hairlineBorder,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        labelStyle: textTheme.labelMedium,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.xs,
        ),
      ),

      listTileTheme: ListTileThemeData(
        titleTextStyle: textTheme.titleSmall,
        subtitleTextStyle: textTheme.bodySmall?.copyWith(
          color: colors.onSurfaceVariant,
        ),
        iconColor: colors.onSurfaceVariant,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.xs,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: colors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        titleTextStyle: textTheme.headlineSmall,
        contentTextStyle: textTheme.bodyMedium,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.xl),
        ),
      ),

      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: colors.inverseSurface,
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: colors.onInverseSurface,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        insetPadding: const EdgeInsets.all(AppSpacing.lg),
      ),

      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll<OutlinedBorder>(
            RoundedRectangleBorder(borderRadius: controlRadius),
          ),
          side: WidgetStatePropertyAll<BorderSide>(hairlineBorder),
          textStyle: WidgetStatePropertyAll<TextStyle?>(textTheme.labelLarge),
        ),
      ),

      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: colors.primary,
        linearTrackColor: colors.surfaceContainerHighest,
      ),
    );
  }
}
