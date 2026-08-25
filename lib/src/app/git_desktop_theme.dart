import 'package:flutter/material.dart';

/// 中文：创建与桌面 Git 工作台信息密度相匹配的应用主题。
/// 输入亮度并返回无外部 UI 依赖的不可变 [ThemeData]；调用方在每次
/// [MaterialApp] 重建时读取它，不持有窗口或异步资源。
///
/// English: Creates the application theme with the density and visual
/// hierarchy of a desktop Git workbench. It returns immutable [ThemeData] for
/// the requested brightness and owns no window or asynchronous resources.
ThemeData buildGitDesktopTheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  final colors = _colorScheme(brightness);
  final textTheme = _textTheme(colors);
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: colors,
    scaffoldBackgroundColor: colors.surface,
    textTheme: textTheme,
    dividerTheme: DividerThemeData(
      color: colors.outlineVariant,
      space: 1,
      thickness: 1,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: colors.surfaceContainerHigh,
      foregroundColor: colors.onSurface,
      toolbarHeight: 38,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: textTheme.titleSmall?.copyWith(
        fontWeight: FontWeight.w600,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: isDark
          ? colors.surfaceContainerLowest
          : colors.surfaceContainerLow,
      contentPadding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
      hintStyle: textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
      border: _inputBorder(colors.outlineVariant),
      enabledBorder: _inputBorder(colors.outlineVariant),
      focusedBorder: _inputBorder(colors.primary, width: 1.5),
      errorBorder: _inputBorder(colors.error),
      focusedErrorBorder: _inputBorder(colors.error, width: 1.5),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: colors.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(3),
        side: BorderSide(color: colors.outlineVariant),
      ),
      textStyle: textTheme.bodySmall,
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(colors.surfaceContainerHigh),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(3),
            side: BorderSide(color: colors.outlineVariant),
          ),
        ),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF15191B) : const Color(0xFF2C3438),
        borderRadius: BorderRadius.circular(3),
      ),
      textStyle: textTheme.labelSmall?.copyWith(color: Colors.white),
      waitDuration: const Duration(milliseconds: 450),
    ),
    iconTheme: IconThemeData(color: colors.onSurfaceVariant, size: 18),
    listTileTheme: ListTileThemeData(
      dense: true,
      minVerticalPadding: 2,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10),
      iconColor: colors.onSurfaceVariant,
      textColor: colors.onSurface,
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 30),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        foregroundColor: colors.primary,
        textStyle: textTheme.labelMedium,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3)),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 30),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        backgroundColor: colors.primary,
        foregroundColor: colors.onPrimary,
        textStyle: textTheme.labelMedium,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 30),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        foregroundColor: colors.onSurface,
        side: BorderSide(color: colors.outline),
        textStyle: textTheme.labelMedium,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: isDark
          ? colors.surfaceContainerHighest
          : const Color(0xFF2D363B),
      contentTextStyle: textTheme.bodySmall?.copyWith(color: Colors.white),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3)),
      behavior: SnackBarBehavior.floating,
    ),
  );
}

