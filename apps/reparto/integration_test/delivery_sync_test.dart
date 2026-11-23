import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:logistics_core/logistics_core.dart';
import 'package:logistics_core/testing.dart';
import 'package:logistics_reparto/delivery_sync.dart';

/// Criterio 4 de la Fase 8: la entrega con evidencia sobrevive a una subida fallida.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('la hoja de ruta trae destinatario y dirección, y queda en local', (tester) async {
    final services = await signedInServices(role: 'courier', channels: (api, _) => [DeliveryChannel(api)]);
    final repository = StopsRepository(services);

    await repository.refresh();

    final stops = await services.cache.all(stopsNamespace);

    expect(stops, isNotEmpty);
    expect(stops.first['recipient_name'], isNotNull);
    expect(stops.first['recipient_address'], startsWith('Av. Lima'));

    await services.db.close();
  });

  testWidgets('sin red la entrega no se pierde; al volver sube evidencia y evento', (tester) async {
    final services = await signedInServices(role: 'courier', channels: (api, _) => [DeliveryChannel(api)]);
    final repository = StopsRepository(services);

    await repository.refresh();

    final stop = (await services.cache.all(stopsNamespace)).firstWhere((row) => row['status'] == 'assigned');
    final signature = await evidenceFile('signature.png');
    final photo = await evidenceFile('photo.png');

    await repository.start(stop);
    await repository.complete(
      stop,
      recipientName: 'Ana Perez',
      recipientDocument: '12345678',
      latitude: -12.04,
      longitude: -77.04,
      signaturePath: signature,
      photoPath: photo,
    );

    final offline = engineOver(services, [DeliveryChannel(offlineClient(services))]);

    expect(await offline.syncNow(), SyncRunResult.retryLater);
    expect((await services.ops.all([OpStatus.pending])).length, 2);
    expect(File(signature).existsSync(), isTrue, reason: 'la evidencia sigue en disco');
    expect(File(photo).existsSync(), isTrue);

    final online = engineOver(services, [DeliveryChannel(services.api)]);

    expect(await online.retryNow(), SyncRunResult.completed);
    expect((await services.ops.all([OpStatus.pending, OpStatus.conflict])), isEmpty);
    expect(File(signature).existsSync(), isFalse, reason: 'se borra al quedar confirmada');
    expect(File(photo).existsSync(), isFalse);

    await repository.refresh();
    final remaining = await services.cache.all(stopsNamespace);

    // Queda en la hoja como hecha: el repartidor puede comprobar lo que ya entregó.
    expect(remaining.singleWhere((row) => row['id'] == stop['id'])['status'], 'delivered');

    await services.db.close();
  });

  testWidgets('no entregado: registra el motivo y sale de la hoja', (tester) async {
    final services = await signedInServices(role: 'courier', channels: (api, _) => [DeliveryChannel(api)]);
    final repository = StopsRepository(services);

    await repository.refresh();

    final stop = (await services.cache.all(stopsNamespace)).firstWhere((row) => row['status'] == 'assigned');

    await repository.fail(stop, 'Recipient not found');
    await services.engine.syncNow();

    final [op] = await services.ops.all([OpStatus.synced], kind: deliveryKind);

    expect(op.payload['failure_reason'], 'Recipient not found');

    await services.db.close();
  });

  testWidgets('sin el archivo local queda como conflicto visible, no se pierde en silencio', (tester) async {
    final services = await signedInServices(role: 'courier', channels: (api, _) => [DeliveryChannel(api)]);
    final repository = StopsRepository(services);

    await repository.refresh();

    final stop = (await services.cache.all(stopsNamespace)).firstWhere((row) => row['status'] == 'assigned');
    final photo = await evidenceFile('photo.png');
    final signature = await evidenceFile('signature.png');

    await repository.complete(
      stop,
      recipientName: 'Ana Perez',
      recipientDocument: '12345678',
      latitude: -12.04,
      longitude: -77.04,
      signaturePath: signature,
      photoPath: photo,
    );
    File(photo).deleteSync();

    await services.engine.syncNow();

    final [op] = await services.ops.all([OpStatus.conflict]);

    expect(op.errorCode, 'LOCAL_FILE_MISSING');

    await services.db.close();
  });
}
