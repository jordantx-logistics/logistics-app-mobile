import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Colores que no dependen de la app: el estado se lee igual en las cuatro.
abstract final class Palette {
  static const ground = Color(0xFFF2F3F5);
  static const surface = Colors.white;
  static const ink = Color(0xFF14181F);
  static const inkSoft = Color(0xFF3D444E);
  static const field = Color(0xFFE4E7EB);

  static const ok = Color(0xFF15803D);
  static const okInk = Color(0xFF14532D);
  static const okTint = Color(0xFFDDF3E4);

  static const wait = Color(0xFF92580A);
  static const waitInk = Color(0xFF6B3F05);
  static const waitTint = Color(0xFFFBEFD5);

  static const bad = Color(0xFFB91C1C);
  static const badInk = Color(0xFF7F1D1D);
  static const badTint = Color(0xFFFBE3E3);
}

/// Dibujo del logo de cada app, en una caja de 64×64.
enum LogoGlyph { box, truck, pin, clock }

/// Identidad de una app: color, logo y lo que se le dice a quien la abre.
class AppBrand {
  const AppBrand({
    required this.name,
    required this.tagline,
    required this.primary,
    required this.dark,
    required this.tint,
    required this.glyph,
  });

  final String name;
  final String tagline;
  final Color primary;

  /// Sobre el color de la app: botones de la cabecera y barras.
  final Color dark;

  /// Fondo suave para lo que es de la app pero no es una acción.
  final Color tint;
  final LogoGlyph glyph;

  static const almacen = AppBrand(
    name: 'Almacén',
    tagline: 'Recibe, embarca e inventaría paquetes.',
    primary: Color(0xFFC2410C),
    dark: Color(0xFF9A3412),
    tint: Color(0xFFFCE9DF),
    glyph: LogoGlyph.box,
  );

  static const flota = AppBrand(
    name: 'Flota',
    tagline: 'Tu ruta, tus tramos y tus gastos de viaje.',
    primary: Color(0xFF1D4ED8),
    dark: Color(0xFF1E3A8A),
    tint: Color(0xFFE3EBFD),
    glyph: LogoGlyph.truck,
  );

  static const reparto = AppBrand(
    name: 'Reparto',
    tagline: 'Tu hoja de ruta y cada entrega firmada.',
    primary: Color(0xFFA21CAF),
    dark: Color(0xFF701A75),
    tint: Color(0xFFF9E6FB),
    glyph: LogoGlyph.pin,
  );

  static const personal = AppBrand(
    name: 'Personal',
    tagline: 'Marca tu jornada en un toque.',
    primary: Color(0xFF0F766E),
    dark: Color(0xFF115E59),
    tint: Color(0xFFD9F2EF),
    glyph: LogoGlyph.clock,
  );
}

/// Guías y placas: la O y el 0 no se confunden.
TextStyle codeStyle(double size, {Color? color, FontWeight weight = FontWeight.w700}) {
  return GoogleFonts.jetBrainsMono(fontSize: size, fontWeight: weight, color: color);
}

/// Logo de la app. [onBrand] lo dibuja blanco para ponerlo sobre el color de la app.
class LogoMark extends StatelessWidget {
  const LogoMark({super.key, required this.brand, this.size = 48, this.onBrand = true});

  final AppBrand brand;
  final double size;
  final bool onBrand;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Logo de ${brand.name}',
      image: true,
      child: CustomPaint(
        size: Size.square(size),
        painter: _LogoPainter(
          glyph: brand.glyph,
          tile: onBrand ? Colors.white : brand.primary,
          ink: onBrand ? brand.primary : Colors.white,
        ),
      ),
    );
  }
}

class _LogoPainter extends CustomPainter {
  const _LogoPainter({required this.glyph, required this.tile, required this.ink});

  final LogoGlyph glyph;
  final Color tile;
  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 64);

    // La esquina cortada es lo que comparte la familia: recuerda a una etiqueta de envío.
    final label = Path()
      ..moveTo(14, 0)
      ..lineTo(46, 0)
      ..lineTo(64, 18)
      ..lineTo(64, 50)
      ..arcToPoint(const Offset(50, 64), radius: const Radius.circular(14))
      ..lineTo(14, 64)
      ..arcToPoint(const Offset(0, 50), radius: const Radius.circular(14))
      ..lineTo(0, 14)
      ..arcToPoint(const Offset(14, 0), radius: const Radius.circular(14))
      ..close();

    canvas.drawPath(label, Paint()..color = tile);

    final stroke = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;

    switch (glyph) {
      case LogoGlyph.box:
        canvas.drawPath(
          Path()
            ..moveTo(15, 26)
            ..lineTo(32, 17)
            ..lineTo(49, 26)
            ..lineTo(49, 45)
            ..lineTo(32, 54)
            ..lineTo(15, 45)
            ..close()
            ..moveTo(15, 26)
            ..lineTo(32, 35)
            ..lineTo(49, 26)
            ..moveTo(32, 35)
            ..lineTo(32, 54),
          stroke,
        );
      case LogoGlyph.truck:
        canvas.drawPath(
          Path()
            ..addRect(const Rect.fromLTWH(10, 22, 25, 22))
            ..moveTo(35, 30)
            ..lineTo(44, 30)
            ..lineTo(52, 38)
            ..lineTo(52, 44)
            ..lineTo(35, 44),
          stroke,
        );

        for (final center in const [Offset(20, 46), Offset(43, 46)]) {
          canvas.drawCircle(center, 4.5, Paint()..color = tile);
          canvas.drawCircle(center, 4.5, stroke);
        }
      case LogoGlyph.pin:
        canvas.drawPath(
          Path()
            ..moveTo(32, 12)
            ..arcToPoint(const Offset(46, 26), radius: const Radius.circular(14))
            ..cubicTo(46, 37, 32, 52, 32, 52)
            ..cubicTo(32, 52, 18, 37, 18, 26)
            ..arcToPoint(const Offset(32, 12), radius: const Radius.circular(14))
            ..close(),
          stroke,
        );
        canvas.drawCircle(const Offset(32, 26), 5, stroke);
      case LogoGlyph.clock:
        canvas.drawCircle(const Offset(32, 33), 18, stroke);
        canvas.drawPath(
          Path()
            ..moveTo(32, 22)
            ..lineTo(32, 33)
            ..lineTo(40, 38),
          stroke,
        );
    }
  }

  @override
  bool shouldRepaint(_LogoPainter oldDelegate) => glyph != oldDelegate.glyph || tile != oldDelegate.tile;
}