/// 中文：返回指定亮度下的应用语义颜色 token。
/// 不读取窗口状态，结果仅由 [brightness] 决定。
///
/// English: Returns semantic application color tokens for [brightness]. The
/// result depends only on the requested brightness and reads no window state.
ColorScheme _colorScheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  return ColorScheme.fromSeed(
    seedColor: const Color(0xFF147DC2),
    brightness: brightness,
  ).copyWith(
    primary: isDark ? const Color(0xFF1688D4) : const Color(0xFF0D70B5),
    onPrimary: Colors.white,
    primaryContainer: isDark
        ? const Color(0xFF104F7B)
        : const Color(0xFFD8EBF8),
    onPrimaryContainer: isDark
        ? const Color(0xFFD9EEFF)
        : const Color(0xFF063B60),
    secondary: isDark ? const Color(0xFFAEB9BE) : const Color(0xFF536168),
    secondaryContainer: isDark
        ? const Color(0xFF35464E)
        : const Color(0xFFDCE5E9),
    onSecondaryContainer: isDark
        ? const Color(0xFFDCE8ED)
        : const Color(0xFF263238),
    tertiary: isDark ? const Color(0xFFFFB86A) : const Color(0xFFAF500F),
    tertiaryContainer: isDark
        ? const Color(0xFF613900)
        : const Color(0xFFFFDCBD),
    error: isDark ? const Color(0xFFFFB4AB) : const Color(0xFFBA1A1A),
    onError: isDark ? const Color(0xFF690005) : Colors.white,
    errorContainer: isDark ? const Color(0xFF93000A) : const Color(0xFFFFDAD6),
    onErrorContainer: isDark
        ? const Color(0xFFFFDAD6)
        : const Color(0xFF410002),
    surface: isDark ? const Color(0xFF202528) : const Color(0xFFF5F6F7),
    onSurface: isDark ? const Color(0xFFE9EDF0) : const Color(0xFF202629),
    surfaceContainerLowest: isDark
        ? const Color(0xFF171B1D)
        : const Color(0xFFFFFFFF),
    surfaceContainerLow: isDark
        ? const Color(0xFF252B2E)
        : const Color(0xFFEEF0F1),
    surfaceContainer: isDark
        ? const Color(0xFF2B3235)
        : const Color(0xFFE7EAEC),
    surfaceContainerHigh: isDark
        ? const Color(0xFF343C40)
        : const Color(0xFFDDE2E5),
    surfaceContainerHighest: isDark
        ? const Color(0xFF424B50)
        : const Color(0xFFCED5D9),
    onSurfaceVariant: isDark
        ? const Color(0xFFB5BEC3)
        : const Color(0xFF58656C),
    outline: isDark ? const Color(0xFF6E7B82) : const Color(0xFF8E989D),
    outlineVariant: isDark ? const Color(0xFF424C51) : const Color(0xFFCBD1D4),
    shadow: Colors.black,
    scrim: Colors.black,
  );
}

/// 中文：建立紧凑的系统字体层级，并应用指定前景色。
///
/// English: Builds the compact system typography hierarchy and applies the
/// supplied foreground colors.
TextTheme _textTheme(ColorScheme colors) => TextTheme(
  displayLarge: const TextStyle(fontSize: 26, height: 1.15),
  displayMedium: const TextStyle(fontSize: 22, height: 1.18),
  displaySmall: const TextStyle(fontSize: 20, height: 1.2),
  headlineLarge: const TextStyle(
    fontSize: 18,
    height: 1.22,
    fontWeight: FontWeight.w600,
  ),
  headlineMedium: const TextStyle(
    fontSize: 16,
    height: 1.25,
    fontWeight: FontWeight.w600,
  ),
  headlineSmall: const TextStyle(
    fontSize: 15,
    height: 1.28,
    fontWeight: FontWeight.w600,
  ),
  titleLarge: const TextStyle(
    fontSize: 16,
    height: 1.25,
    fontWeight: FontWeight.w600,
  ),
  titleMedium: const TextStyle(
    fontSize: 14,
    height: 1.3,
    fontWeight: FontWeight.w600,
  ),
  titleSmall: const TextStyle(
    fontSize: 13,
    height: 1.3,
    fontWeight: FontWeight.w600,
  ),
  bodyLarge: const TextStyle(fontSize: 14, height: 1.35),
  bodyMedium: const TextStyle(fontSize: 13, height: 1.35),
  bodySmall: const TextStyle(fontSize: 12, height: 1.3),
  labelLarge: const TextStyle(
    fontSize: 13,
    height: 1.2,
    fontWeight: FontWeight.w600,
  ),
  labelMedium: const TextStyle(
    fontSize: 12,
    height: 1.2,
    fontWeight: FontWeight.w600,
  ),
  labelSmall: const TextStyle(
    fontSize: 11,
    height: 1.18,
    fontWeight: FontWeight.w600,
  ),
).apply(bodyColor: colors.onSurface, displayColor: colors.onSurface);

/// 中文：创建工作台输入控件共用的低圆角边框。
///
/// English: Creates the shared low-radius border for workbench inputs.
OutlineInputBorder _inputBorder(Color color, {double width = 1}) =>
    OutlineInputBorder(
      borderRadius: BorderRadius.circular(3),
      borderSide: BorderSide(color: color, width: width),
    );
