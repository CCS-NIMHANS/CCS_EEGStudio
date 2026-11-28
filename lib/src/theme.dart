import 'dart:io';

import 'package:flutter/material.dart';

/// Design tokens and ThemeData matching CCS Sleep Studio's clean light clinical theme.
class CcsTheme {
  static const Color bg = Color(0xFFF8F9FB);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color panel = Color(0xFFF0F4F8);
  static const Color panelAlt = Color(0xFFE2E8F0);
  static const Color border = Color(0xFFCBD5E1);
  static const Color borderSubtle = Color(0xFFE2E8F0);

  static const Color text = Color(0xFF1E293B);
  static const Color textSecondary = Color(0xFF475569);
  static const Color textMuted = Color(0xFF64748B);

  static const Color accentBlue = Color(0xFF3B6EA5);
  static const Color accentBrightBlue = Color(0xFF1E88E5);
  static const Color accentGreen = Color(0xFF16A34A);
  static const Color accentAmber = Color(0xFFD97706);
  static const Color accentPurple = Color(0xFF6D28D9);
  static const Color accentPink = Color(0xFFDB2777);
  static const Color accentCyan = Color(0xFF0284C7);
  static const Color accentRed = Color(0xFFDC2626);
}

ThemeData buildCcsLightTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: CcsTheme.accentBlue,
    brightness: Brightness.light,
    surface: CcsTheme.surface,
  );
  return ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: CcsTheme.bg,
    cardColor: CcsTheme.surface,
    canvasColor: CcsTheme.surface,
    dialogTheme: DialogThemeData(
      backgroundColor: CcsTheme.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: CcsTheme.border),
      ),
    ),
    cardTheme: CardThemeData(
      color: CcsTheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: CcsTheme.borderSubtle),
      ),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: CcsTheme.panel,
      foregroundColor: CcsTheme.text,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
    ),
    dividerTheme: const DividerThemeData(
      color: CcsTheme.border,
      thickness: 1,
    ),
    useMaterial3: true,
    fontFamily: Platform.isMacOS ? '.AppleSystemUIFont' : null,
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(
        borderSide: const BorderSide(color: CcsTheme.border),
        borderRadius: BorderRadius.circular(6),
      ),
      enabledBorder: OutlineInputBorder(
        borderSide: const BorderSide(color: CcsTheme.border),
        borderRadius: BorderRadius.circular(6),
      ),
      focusedBorder: OutlineInputBorder(
        borderSide: const BorderSide(color: CcsTheme.accentBlue, width: 1.5),
        borderRadius: BorderRadius.circular(6),
      ),
      labelStyle: const TextStyle(color: CcsTheme.textMuted),
      hintStyle: const TextStyle(color: CcsTheme.textMuted),
      isDense: true,
      filled: true,
      fillColor: CcsTheme.surface,
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected)
            ? CcsTheme.accentBlue
            : Colors.transparent,
      ),
      side: const BorderSide(color: CcsTheme.textMuted, width: 1.5),
      checkColor: WidgetStateProperty.all(Colors.white),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: CcsTheme.panel,
      selectedColor: CcsTheme.accentBlue.withValues(alpha: 0.14),
      side: const BorderSide(color: CcsTheme.border),
      labelStyle: const TextStyle(color: CcsTheme.text, fontSize: 12),
      secondaryLabelStyle: const TextStyle(color: CcsTheme.text, fontSize: 12),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? Colors.white
              : CcsTheme.text,
        ),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? CcsTheme.accentBlue
              : CcsTheme.surface,
        ),
        side: WidgetStateProperty.all(
          const BorderSide(color: CcsTheme.border),
        ),
      ),
    ),
    expansionTileTheme: const ExpansionTileThemeData(
      textColor: CcsTheme.text,
      collapsedTextColor: CcsTheme.text,
      iconColor: CcsTheme.textSecondary,
      collapsedIconColor: CcsTheme.textSecondary,
    ),
    dataTableTheme: const DataTableThemeData(
      headingTextStyle: TextStyle(
        color: CcsTheme.text,
        fontWeight: FontWeight.w600,
        fontSize: 12,
      ),
      dataTextStyle: TextStyle(
        color: CcsTheme.text,
        fontSize: 12,
      ),
    ),
    popupMenuTheme: const PopupMenuThemeData(
      color: CcsTheme.surface,
      surfaceTintColor: Colors.transparent,
    ),
  );
}
