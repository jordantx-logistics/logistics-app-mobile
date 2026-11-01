import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logistics_core/logistics_core.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'scans_channel.dart';

/// Lado del recuadro de lectura. Sirve igual para un QR que para un código de barras.
const _frameSize = 270.0;

String _scannedLabel(int count) => '$count ${count == 1 ? 'escaneado' : 'escaneados'}';

/// Lo que se ha escaneado en esta pantalla, compartido con el resumen.
class ScanEntry {
  const ScanEntry(this.code, this.opId);

  final String code;
  final String opId;
}

/// Escaneo continuo a pantalla completa. La cámara solo lee dentro del recuadro; un lector
/// integrado escribe como teclado y entra por el mismo camino, sin hacer nada más.
class ScanScreen extends StatefulWidget {
  const ScanScreen({
    super.key,
    required this.type,
    required this.agencyId,
    required this.context,
    this.embarkId,
    this.contextIsCode = false,
    this.cameraEnabled = true,
  });

  final ScanType type;
  final int agencyId;
  final int? embarkId;

  /// Sobre qué se escanea: la placa del manifiesto o la agencia.
  final String context;
  final bool contextIsCode;
  final bool cameraEnabled;

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _Flash {
  const _Flash({required this.ok, required this.title, required this.code, this.detail});

  final bool ok;
  final String title;
  final String code;
  final String? detail;
}

class _ScanScreenState extends State<ScanScreen> {
  final _focus = FocusNode();
  final _entries = <ScanEntry>[];
  final _codes = <String>{};
  final _keys = StringBuffer();

  MobileScannerController? _camera;
  Timer? _resume;
  _Flash? _flash;
  bool _torch = false;
  bool _covered = false;

  // La cámara sigue viendo la misma etiqueta tras leerla: no es un segundo escaneo.
  String? _lastCode;
  DateTime? _lastSeen;

  @override
  void initState() {
    super.initState();

    if (widget.cameraEnabled) {
      _camera = MobileScannerController(formats: const [BarcodeFormat.all], detectionSpeed: DetectionSpeed.normal);
    }
  }

  @override
  void dispose() {
    _resume?.cancel();
    _focus.dispose();
    unawaited(_camera?.dispose());
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    final value = capture.barcodes.firstOrNull?.rawValue;

    if (value == null || _covered || _flash != null) {
      return;
    }

    final now = DateTime.now();
    final same = value == _lastCode && _lastSeen != null && now.difference(_lastSeen!) < const Duration(seconds: 5);

    _lastCode = value;
    _lastSeen = now;

    if (!same) {
      unawaited(_onCode(value));
    }
  }

  /// El lector físico teclea muy rápido y termina con Enter.
  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent || _flash != null) {
      return KeyEventResult.ignored;
    }

    if (event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      final value = _keys.toString();

      _keys.clear();

      if (value.isNotEmpty) {
        unawaited(_onCode(value));
      }

      return KeyEventResult.handled;
    }

    final character = event.character;

    if (character == null || character.isEmpty) {
      return KeyEventResult.ignored;
    }

    _keys.write(character);

