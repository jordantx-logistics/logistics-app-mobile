import 'package:flutter/material.dart';

import 'brand.dart';

/// Hora local a partir de una fecha del servidor o de la cola.
String clockOf(DateTime at) {
  final local = at.toLocal();

  return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
}

/// Igual que [clockOf], si la fecha viene como texto y puede faltar.
String? clockOfText(Object? iso) {
  final at = iso is String ? DateTime.tryParse(iso) : null;

  return at == null ? null : clockOf(at);
}

/// `8 h 02`, o `45 min` si no llega a la hora.
String durationLabel(int minutes) {
  if (minutes < 60) {
    return '$minutes min';
  }

  return '${minutes ~/ 60} h ${(minutes % 60).toString().padLeft(2, '0')}';
}

/// Etiqueta de un campo: va encima, porque el campo relleno no tiene borde que la aloje.
class FieldLabel extends StatelessWidget {
  const FieldLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Palette.inkSoft),
    );
  }
}

/// Título pequeño de una sección de la pantalla.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: Palette.inkSoft),
    );
  }
}

/// Botón cuadrado de la cabecera, sobre el color de la app.
class HeaderButton extends StatelessWidget {
  const HeaderButton({super.key, required this.icon, required this.tooltip, required this.color, this.onPressed});

  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: color,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onPressed,
          child: SizedBox.square(dimension: 48, child: Icon(icon, color: Colors.white)),
        ),
      ),
    );
  }
}

/// Cabecera de las pantallas: el color de la app con el fondo redondeado.
class BrandHeader extends StatelessWidget {
  const BrandHeader({
    super.key,
    required this.brand,
    required this.title,
    this.subtitle,
    this.subtitleIsCode = false,
    this.logo = false,
    this.trailing,
    this.child,
  });

  final AppBrand brand;
  final String title;
  final String? subtitle;

  /// El subtítulo es una guía o una placa.
  final bool subtitleIsCode;

  /// En una pantalla principal va el logo; en las demás, el botón de volver.
  final bool logo;
  final Widget? trailing;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final subtitleStyle = subtitleIsCode
        ? codeStyle(16, color: Colors.white)
        : const TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: Colors.white);

    return Material(
      color: brand.primary,
      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(28)),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 14,
            children: [
              Row(
                spacing: 12,
                children: [
                  if (logo)
                    LogoMark(brand: brand)
                  else
                    HeaderButton(
                      icon: Icons.arrow_back,
                      tooltip: 'Volver',
                      color: brand.dark,
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            fontSize: 26,
                            height: 1.1,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                          ),
                        ),
                        if (subtitle != null) Text(subtitle!, style: subtitleStyle),
                      ],
                    ),
                  ),
                  ?trailing,
                ],
              ),
              ?child,
            ],
          ),
        ),
      ),
    );
  }
}

/// Cómo quedó algo: lo que más importa de una lista, y se lee por color e icono.
enum ItemState { ok, waiting, rejected, neutral }

/// Fila de lista: una tarjeta, con un bloque de color que dice su estado.
class ItemCard extends StatelessWidget {
  const ItemCard({
    super.key,
    required this.state,
    required this.title,
    this.subtitle,
    this.titleIsCode = false,
    this.leadingText,
    this.trailing,
    this.onTap,
    this.actions,
    this.brand,
  });

  final ItemState state;
  final String title;
  final String? subtitle;
  final bool titleIsCode;

  /// Sustituye al icono: el número de una parada, por ejemplo.
  final String? leadingText;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Widget? actions;

  /// Una fila sin estado propio usa el color suave de la app.
  final AppBrand? brand;

  @override
  Widget build(BuildContext context) {
    final (Color background, Color block, Color ink, IconData icon) = switch (state) {
      ItemState.ok => (Palette.okTint, Palette.ok, Palette.okInk, Icons.check),
      ItemState.waiting => (Palette.waitTint, Palette.wait, Palette.waitInk, Icons.schedule),
      ItemState.rejected => (Palette.badTint, Palette.bad, Palette.badInk, Icons.close),
      ItemState.neutral => (Palette.surface, brand?.tint ?? Palette.field, Palette.inkSoft, Icons.circle),
    };
    final blockInk = state == ItemState.neutral ? brand?.dark ?? Palette.ink : Colors.white;

    return Material(
      color: background,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: actions == null ? CrossAxisAlignment.center : CrossAxisAlignment.start,
            spacing: 12,
            children: [
              Container(
                width: 48,
                height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: block, borderRadius: BorderRadius.circular(13)),
                child: leadingText != null
                    ? Text(
                        leadingText!,
                        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: blockInk),
                      )
                    : Icon(icon, color: blockInk, size: 28),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: titleIsCode
                          ? codeStyle(19, color: Palette.ink)
                          : const TextStyle(fontSize: 19, height: 1.15, fontWeight: FontWeight.w700),
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        style: TextStyle(fontSize: 16, height: 1.25, fontWeight: FontWeight.w600, color: ink),
                      ),
                    if (actions != null) ...[const SizedBox(height: 10), actions!],
                  ],
                ),
              ),
              ?trailing,
            ],
          ),
        ),
      ),
    );
  }
}

/// Placa de un vehículo, como se ve en el camión.
class PlateTag extends StatelessWidget {
  const PlateTag(this.plate, {super.key, this.size = 22, this.background = Palette.field});

  final String plate;
  final double size;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(10)),
      child: Text(plate, style: codeStyle(size, color: Palette.ink)),
    );
  }
}

/// Lista vacía: dice qué es lo que falta y por qué.
class EmptyMessage extends StatelessWidget {
  const EmptyMessage({super.key, required this.icon, required this.title, this.detail});

  final IconData icon;
  final String title;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 8,
          children: [
            Icon(icon, size: 56, color: Palette.inkSoft),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
            if (detail != null)
              Text(
                detail!,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 17, color: Palette.inkSoft),
              ),
          ],
        ),
      ),
    );
  }
}

/// Pantalla de confirmación al terminar algo importante: que no quede duda de que quedó.
class DoneScreen extends StatelessWidget {
  const DoneScreen({super.key, required this.brand, required this.title, required this.message, required this.panel});

  final AppBrand brand;
  final String title;
  final Widget message;
  final Widget panel;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: brand.primary,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  spacing: 16,
                  children: [
                    Container(
                      width: 104,
                      height: 104,
                      decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                      child: Icon(Icons.check, size: 64, color: brand.primary),
                    ),
                    Text(
                      title,
                      style: const TextStyle(fontSize: 44, height: 1, fontWeight: FontWeight.w800, color: Colors.white),
                    ),
                    DefaultTextStyle.merge(
                      style: const TextStyle(
                        fontSize: 21,
                        height: 1.25,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                      child: message,
                    ),
                  ],
                ),
              ),
            ),
          ),
          DecoratedBox(
            decoration: const BoxDecoration(
              color: Palette.surface,
              borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
            ),
            child: SafeArea(
              top: false,
              child: Padding(padding: const EdgeInsets.all(24), child: panel),
            ),
          ),
        ],
      ),
    );
  }
}

/// Botón secundario: relleno oscuro, nunca un contorno.
ButtonStyle darkButton() {
  return FilledButton.styleFrom(backgroundColor: Palette.ink, foregroundColor: Colors.white);
}

/// Botón terciario: relleno neutro, para lo que rara vez se usa.
ButtonStyle quietButton() {
  return FilledButton.styleFrom(backgroundColor: Palette.field, foregroundColor: Palette.ink);
}
