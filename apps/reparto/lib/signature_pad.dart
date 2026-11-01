import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Lienzo de firma. Pinta y exporta a PNG sin depender de otro paquete.
class SignaturePad extends StatefulWidget {
  const SignaturePad({super.key, required this.controller});

  final SignatureController controller;

  @override
  State<SignaturePad> createState() => _SignaturePadState();
}

class SignatureController extends ChangeNotifier {
  final List<List<Offset>> _strokes = [];

  bool get isEmpty => _strokes.isEmpty;

  void startStroke(Offset point) {
    _strokes.add([point]);
    notifyListeners();
  }

  void extendStroke(Offset point) {
    _strokes.last.add(point);
    notifyListeners();
  }

  void clear() {
    _strokes.clear();
    notifyListeners();
  }

  /// Guarda la firma con fondo blanco en [path].
  Future<void> saveTo(String path, {double width = 800, double height = 300}) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, width, height));

    canvas.drawRect(Rect.fromLTWH(0, 0, width, height), Paint()..color = Colors.white);
    _paintStrokes(canvas, _strokes);

    final image = await recorder.endRecording().toImage(width.toInt(), height.toInt());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);

    await File(path).writeAsBytes(bytes!.buffer.asUint8List());
  }
}

void _paintStrokes(Canvas canvas, List<List<Offset>> strokes) {
  final paint = Paint()
    ..color = Colors.black
    ..strokeWidth = 3
    ..strokeCap = StrokeCap.round
    ..style = PaintingStyle.stroke;

  for (final stroke in strokes) {
    final path = Path()..moveTo(stroke.first.dx, stroke.first.dy);

    for (final point in stroke.skip(1)) {
      path.lineTo(point.dx, point.dy);
    }

    canvas.drawPath(path, paint);
  }
}

class _SignaturePadState extends State<SignaturePad> {
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 200,
      decoration: BoxDecoration(color: Colors.white, border: Border.all(color: Colors.grey)),
      // El reconocedor impaciente gana al scroll de la pantalla: un trazo vertical dibuja.
      child: Listener(
        onPointerDown: (event) => widget.controller.startStroke(event.localPosition),
        onPointerMove: (event) => widget.controller.extendStroke(event.localPosition),
        child: RawGestureDetector(
          gestures: {
            EagerGestureRecognizer: GestureRecognizerFactoryWithHandlers<EagerGestureRecognizer>(
              EagerGestureRecognizer.new,
              (_) {},
            ),
          },
          child: ListenableBuilder(
            listenable: widget.controller,
            builder: (_, _) => CustomPaint(painter: _SignaturePainter(widget.controller), size: Size.infinite),
          ),
        ),
      ),
    );
  }
}

class _SignaturePainter extends CustomPainter {
  _SignaturePainter(this.controller);

  final SignatureController controller;

  @override
  void paint(Canvas canvas, Size size) => _paintStrokes(canvas, controller._strokes);

  @override
  bool shouldRepaint(_SignaturePainter oldDelegate) => true;
}
