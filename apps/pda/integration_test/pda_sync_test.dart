import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:logistics_core/logistics_core.dart';
import 'package:logistics_core/testing.dart';
import 'package:logistics_pda/main.dart';
import 'package:logistics_pda/scans_channel.dart';

/// Criterios 1, 2, 3, 5 y 6 de la Fase 8, en el emulador y contra el backend real.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  String code(int number) => 'M${number.toString().padLeft(7, '0')}';

  testWidgets('500 escaneos sin red, sin duplicar al sincronizar y reintentar', (tester) async {
    final services = await signedInServices(role: 'warehouse-operator', channels: (api, _) => [scansChannel(api)]);
    final agency = services.session.user!.agencies.first;

    final offline = engineOver(services, [scansChannel(offlineClient(services))]);
    final local = <Duration>[];
    final ids = <String>[];

    for (var number = 1; number <= 500; number++) {
      final watch = Stopwatch()..start();

      ids.add(
        await recordScan(
          ops: services.ops,
          type: ScanType.reception,
          ticketCode: code(number),
          agencyId: agency,
          embarkId: null,
        ),
      );
      local.add(watch.elapsed);
    }

    final offlineResult = await offline.syncNow();

    expect(offlineResult, SyncRunResult.retryLater);
    expect((await services.ops.all([OpStatus.pending])).length, 500);

    final batches = <Duration>[];
    final measured = _TimedChannel(scansChannel(services.api), batches);
    final online = engineOver(services, [measured]);

    expect(await online.retryNow(), SyncRunResult.completed);
    expect((await services.ops.all([OpStatus.synced])).length, 500);
    expect(measured.accepted, 500);

    // Reenviar lo mismo simula haber perdido todas las respuestas.
    final replay = await scansChannel(services.api).send([
      for (final id in ids.take(50))
        LocalOp(
          id: id,
          kind: scanKind,
          entityKey: 'x',
          payload: {
            'ticket_code': code(ids.indexOf(id) + 1),
            'scan_type': 'reception',
            'scanned_at': DateTime.now().toUtc().toIso8601String(),
            'agency_id': agency,
          },
          files: const {},
          status: OpStatus.pending,
          attempts: 0,
          createdAt: DateTime.now(),
        ),
    ]);

    expect(replay.every((result) => result.outcome == OpOutcome.duplicated), isTrue);

    binding.reportData = {
      'scans': 500,
      'local_scan_p95_ms': percentile(local, 0.95).inMilliseconds,
      'local_scan_max_ms': local.reduce((a, b) => a > b ? a : b).inMilliseconds,
      'batches': batches.length,
      'batch_p95_ms': percentile(batches, 0.95).inMilliseconds,
    };

    // ignore: avoid_print
    print('PDA_METRICS ${binding.reportData}');

    expect(percentile(local, 0.95), lessThan(const Duration(milliseconds: 100)));
    await services.db.close();
  });

  testWidgets('un estado inválido se rechaza y queda visible', (tester) async {
    final services = await signedInServices(role: 'warehouse-operator', channels: (api, _) => [scansChannel(api)]);
    final agency = services.session.user!.agencies.first;

    // Embarcar sin haber recibido: el servidor es quien lo sabe.
    final invalid = await recordScan(
      ops: services.ops,
      type: ScanType.disembark,
      ticketCode: code(510),
      agencyId: agency,
      embarkId: 999999,
    );
    final unknown = await recordScan(
      ops: services.ops,
      type: ScanType.reception,
      ticketCode: 'ZZZZ9999',
      agencyId: agency,
      embarkId: null,
    );

    await services.engine.syncNow();

    final first = (await services.ops.find(invalid))!;
    final second = (await services.ops.find(unknown))!;

    expect(first.status, OpStatus.conflict);
    expect(first.errorCode, isNotNull);
    expect(second.status, OpStatus.conflict);

    await services.db.close();
  });

  testWidgets('revocar invalida el token en menos de 1 s y no pierde la cola', (tester) async {
    final services = await signedInServices(role: 'warehouse-operator', channels: (api, _) => [scansChannel(api)]);
    final other = ApiClient(baseUrl: apiBaseUrl, appVersion: 'test', token: services.session.token);
    final pending = await recordScan(
      ops: services.ops,
      type: ScanType.reception,
      ticketCode: code(511),
      agencyId: services.session.user!.agencies.first,
      embarkId: null,
    );
    final tokenBefore = await services.session.token();

    final watch = Stopwatch()..start();
    await other.post('/api/v1/auth/logout-all');
    final revoked = ApiClient(baseUrl: apiBaseUrl, appVersion: 'test', token: () async => tokenBefore);

    await expectLater(
      revoked.get(ApiPaths.authMe),
      throwsA(isA<ApiException>().having((error) => error.isUnauthorized, 'unauthorized', isTrue)),
    );
    watch.stop();

    // ignore: avoid_print
    print('PDA_METRICS revoke_ms=${watch.elapsedMilliseconds}');
    expect(watch.elapsed, lessThan(const Duration(seconds: 1)));

    expect(await services.engine.syncNow(), SyncRunResult.unauthorized);
    expect((await services.ops.find(pending))!.status, OpStatus.pending);
    expect(services.session.current, SessionStatus.signedOut);

    await services.db.close();
  });

  testWidgets('la app recorre login, PIN y un escaneo', (tester) async {
    final services = await AppServices.create(
      appName: 'test_ui_${DateTime.now().microsecondsSinceEpoch}',
      appVersion: 'test',
      channels: (api, _) => [scansChannel(api)],
      store: MemorySecureStore(),
    );
    final repository = EmbarksRepository(services);

    services.onPull = repository.refresh;

    await tester.pumpWidget(
      LogisticsApp(
        title: 'Logistics PDA',
        services: services,
        permission: 'tracking.scan',
        home: (_) => PdaHome(embarks: repository),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('login.email')), 'e2e.warehouse-operator@logistics.test');
    await tester.enterText(find.byKey(const Key('login.password')), e2ePassword);
    await tester.tap(find.byKey(const Key('login.submit')));
    await _pumpUntil(tester, find.byKey(const Key('pin.value')));

    await tester.enterText(find.byKey(const Key('pin.value')), '4821');
    await tester.tap(find.byKey(const Key('pin.submit')));
    await _pumpUntil(tester, find.byKey(const Key('pda.reception')));

    await tester.tap(find.byKey(const Key('pda.reception')));
    await _pumpUntil(tester, find.byKey(const Key('scan.input')));

    await tester.enterText(find.byKey(const Key('scan.input')), 'nope');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _pumpUntil(tester, find.textContaining('Invalid code'));

    await tester.enterText(find.byKey(const Key('scan.input')), code(512).toLowerCase());
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _pumpUntil(tester, find.textContaining('saved'));

    await tester.enterText(find.byKey(const Key('scan.input')), code(512));
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _pumpUntil(tester, find.textContaining('already scanned'));

    services.stopBackgroundSync();
    await services.db.close();
  });
}

/// `pumpAndSettle` no termina mientras hay red o temporizadores de por medio.
Future<void> _pumpUntil(WidgetTester tester, Finder finder, {Duration timeout = const Duration(seconds: 30)}) async {
  final end = DateTime.now().add(timeout);

  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));

    if (finder.evaluate().isNotEmpty) {
      return;
    }
  }

  throw TestFailure('Not found in time: $finder');
}

class _TimedChannel implements SyncChannel {
  _TimedChannel(this._inner, this.durations);

  final SyncChannel _inner;
  final List<Duration> durations;
  int accepted = 0;

  @override
  Set<String> get kinds => _inner.kinds;

  @override
  int get batchSize => _inner.batchSize;

  @override
  Future<List<OpResult>> send(List<LocalOp> ops) async {
    final watch = Stopwatch()..start();
    final results = await _inner.send(ops);

    durations.add(watch.elapsed);
    accepted += results.where((result) => result.outcome == OpOutcome.accepted).length;

    return results;
  }
}