    return KeyEventResult.handled;
  }

  Future<void> _onCode(String raw) async {
    final services = AppScope.of(context);
    final code = normalizeTicketCode(raw);

    if (code == null) {
      return _show(
        _Flash(
          ok: false,
          title: 'Código no válido',
          code: raw.trim(),
          detail: 'No es una guía. Centra la etiqueta del paquete.',
        ),
      );
    }

    if (!_codes.add(code)) {
      return _show(_Flash(ok: false, title: 'Ya está escaneado', code: code, detail: 'Este paquete ya se leyó aquí.'));
    }

    final opId = await recordScan(
      ops: services.ops,
      type: widget.type,
      ticketCode: code,
      agencyId: widget.agencyId,
      embarkId: widget.embarkId,
    );

    _entries.insert(0, ScanEntry(code, opId));
    await _show(
      _Flash(
        ok: true,
        title: 'Guardado',
        code: code,
        detail: '${_scannedLabel(_entries.length)} · Listo para el siguiente',
      ),
    );

    unawaited(_checkOutcome(services, opId, code));
  }

  /// Con señal, el servidor responde enseguida y el rechazo se ve al momento. Sin señal,
  /// queda como pendiente y aparecerá en el resumen.
  Future<void> _checkOutcome(AppServices services, String opId, String code) async {
    await services.sync();

    final op = await services.ops.find(opId);

    if (mounted && op?.status == OpStatus.conflict && !_covered) {
      await _show(_Flash(ok: false, title: rejectionTitle(op!), code: code, detail: rejectionDetail(op)));
    }
  }

  /// Verde un instante y sigue. Rojo espera: un error que se va solo se pasa por alto.
  Future<void> _show(_Flash flash) async {
    _resume?.cancel();
    setState(() => _flash = flash);

    await (flash.ok ? HapticFeedback.lightImpact() : HapticFeedback.heavyImpact());
    await SystemSound.play(flash.ok ? SystemSoundType.click : SystemSoundType.alert);

    if (flash.ok) {
      _resume = Timer(const Duration(seconds: 1), _dismissFlash);
    }
  }

  void _dismissFlash() {
    if (mounted) {
      setState(() => _flash = null);
      _focus.requestFocus();
    }
  }

  Future<void> _writeCode() async {
    final value = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _WriteCodeSheet(),
    );

    if (value != null && value.trim().isNotEmpty) {
      await _onCode(value);
    }
  }

  Future<void> _openSummary() async {
    setState(() => _covered = true);
    await _camera?.stop();

    if (!mounted) {
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ScanSummaryScreen(type: widget.type, context: widget.context, entries: _entries),
      ),
    );

    if (mounted) {
      setState(() => _covered = false);
      await _camera?.start();
      _focus.requestFocus();
    }
  }

  void _leave() {
    if (_entries.isEmpty) {
      Navigator.of(context).pop();
    } else {
      unawaited(_openSummary());
    }
  }

  Future<void> _toggleTorch() async {
    await _camera?.toggleTorch();
    setState(() => _torch = !_torch);
  }

  @override
  Widget build(BuildContext context) {
    final brand = AppScope.brandOf(context);
    final flash = _flash;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          _leave();
        }
      },
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Scaffold(
          backgroundColor: Palette.ink,
          body: LayoutBuilder(
            builder: (context, constraints) {
              final center = constraints.biggest.center(Offset.zero);
              final frame = Rect.fromCenter(center: center, width: _frameSize, height: _frameSize);

              return Stack(
                fit: StackFit.expand,
                children: [
                  if (_camera != null)
                    MobileScanner(
                      controller: _camera,
                      fit: BoxFit.cover,
                      scanWindow: frame,
                      onDetect: _onDetect,
                      errorBuilder: (_, _) => const _CameraUnavailable(),
                    ),
                  IgnorePointer(
                    child: CustomPaint(
                      painter: _FramePainter(
                        frame: frame,
                        color: flash == null
                            ? Colors.white
                            : (flash.ok ? const Color(0xFF22C55E) : const Color(0xFFEF4444)),
                        closed: flash != null,
                      ),
                    ),
                  ),
                  if (flash != null)
                    Positioned.fromRect(
                      rect: frame,
                      child: Center(
                        child: Container(
                          width: 112,
                          height: 112,
                          decoration: BoxDecoration(color: flash.ok ? Palette.ok : Palette.bad, shape: BoxShape.circle),
                          child: Icon(flash.ok ? Icons.check : Icons.close, size: 68, color: Colors.white),
                        ),
                      ),
                    )
                  else
                    Positioned(
                      left: 16,
                      right: 16,
                      top: frame.bottom + 20,
                      child: const Text(
                        'Centra el código en el recuadro',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: Colors.white),
                      ),
                    ),
                  Positioned(
                    left: 16,
                    right: 16,
                    top: 0,
                    child: SafeArea(
                      bottom: false,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Row(
                          spacing: 10,
                          children: [
                            HeaderButton(
                              icon: Icons.arrow_back,
                              tooltip: 'Volver',
                              color: Palette.ink,
                              onPressed: _leave,
                            ),
                            Expanded(
                              child: Container(
                                constraints: const BoxConstraints(minHeight: 48),
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                                decoration: BoxDecoration(
                                  color: brand.primary,
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      widget.type.contextLabel,
                                      style: const TextStyle(
                                        fontSize: 14,
                                        height: 1.1,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.white,
                                      ),
                                    ),
                                    Text(
                                      widget.context,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: widget.contextIsCode
                                          ? codeStyle(18, color: Colors.white)
                                          : const TextStyle(
                                              fontSize: 18,
                                              fontWeight: FontWeight.w700,
                                              color: Colors.white,
                                            ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            if (_camera != null)
                              HeaderButton(
                                icon: _torch ? Icons.flash_off : Icons.flash_on,
                                tooltip: _torch ? 'Apagar linterna' : 'Encender linterna',
                                color: Palette.ink,
                                onPressed: _toggleTorch,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (flash != null)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: _ResultBand(flash: flash, onDismiss: _dismissFlash),
                    )
                  else
                    Positioned(
                      left: 16,
                      right: 16,
                      bottom: 0,
                      child: SafeArea(
                        top: false,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: Row(
                            spacing: 10,
                            children: [
                              Expanded(
                                child: FilledButton(
                                  key: const Key('scan.summary'),
                                  // Sin escaneos no abre nada, pero el contador se sigue viendo.
                                  style: FilledButton.styleFrom(
                                    backgroundColor: Palette.ink,
                                    foregroundColor: Colors.white,
                                    disabledBackgroundColor: Palette.ink,
                                    disabledForegroundColor: Colors.white,
                                    minimumSize: const Size.fromHeight(64),
                                  ),
                                  onPressed: _entries.isEmpty ? null : _openSummary,
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    spacing: 8,
                                    children: [
                                      Text(
                                        '${_entries.length}',
                                        style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
                                      ),
                                      Text(
                                        _entries.length == 1 ? 'escaneado' : 'escaneados',
                                        style: const TextStyle(fontSize: 16),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              Expanded(
                                child: FilledButton(
                                  key: const Key('scan.manual'),
                                  style: FilledButton.styleFrom(
                                    backgroundColor: Palette.surface,
                                    foregroundColor: Palette.ink,
                                    minimumSize: const Size.fromHeight(64),
                                  ),
                                  onPressed: _writeCode,
                                  child: const Text('Escribir código', style: TextStyle(fontSize: 18)),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Escribir la guía cuando la etiqueta no se puede leer. El campo es de la hoja: debe
/// seguir vivo mientras se cierra.
class _WriteCodeSheet extends StatefulWidget {
  const _WriteCodeSheet();

  @override
  State<_WriteCodeSheet> createState() => _WriteCodeSheetState();
}

class _WriteCodeSheetState extends State<_WriteCodeSheet> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 24, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 10,
        children: [
          const FieldLabel('Código de la guía'),
          TextField(
            key: const Key('scan.input'),
            controller: _controller,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            textInputAction: TextInputAction.done,
            style: codeStyle(22, color: Palette.ink),
            decoration: const InputDecoration(hintText: 'M0000512'),
            onSubmitted: (text) => Navigator.pop(context, text),
          ),
          FilledButton(
            key: const Key('scan.input_ok'),
            onPressed: () => Navigator.pop(context, _controller.text),
            child: const Text('Registrar'),
          ),
        ],
      ),
    );
  }
}

class _CameraUnavailable extends StatelessWidget {
  const _CameraUnavailable();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(32, 140, 32, 0),
      child: Text(
        'No se puede usar la cámara. Revisa el permiso, usa el lector o escribe el código.',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white),
      ),
    );
  }
}

class _ResultBand extends StatelessWidget {
  const _ResultBand({required this.flash, required this.onDismiss});

  final _Flash flash;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Material(
      key: const Key('scan.feedback'),
      color: flash.ok ? Palette.ok : Palette.bad,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 4,
            children: [
              Text(
                flash.title,
                style: const TextStyle(fontSize: 30, height: 1.1, fontWeight: FontWeight.w800, color: Colors.white),
              ),
              Text(
                flash.code,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: codeStyle(26, color: Colors.white),
              ),
              if (flash.detail != null)
                Text(
                  flash.detail!,
                  style: const TextStyle(fontSize: 18, height: 1.25, fontWeight: FontWeight.w600, color: Colors.white),
                ),
              if (!flash.ok) ...[
                const SizedBox(height: 12),
                FilledButton(
                  key: const Key('scan.feedback_ok'),
                  style: FilledButton.styleFrom(backgroundColor: Palette.surface, foregroundColor: Palette.badInk),
                  onPressed: onDismiss,
                  child: const Text('Entendido, seguir'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Oscurece todo menos el recuadro y dibuja sus esquinas, o el recuadro entero al leer.
class _FramePainter extends CustomPainter {
  const _FramePainter({required this.frame, required this.color, required this.closed});

  final Rect frame;
  final Color color;
  final bool closed;

  @override
  void paint(Canvas canvas, Size size) {
    final hole = RRect.fromRectAndRadius(frame, const Radius.circular(24));

    canvas.drawPath(
      Path.combine(PathOperation.difference, Path()..addRect(Offset.zero & size), Path()..addRRect(hole)),
      Paint()..color = const Color(0x9E0A0C10),
    );

    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = closed ? 9 : 7
      ..strokeCap = StrokeCap.round;

    if (closed) {
      canvas.drawRRect(hole, stroke);

      return;
    }

    const corner = 34.0;
    const radius = 24.0;

    for (final (x, y, dx, dy) in [
      (frame.left, frame.top, 1.0, 1.0),
      (frame.right, frame.top, -1.0, 1.0),
      (frame.left, frame.bottom, 1.0, -1.0),
      (frame.right, frame.bottom, -1.0, -1.0),
    ]) {
      canvas.drawPath(
        Path()
          ..moveTo(x, y + dy * (radius + corner))
          ..lineTo(x, y + dy * radius)
          ..quadraticBezierTo(x, y, x + dx * radius, y)
          ..lineTo(x + dx * (radius + corner), y),
        stroke,
      );
    }
  }

  @override
  bool shouldRepaint(_FramePainter oldDelegate) => color != oldDelegate.color || frame != oldDelegate.frame;
}

/// Título de un rechazo, en lo que el operador puede hacer.
String rejectionTitle(LocalOp op) {
  final fromCreated = op.errorCode == 'INVALID_SHIPMENT_TRANSITION' && (op.errorMessage ?? '').contains('[created]');

  return fromCreated ? 'Aún no se recibió' : 'No se pudo registrar';
}

String rejectionDetail(LocalOp op) {
  return rejectionTitle(op) == 'Aún no se recibió'
      ? 'Pásalo primero por Recibir y vuelve a escanearlo.'
      : friendlyRejection(op.errorCode);
}

/// Cómo fue cada paquete. El estado llega de la cola: al volver la señal se actualiza solo.
class ScanSummaryScreen extends StatelessWidget {
  const ScanSummaryScreen({super.key, required this.type, required this.context, required this.entries});

  final ScanType type;
  final String context;
  final List<ScanEntry> entries;

  @override
  Widget build(BuildContext buildContext) {
    final services = AppScope.of(buildContext);
    final brand = AppScope.brandOf(buildContext);

    return Scaffold(
      body: StreamBuilder<List<LocalOp>>(
        stream: services.ops.watch([OpStatus.pending, OpStatus.conflict, OpStatus.synced], kind: scanKind),
        builder: (_, snapshot) {
          final ops = {for (final op in snapshot.data ?? const <LocalOp>[]) op.id: op};
          int count(String status) => entries.where((entry) => ops[entry.opId]?.status == status).length;
          final accepted = count(OpStatus.synced);
          final rejected = count(OpStatus.conflict);
          final waiting = entries.length - accepted - rejected;

          // Lo que necesita al operador va primero.
          final sorted = [...entries]..sort((a, b) => _rank(ops[a.opId]?.status).compareTo(_rank(ops[b.opId]?.status)));

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              BrandHeader(
                brand: brand,
                title: type.label,
                subtitle: context,
                child: Row(
                  spacing: 8,
                  children: [
                    _Total(value: accepted, label: 'Aceptados', color: Palette.okInk),
                    _Total(value: waiting, label: 'En cola', color: Palette.waitInk),
                    _Total(value: rejected, label: 'Revisar', color: Palette.badInk),
                  ],
                ),
              ),
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.all(20),
                  itemCount: sorted.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (_, index) => _ScanCard(entry: sorted[index], op: ops[sorted[index].opId]),
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                  child: Row(
                    spacing: 10,
                    children: [
                      Expanded(
                        flex: 3,
                        child: FilledButton.icon(
                          key: const Key('summary.continue'),
                          icon: const Icon(Icons.qr_code_scanner),
                          onPressed: () => Navigator.of(buildContext).pop(),
                          label: const Text('Seguir escaneando'),
                        ),
                      ),
                      Expanded(
                        flex: 2,
                        child: FilledButton(
                          key: const Key('summary.finish'),
                          style: darkButton().copyWith(padding: const WidgetStatePropertyAll(EdgeInsets.zero)),
                          onPressed: () => Navigator.of(buildContext).popUntil((route) => route.isFirst),
                          child: const Text('Terminar'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  static int _rank(String? status) => switch (status) {
    OpStatus.conflict => 0,
    OpStatus.synced => 2,
    _ => 1,
  };
}

class _Total extends StatelessWidget {
  const _Total({required this.value, required this.label, required this.color});

  final int value;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(color: Palette.surface, borderRadius: BorderRadius.circular(14)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$value',
              style: TextStyle(fontSize: 30, height: 1, fontWeight: FontWeight.w800, color: color),
            ),
            Text(
              label,
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: color),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScanCard extends StatelessWidget {
  const _ScanCard({required this.entry, required this.op});

  final ScanEntry entry;
  final LocalOp? op;

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final op = this.op;

    if (op?.status == OpStatus.conflict) {
      return ItemCard(
        state: ItemState.rejected,
        title: entry.code,
        titleIsCode: true,
        subtitle: rejectionDetail(op!),
        actions: Row(
          spacing: 8,
          children: [
            Expanded(
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Palette.bad, minimumSize: const Size.fromHeight(48)),
                onPressed: () async {
                  await services.ops.retry(op.id);
                  await services.sync(manual: true);
                },
                child: const Text('Reintentar'),
              ),
            ),
            Expanded(
              child: FilledButton(
                style: darkButton().copyWith(minimumSize: const WidgetStatePropertyAll(Size.fromHeight(48))),
                onPressed: () => services.ops.discard(op.id),
                child: const Text('Descartar'),
              ),
            ),
          ],
        ),
      );
    }

    if (op?.status == OpStatus.synced) {
      return ItemCard(
        state: ItemState.ok,
        title: entry.code,
        titleIsCode: true,
        subtitle: 'Aceptado · ${clockOf(op!.createdAt)}',
      );
    }

    return ItemCard(
      state: ItemState.waiting,
      title: entry.code,
      titleIsCode: true,
      subtitle: 'Se enviará al volver la señal',
    );
  }
}
