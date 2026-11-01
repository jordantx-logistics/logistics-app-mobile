import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:logistics_core/logistics_core.dart';
import 'package:logistics_core/testing.dart';
import 'package:logistics_flota/fleet_sync.dart';

/// La ruta troncal completa, capturada sin señal y sincronizada al volver.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  List<SyncChannel> channels(ApiClient api) => [fleetEventsChannel(api), FleetReceiptChannel(api)];

  testWidgets('recorre la ruta sin red y sincroniza en orden, con su comprobante', (tester) async {
    final services = await signedInServices(role: 'driver', channels: (api, _) => channels(api));
    final repository = RoutesRepository(services);

    await repository.refresh();

    var route = (await services.cache.all(routesNamespace)).single;
    final segment = (route['segments'] as List).first as Map;
    final receipt = await evidenceFile('receipt.png');

    await repository.startRoute(route, '1000');
    route = (await services.cache.get(routesNamespace, '${route['id']}'))!;
    expect(route['status'], 'in_progress');

    await repository.addMileage(route, '1050');
    await repository.addPerDiem(route, '40');
    await repository.addFuel(route, amount: '100', liters: '25', receiptPath: receipt, odometer: '1060');
    await repository.completeSegment(route, segment['id'] as int);
    route = (await services.cache.get(routesNamespace, '${route['id']}'))!;
    await repository.finishRoute(route, '1100');

    final offline = engineOver(services, channels(offlineClient(services)));

    expect(await offline.syncNow(), SyncRunResult.retryLater);
    expect((await services.ops.all([OpStatus.pending])).length, 6);
    expect(File(receipt).existsSync(), isTrue);

    final online = engineOver(services, channels(services.api));

    expect(await online.retryNow(), SyncRunResult.completed);
    expect(await services.ops.all([OpStatus.pending, OpStatus.conflict]), isEmpty);
    expect(File(receipt).existsSync(), isFalse);

    final detail = await services.api.get(ApiPaths.fleetRoute(route['id'] as Object));

    expect((detail['data'] as Map)['status'], 'finished');
    expect((detail['data'] as Map)['computed_km'].toString(), startsWith('100'));

    await services.db.close();
  });
}
