import 'package:flutter/material.dart';

/// Global notifier that drives the app's theme mode.
/// Updated by [SettingsScreen] and persisted via SharedPreferences
/// under the key 'themeMode'.
final themeNotifier = ValueNotifier<ThemeMode>(ThemeMode.system);

const _kAccent = Color(0xFFFF8800);

ThemeData buildLightTheme() => ThemeData(
  brightness: Brightness.light,
  scaffoldBackgroundColor: const Color(0xFFF2F2F7),
  colorScheme: const ColorScheme.light(
    primary: _kAccent,
    secondary: _kAccent,
    surface: Colors.white,
    onSurface: Colors.black87,
  ),
  appBarTheme: const AppBarTheme(
    backgroundColor: Color(0xFFF2F2F7),
    foregroundColor: Colors.black87,
    elevation: 0,
    surfaceTintColor: Colors.transparent,
    titleTextStyle: TextStyle(
      color: Colors.black87,
      fontSize: 26,
      fontWeight: FontWeight.bold,
    ),
    iconTheme: IconThemeData(color: Colors.black87),
  ),
  listTileTheme: ListTileThemeData(
    iconColor: Colors.grey.shade700,
    titleTextStyle: const TextStyle(color: Colors.black87, fontSize: 16),
    subtitleTextStyle: TextStyle(color: Colors.grey.shade600, fontSize: 14),
  ),
  dividerColor: Colors.black12,
  textTheme: const TextTheme(
    titleLarge: TextStyle(color: Colors.black87, fontWeight: FontWeight.bold),
    bodyMedium: TextStyle(color: Colors.black87),
    bodySmall: TextStyle(color: Colors.black54),
    labelSmall: TextStyle(
      color: Colors.black54,
      fontWeight: FontWeight.bold,
      fontSize: 12,
    ),
  ),
  switchTheme: SwitchThemeData(
    thumbColor: WidgetStateProperty.resolveWith(
      (s) => s.contains(WidgetState.selected) ? _kAccent : null,
    ),
    trackColor: WidgetStateProperty.resolveWith(
      (s) => s.contains(WidgetState.selected)
          ? _kAccent.withValues(alpha: 0.4)
          : null,
    ),
  ),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: Colors.grey.shade200,
    enabledBorder: OutlineInputBorder(
      borderSide: const BorderSide(color: Colors.black12),
      borderRadius: BorderRadius.circular(10),
    ),
    focusedBorder: OutlineInputBorder(
      borderSide: const BorderSide(color: _kAccent),
      borderRadius: BorderRadius.circular(10),
    ),
    labelStyle: const TextStyle(color: Colors.black54),
    hintStyle: const TextStyle(color: Colors.black38),
  ),
  tabBarTheme: TabBarThemeData(
    labelColor: Colors.black87,
    unselectedLabelColor: Colors.black45,
    indicatorColor: _kAccent,
  ),
);

ThemeData buildDarkTheme() => ThemeData(
  brightness: Brightness.dark,
  scaffoldBackgroundColor: Colors.black,
  colorScheme: const ColorScheme.dark(
    primary: _kAccent,
    secondary: _kAccent,
    surface: Color(0xFF1C1C1E),
    onSurface: Colors.white,
  ),
  appBarTheme: const AppBarTheme(
    backgroundColor: Colors.black,
    foregroundColor: Colors.white,
    elevation: 0,
    surfaceTintColor: Colors.transparent,
    titleTextStyle: TextStyle(
      color: Colors.white,
      fontSize: 26,
      fontWeight: FontWeight.bold,
    ),
    iconTheme: IconThemeData(color: Colors.white),
  ),
  listTileTheme: const ListTileThemeData(
    iconColor: Colors.white70,
    titleTextStyle: TextStyle(color: Colors.white, fontSize: 16),
    subtitleTextStyle: TextStyle(color: Colors.grey, fontSize: 14),
  ),
  dividerColor: Colors.white10,
  textTheme: const TextTheme(
    titleLarge: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
    bodyMedium: TextStyle(color: Colors.white),
    bodySmall: TextStyle(color: Colors.grey),
    labelSmall: TextStyle(
      color: Colors.grey,
      fontWeight: FontWeight.bold,
      fontSize: 12,
    ),
  ),
  switchTheme: SwitchThemeData(
    thumbColor: WidgetStateProperty.resolveWith(
      (s) => s.contains(WidgetState.selected) ? _kAccent : null,
    ),
    trackColor: WidgetStateProperty.resolveWith(
      (s) => s.contains(WidgetState.selected)
          ? _kAccent.withValues(alpha: 0.4)
          : null,
    ),
  ),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: Colors.white10,
    enabledBorder: OutlineInputBorder(
      borderSide: const BorderSide(color: Colors.white24),
      borderRadius: BorderRadius.circular(10),
    ),
    focusedBorder: OutlineInputBorder(
      borderSide: const BorderSide(color: _kAccent),
      borderRadius: BorderRadius.circular(10),
    ),
    labelStyle: const TextStyle(color: Colors.white70),
    hintStyle: const TextStyle(color: Colors.white30),
  ),
  tabBarTheme: const TabBarThemeData(
    labelColor: Colors.white,
    unselectedLabelColor: Colors.white60,
    indicatorColor: Colors.white,
  ),
);
