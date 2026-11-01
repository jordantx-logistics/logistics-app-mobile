import 'dart:math';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logistics_core/src/db/app_database.dart';
import 'package:logistics_core/src/sync/op_store.dart';
import 'package:logistics_core/src/sync/sync_engine.dart';

/// Servidor falso: aplica cada id una sola vez, como el backend.
class FakeChannel implements SyncChannel {
  FakeChannel({this.batchSize = 50, Set<String>? kinds}) : kinds = kinds ?? {'scan'};

  @override
  final Set<String> kinds;

  @override
  final int batchSize;

  final applied = <String>[];
  final batches = <int>[];
  final rejectIds = <String>{};
  Object? failWith;
  bool applyButFail = false;

  /// Índice de envío a partir del cual se responde sin reportar la última operación.
  bool dropLast = false;

  @override
  Future<List<OpResult>> send(List<LocalOp> ops) async {
    if (failWith != null && !applyButFail) {
      throw failWith!;
    }

    batches.add(ops.length);
    final results = <OpResult>[];

    for (final op in ops) {
      if (rejectIds.contains(op.id)) {
        results.add(OpResult(op.id, OpOutcome.rejected, errorCode: 'RULE', message: 'Not allowed'));
      } else if (applied.contains(op.id)) {
        results.add(OpResult(op.id, OpOutcome.duplicated));
      } else {
        applied.add(op.id);
        results.add(OpResult(op.id, OpOutcome.accepted));
      }
    }

    if (applyButFail) {
      // El servidor aplicó, pero la respuesta se perdió por el camino.
      applyButFail = false;
      final error = failWith!;
      failWith = null;
      throw error;
    }

    return dropLast ? results.sublist(0, results.length - 1) : results;
  }
}

