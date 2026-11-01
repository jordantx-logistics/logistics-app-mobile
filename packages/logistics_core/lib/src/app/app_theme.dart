import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'brand.dart';

/// Tema de cada app: su color y formas rellenas, sin contornos. Botones y campos
/// grandes: se usan de pie, con guantes, al sol o con poca luz.
ThemeData logisticsTheme(AppBrand brand) {
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(16));
  final buttonText = GoogleFonts.barlow(fontSize: 19, fontWeight: FontWeight.w700);
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: brand.primary,
      primary: brand.primary,
      onPrimary: Colors.white,
      surface: Palette.surface,
      error: Palette.bad,
    ),
    scaffoldBackgroundColor: Palette.ground,
  );

  return base.copyWith(
    textTheme: GoogleFonts.barlowTextTheme(base.textTheme).apply(bodyColor: Palette.ink, displayColor: Palette.ink),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Palette.field,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
      errorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
      errorMaxLines: 3,
      hintStyle: const TextStyle(color: Palette.inkSoft),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: brand.primary,
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(60),
        shape: shape,
        textStyle: buttonText,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: brand.dark, minimumSize: const Size(48, 48), textStyle: buttonText),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Palette.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Palette.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    ),
  );
}
