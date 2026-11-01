import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:logistics_core/logistics_core.dart';
import 'package:logistics_core/testing.dart';
import 'package:logistics_flota/fleet_sync.dart';
import 'package:logistics_flota/main.dart';

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

/// Corre antes que `fleet_sync_test`, que termina la única ruta sembrada: `tool/e2e_all.sh`.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('el chofer abre su ruta y un valor inválido no entra en la cola', (tester) async {
    final services = await signedInServices(
      role: 'driver',
      channels: (api, _) => [fleetEventsChannel(api), FleetReceiptChannel(api)],
    );
    final repository = RoutesRepository(services);

    await repository.refresh();

    await tester.pumpWidget(
      LogisticsApp(
        brand: AppBrand.flota,
        services: services,
        permission: 'routes.execute',
        home: (_) => RoutesHome(repository: repository),
      ),
    );

    // Restaurar una sesión abre bloqueada: es lo que protege un equipo que cambia de manos.
    await pumpUntil(tester, find.byKey(const Key('pin.value')));
    await tester.enterText(find.byKey(const Key('pin.value')), '4821');
    await tester.tap(find.byKey(const Key('pin.submit')));

    final route = (await services.cache.all(routesNamespace)).single;
    final tile = find.byKey(Key('route.${route['id']}'));

    await pumpUntil(tester, tile);
    await tester.tap(tile);
    await pumpUntil(tester, find.byKey(const Key('route.start')));

    await tester.tap(find.byKey(const Key('route.start')));
    await pumpUntil(tester, find.byKey(const Key('route.value')));
    await tester.enterText(find.byKey(const Key('route.value')), 'abc');
    await tester.tap(find.byKey(const Key('route.value_ok')));
    await tester.pump(const Duration(milliseconds: 300));

    expect(await services.ops.all([OpStatus.pending]), isEmpty);
    expect(find.textContaining('Por iniciar'), findsWidgets);

    services.stopBackgroundSync();
    await services.db.close();
  });
}
