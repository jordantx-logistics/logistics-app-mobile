import 'package:flutter/material.dart';

/// Tema común. Botones y campos grandes: se usan de pie, con guantes o al sol.
ThemeData logisticsTheme() {
  return ThemeData(
    colorSchemeSeed: const Color(0xFF4F46E5),
    useMaterial3: true,
    inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
    filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52))),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
    ),
  );
}