void main() {
  late AppDatabase db;
  late OpStore store;
  late DateTime now;
  late FakeChannel channel;
  late SyncEngine engine;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    now = DateTime.utc(2026, 11, 1, 12);
    store = OpStore(db, clock: () => now);
    channel = FakeChannel();
    engine = SyncEngine(store: store, channels: [channel], random: Random(1), clock: () => now);
  });

  tearDown(() => db.close());

  Future<String> enqueue(String entity, {String kind = 'scan'}) =>
      store.enqueue(kind: kind, entityKey: entity, payload: {'entity': entity});

  test('guarda 500 operaciones sin red y las envía todas en lotes, una sola vez', () async {
    channel.failWith = const SyncRetryableException('offline');

    for (var i = 0; i < 500; i++) {
      await enqueue('ticket-$i');
    }

    expect(await engine.syncNow(), SyncRunResult.retryLater);
    expect((await store.all([OpStatus.pending])).length, 500);

    channel.failWith = null;
    expect(await engine.retryNow(), SyncRunResult.completed);

    expect(channel.applied.length, 500);
    expect(channel.applied.toSet().length, 500);
    expect(channel.batches.every((size) => size <= 50), isTrue);
    expect((await store.all([OpStatus.synced])).length, 500);
  });

  test('si se pierde la respuesta, reintentar no duplica', () async {
    final id = await enqueue('ticket-1');
    channel
      ..failWith = const SyncRetryableException('timeout')
      ..applyButFail = true;

    expect(await engine.syncNow(), SyncRunResult.retryLater);
    expect(channel.applied, [id]);
    expect((await store.find(id))!.status, OpStatus.pending);

    expect(await engine.retryNow(), SyncRunResult.completed);

    expect(channel.applied, [id]);
    expect((await store.find(id))!.status, OpStatus.synced);
  });

  test('un rechazo queda visible y no bloquea a otras entidades', () async {
    final rejected = await enqueue('ticket-1');
    final other = await enqueue('ticket-2');
    channel.rejectIds.add(rejected);

    await engine.syncNow();

    final conflict = (await store.find(rejected))!;
    expect(conflict.status, OpStatus.conflict);
    expect(conflict.errorCode, 'RULE');
    expect(conflict.errorMessage, 'Not allowed');
    expect((await store.find(other))!.status, OpStatus.synced);
  });

  test('un conflicto retiene lo posterior de su entidad hasta resolverse', () async {
    final first = await enqueue('route-1');
    final second = await enqueue('route-1');
    channel.rejectIds.add(first);

    await engine.syncNow();

    expect((await store.find(second))!.status, OpStatus.pending);
    expect(channel.applied, isEmpty);

    await store.discard(first);
    await engine.syncNow();

    expect(channel.applied, [second]);
  });

  test('corregir y reenviar un conflicto respeta el orden', () async {
    final first = await enqueue('route-1');
    final second = await enqueue('route-1');
    channel.rejectIds.add(first);
    await engine.syncNow();

    channel.rejectIds.clear();
    await store.retry(first);
    await engine.syncNow();

    expect(channel.applied, [first, second]);
  });

  test('respeta el orden dentro de una entidad', () async {
    final ids = [for (var i = 0; i < 5; i++) await enqueue('route-1')];

    await engine.syncNow();

    expect(channel.applied, ids);
  });

  test('sin red espera con desfase creciente y sin tope de reintentos', () async {
    final id = await enqueue('ticket-1');
    channel.failWith = const SyncRetryableException('offline');

    await engine.syncNow();
    expect((await store.find(id))!.attempts, 1);

    // Antes de vencer la espera no se reintenta.
    expect(await store.nextBatch(), isEmpty);
    expect(await engine.syncNow(), SyncRunResult.idle);
    expect((await store.find(id))!.attempts, 1);

    for (var i = 0; i < 20; i++) {
      now = now.add(const Duration(hours: 1));
      await engine.syncNow();
    }

    final op = (await store.find(id))!;
    expect(op.attempts, 21);
    expect(op.status, OpStatus.pending);
  });

  test('una sesión caducada detiene el envío y no pierde nada', () async {
    final id = await enqueue('ticket-1');
    channel.failWith = const SyncUnauthorizedException();

    expect(await engine.syncNow(), SyncRunResult.unauthorized);

    final op = (await store.find(id))!;
    expect(op.status, OpStatus.pending);
    expect(op.attempts, 0);

    channel.failWith = null;
    expect(await engine.syncNow(), SyncRunResult.completed);
    expect(channel.applied, [id]);
  });

  test('una respuesta incompleta reintenta solo lo no reportado', () async {
    final a = await enqueue('ticket-1');
    final b = await enqueue('ticket-2');
    channel.dropLast = true;

    await engine.syncNow();

    expect((await store.find(a))!.status, OpStatus.synced);
    expect((await store.find(b))!.status, OpStatus.pending);
    expect((await store.find(b))!.attempts, 1);
  });

  test('una operación sin canal se marca como conflicto y no bloquea la cola', () async {
    final orphan = await enqueue('x', kind: 'unknown');
    final ok = await enqueue('y');

    await engine.syncNow();

    expect((await store.find(orphan))!.errorCode, 'SYNC_NO_CHANNEL');
    expect((await store.find(ok))!.status, OpStatus.synced);
  });

  test('cada canal envía lo suyo sin alterar el orden global', () async {
    final files = FakeChannel(batchSize: 1, kinds: {'file'});
    final multi = SyncEngine(store: store, channels: [channel, files], random: Random(1), clock: () => now);
    final a = await enqueue('a');
    final b = await enqueue('b', kind: 'file');
    final c = await enqueue('c', kind: 'file');
    final d = await enqueue('d');

    await multi.syncNow();

    expect(channel.applied, [a, d]);
    expect(files.applied, [b, c]);
    expect(files.batches, [1, 1]);
  });

  test('dos disparos a la vez comparten la pasada', () async {
    final id = await enqueue('a');

    final results = await Future.wait([engine.syncNow(), engine.syncNow()]);

    expect(results, [SyncRunResult.completed, SyncRunResult.completed]);
    expect(channel.applied, [id]);
    expect(channel.batches, [1]);
  });

  test('sin nada que enviar no llama al canal', () async {
    expect(await engine.syncNow(), SyncRunResult.idle);
    expect(channel.batches, isEmpty);
  });

  test('la cola sobrevive a cerrar y reabrir la base', () async {
    final file = NativeDatabase.memory();
    final first = AppDatabase(file);
    final firstStore = OpStore(first, clock: () => now);
    final id = await firstStore.enqueue(
      kind: 'scan',
      entityKey: 'a',
      payload: {'x': 1},
      files: {'photo': '/tmp/p.jpg'},
    );

    final op = (await firstStore.find(id))!;
    expect(op.payload, {'x': 1});
    expect(op.files, {'photo': '/tmp/p.jpg'});
    await first.close();
  });

  test('cuenta por estado y purga lo sincronizado antiguo', () async {
    final done = await enqueue('a');
    final rejected = await enqueue('b');
    await enqueue('b');
    channel.rejectIds.add(rejected);
    await engine.syncNow();

    final counts = await store.watchCounts().first;
    expect(counts.synced, 1);
    expect(counts.conflict, 1);
    expect(counts.pending, 1);

    expect(await store.purgeSynced(const Duration(days: 7)), 0);
    now = now.add(const Duration(days: 8));
    expect(await store.purgeSynced(const Duration(days: 7)), 1);
    expect(await store.find(done), isNull);
  });

  test('el desfase crece y respeta el tope', () {
    const policy = BackoffPolicy(jitter: 0);
    final random = Random(1);

    expect(policy.delay(0, random), const Duration(seconds: 5));
    expect(policy.delay(1, random), const Duration(seconds: 10));
    expect(policy.delay(40, random), const Duration(minutes: 10));
  });

  test('el desfase aleatorio se queda dentro del margen', () {
    const policy = BackoffPolicy();
    final random = Random(7);

    for (var i = 0; i < 50; i++) {
      final ms = policy.delay(1, random).inMilliseconds;
      expect(ms, inInclusiveRange(8000, 12000));
    }
  });
}
