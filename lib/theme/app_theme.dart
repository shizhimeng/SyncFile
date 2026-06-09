import 'package:flutter/material.dart';

class AppTheme {
  // 色彩代号配置 (基于 HTML Tailwind 扩展)
  static const Color primary = Color(0xFF0058BC);
  static const Color primaryContainer = Color(0xFF0070EB);
  static const Color onPrimary = Color(0xFFFFFFFF);
  static const Color onPrimaryContainer = Color(0xFFFEFCFF);

  static const Color secondary = Color(0xFF006E28);
  static const Color secondaryContainer = Color(0xFF6FFB85);
  static const Color onSecondary = Color(0xFFFFFFFF);
  static const Color onSecondaryContainer = Color(0xFF00732A);

  static const Color background = Color(0xFFFCF8FB);
  static const Color surface = Color(0xFFFCF8FB);
  static const Color onSurface = Color(0xFF1B1B1D);
  static const Color onBackground = Color(0xFF1B1B1D);

  static const Color surfaceVariant = Color(0xFFE4E2E4);
  static const Color onSurfaceVariant = Color(0xFF414755);

  static const Color surfaceContainerLowest = Color(0xFFFFFFFF);
  static const Color surfaceContainerLow = Color(0xFFF6F3F5);
  static const Color surfaceContainer = Color(0xFFF0EDEF);
  static const Color surfaceContainerHigh = Color(0xFFEAE7EA);
  static const Color surfaceContainerHighest = Color(0xFFE4E2E4);

  static const Color outline = Color(0xFF717786);
  static const Color outlineVariant = Color(0xFFC1C6D7);

  static const Color error = Color(0xFFBA1A1A);
  static const Color errorContainer = Color(0xFFFFDAD6);
  static const Color onError = Color(0xFFFFFFFF);
  static const Color onErrorContainer = Color(0xFF93000A);

  // 渐变色配置
  static const Gradient primaryGradient = LinearGradient(
    colors: [primaryContainer, primary],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const Gradient voiceGradient = LinearGradient(
    colors: [primaryContainer, primary],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  // 获取 ThemeData 配置
  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      colorScheme: const ColorScheme(
        brightness: Brightness.light,
        primary: primary,
        onPrimary: onPrimary,
        primaryContainer: primaryContainer,
        onPrimaryContainer: onPrimaryContainer,
        secondary: secondary,
        onSecondary: onSecondary,
        secondaryContainer: secondaryContainer,
        onSecondaryContainer: onSecondaryContainer,
        error: error,
        onError: onError,
        errorContainer: errorContainer,
        onErrorContainer: onErrorContainer,
        surface: surface,
        onSurface: onSurface,
        onSurfaceVariant: onSurfaceVariant,
        outline: outline,
        outlineVariant: outlineVariant,
      ),
      scaffoldBackgroundColor: background,
      fontFamily: 'Inter',
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0x33C1C6D7), width: 1),
        ),
      ),
      textTheme: const TextTheme(
        displayLarge: TextStyle(
          fontSize: 48,
          fontWeight: FontWeight.bold,
          letterSpacing: -0.02,
          color: onSurface,
        ),
        headlineLarge: TextStyle(
          fontSize: 32,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.01,
          color: onSurface,
        ),
        titleMedium: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: onSurface,
        ),
        bodyLarge: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.normal,
          color: onSurface,
        ),
        bodySmall: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.normal,
          color: onSurfaceVariant,
        ),
        labelLarge: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.05,
          color: primary,
        ),
      ),
    );
  }

  // 极富品质感的毛玻璃与卡片阴影装饰
  static BoxDecoration glassCardDecoration({
    Color color = Colors.white,
    double opacity = 0.7,
    double radius = 16,
  }) {
    return BoxDecoration(
      color: color.withOpacity(opacity),
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: const Color(0x55E5E5EA), width: 1),
      boxShadow: const [
        BoxShadow(
          color: Color(0x08000000),
          blurRadius: 12,
          offset: Offset(0, 4),
        )
      ],
    );
  }
}
