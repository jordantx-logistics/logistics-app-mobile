import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:logistics_core/logistics_core.dart';
import 'package:logistics_core/testing.dart';
import 'package:logistics_reparto/delivery_sync.dart';
import 'package:logistics_reparto/main.dart';
import 'package:logistics_reparto/signature_pad.dart';

Future<void> pumpUntil(WidgetTester tester, Finder finder) async {
  final end = DateTime.now().add(const Duration(seconds: 30));

  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));

    if (finder.evaluate().isNotEmpty) {
      return;
    }
  }

  throw TestFailure('Not found in time: $finder');
}

/// La cámara y el GPS no se automatizan: aquí se prueba hasta el formulario de entrega y
/// que la firma genere un PNG. La parte con archivos la cubre `delivery_sync_test.dart`.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('la app muestra la hoja de ruta, inicia y abre el formulario de entrega', (tester) async {
    final services = await signedInServices(role: 'courier', channels: (api, _) => [DeliveryChannel(api)]);
    final repository = StopsRepository(services);

    services.onPull = repository.refresh;
    await repository.refresh();

    await tester.pumpWidget(
      LogisticsApp(
        title: 'Logistics Delivery',
        services: services,
        permission: 'delivery.execute',
        home: (_) => StopsHome(repository: repository),
      ),
    );

    // Restaurar una sesión abre bloqueada: es lo que protege un equipo que cambia de manos.
    await pumpUntil(tester, find.byKey(const Key('pin.value')));
    await tester.enterText(find.byKey(const Key('pin.value')), '4821');
    await tester.tap(find.byKey(const Key('pin.submit')));

    final stop = (await services.cache.all(stopsNamespace)).firstWhere((row) => row['status'] == 'assigned');
    final tile = find.byKey(Key('stop.${stop['id']}'));

    await pumpUntil(tester, tile);
    await tester.tap(tile);
    await pumpUntil(tester, find.byKey(const Key('stop.start')));
    expect(find.textContaining('Av. Lima'), findsWidgets);

    await tester.tap(find.byKey(const Key('stop.complete')));
    await pumpUntil(tester, find.text('Confirm delivery'));

    // Sin firma ni foto no deja confirmar.
    await tester.tap(find.text('Confirm delivery'));
    await pumpUntil(tester, find.textContaining('are required'));
    expect(await services.ops.all([OpStatus.pending]), isEmpty);

    services.stopBackgroundSync();
    await services.db.close();
  });

  testWidgets('un trazo vertical firma y no mueve la pantalla', (tester) async {
    final controller = SignatureController();
    final scroll = ScrollController();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            controller: scroll,
            children: [
              SignaturePad(controller: controller),
              const SizedBox(height: 2000),
            ],
          ),
        ),
      ),
    );

    await tester.drag(find.byType(SignaturePad), const Offset(0, -120));
    await tester.pump();

    expect(controller.isEmpty, isFalse);
    expect(scroll.offset, 0);
  });

  testWidgets('la firma se exporta a un PNG real', (tester) async {
    final controller = SignatureController()
      ..startStroke(const Offset(10, 10))
      ..extendStroke(const Offset(100, 60));
    final path = await evidenceFile('signature.png');

    await tester.runAsync(() => controller.saveTo(path));

    expect(controller.isEmpty, isFalse);
    controller.clear();
    expect(controller.isEmpty, isTrue);
  });
}
