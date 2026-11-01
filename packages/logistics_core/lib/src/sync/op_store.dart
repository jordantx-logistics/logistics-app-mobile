import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../db/app_database.dart';

/// Operación local, con su contenido ya decodificado.
class LocalOp {
  const LocalOp({
    required this.id,
    required this.kind,
    required this.entityKey,
    required this.payload,
    required this.files,
    required this.status,
    required this.attempts,
    required this.createdAt,
    this.errorCode,
    this.errorMessage,
  });

  factory LocalOp.fromRow(PendingOp row) => LocalOp(
    id: row.id,
    kind: row.kind,
    entityKey: row.entityKey,
    payload: (jsonDecode(row.payload) as Map).cast<String, dynamic>(),
    files: (jsonDecode(row.files) as Map).cast<String, String>(),
    status: row.status,
    attempts: row.attempts,
    createdAt: row.createdAt,
    errorCode: row.errorCode,
    errorMessage: row.errorMessage,
  );

  final String id;
  final String kind;
  final String entityKey;
  final Map<String, dynamic> payload;
  final Map<String, String> files;
  final String status;
  final int attempts;
  final DateTime createdAt;
  final String? errorCode;
  final String? errorMessage;
}

/// Totales que muestra la pantalla de sincronización.
class SyncCounts {
  const SyncCounts({this.pending = 0, this.conflict = 0, this.synced = 0});

  final int pending;
  final int conflict;
  final int synced;
}

/// Acceso a la cola de salida.
class OpStore {
  OpStore(this._db, {Uuid? uuid, DateTime Function()? clock})
    : _uuid = uuid ?? const Uuid(),
      _clock = clock ?? DateTime.now;

  final AppDatabase _db;
  final Uuid _uuid;
  final DateTime Function() _clock;

  /// Guarda una operación y responde al instante: la red es cosa del motor.
  Future<String> enqueue({
    required String kind,
    required String entityKey,
    required Map<String, dynamic> payload,
    Map<String, String> files = const {},
    String? id,
  }) async {
    final opId = id ?? _uuid.v4();

    await _db.transaction(() async {
      final last = await (_db.selectOnly(_db.pendingOps)..addColumns([_db.pendingOps.sequence.max()])).getSingle();
      final sequence = (last.read(_db.pendingOps.sequence.max()) ?? 0) + 1;

      await _db
          .into(_db.pendingOps)
          .insert(
            PendingOpsCompanion.insert(
              id: opId,
              kind: kind,
              entityKey: entityKey,
              payload: jsonEncode(payload),
              files: Value(jsonEncode(files)),
              createdAt: _clock().toUtc(),
              sequence: sequence,
            ),
          );
    });

    return opId;
  }

  /// Lo que puede salir ahora, como máximo una operación por entidad.
  ///
  /// Una entidad en espera o con conflicto retiene sus operaciones posteriores, y
  /// la siguiente de una entidad no sale hasta conocer el resultado de la anterior:
  /// de lo contrario se aplicaría aunque la primera fuera rechazada.
  Future<List<LocalOp>> nextBatch({int limit = 200}) async {
    final rows =
        await (_db.select(_db.pendingOps)
              ..where((op) => op.status.isIn([OpStatus.pending, OpStatus.conflict]))
              ..orderBy([(op) => OrderingTerm.asc(op.sequence)]))
            .get();

    final now = _clock().toUtc();
    final blocked = <String>{};
    final ready = <LocalOp>[];

    for (final row in rows) {
      if (blocked.contains(row.entityKey)) {
        continue;
      }

      final waiting = row.nextAttemptAt != null && row.nextAttemptAt!.toUtc().isAfter(now);

      if (row.status == OpStatus.conflict || waiting) {
        blocked.add(row.entityKey);
        continue;
      }

      ready.add(LocalOp.fromRow(row));
      blocked.add(row.entityKey);

      if (ready.length == limit) {
        break;
      }
    }

    return ready;
  }

  Future<void> markSynced(String id) {
    return (_db.update(_db.pendingOps)..where((op) => op.id.equals(id))).write(
      PendingOpsCompanion(
        status: const Value(OpStatus.synced),
        syncedAt: Value(_clock().toUtc()),
        errorCode: const Value(null),
        errorMessage: const Value(null),
      ),
    );
  }

  Future<void> markConflict(String id, String? code, String? message) {
    return (_db.update(_db.pendingOps)..where((op) => op.id.equals(id))).write(
      PendingOpsCompanion(status: const Value(OpStatus.conflict), errorCode: Value(code), errorMessage: Value(message)),
    );
  }

  /// Fallo de red: se reintenta más tarde, sin tope.
  Future<void> markRetry(String id, DateTime nextAttempt, String? message) async {
    await _db.customUpdate(
      'UPDATE pending_ops SET attempts = attempts + 1, next_attempt_at = ?, error_message = ? WHERE id = ?',
      variables: [Variable<DateTime>(nextAttempt.toUtc()), Variable<String>(message), Variable<String>(id)],
      updates: {_db.pendingOps},
    );
  }

  Future<LocalOp?> find(String id) async {
    final row = await (_db.select(_db.pendingOps)..where((op) => op.id.equals(id))).getSingleOrNull();

    return row == null ? null : LocalOp.fromRow(row);
  }

  /// Reenvía un conflicto, por ejemplo tras corregir el dato en el servidor.
  Future<void> retry(String id) {
    return (_db.update(_db.pendingOps)..where((op) => op.id.equals(id))).write(
      const PendingOpsCompanion(
        status: Value(OpStatus.pending),
        nextAttemptAt: Value(null),
        errorCode: Value(null),
        errorMessage: Value(null),
      ),
    );
  }

  /// Fin de la espera de todas las operaciones: reintento manual o vuelta de la red.
  Future<void> clearBackoff() {
    return (_db.update(
      _db.pendingOps,
    )..where((op) => op.status.equals(OpStatus.pending))).write(const PendingOpsCompanion(nextAttemptAt: Value(null)));
  }

  /// Descarta un conflicto que el usuario ya revisó, liberando su entidad.
  Future<void> discard(String id) {
    return (_db.delete(_db.pendingOps)..where((op) => op.id.equals(id))).go();
  }

  /// Purga lo ya sincronizado con cierta antigüedad.
  Future<int> purgeSynced(Duration olderThan) {
    final limit = _clock().toUtc().subtract(olderThan);

    return (_db.delete(
      _db.pendingOps,
    )..where((op) => op.status.equals(OpStatus.synced) & op.syncedAt.isSmallerThanValue(limit))).go();
  }

  Stream<List<LocalOp>> watch(List<String> statuses, {String? kind}) {
    final query = _db.select(_db.pendingOps)
      ..where((op) => op.status.isIn(statuses))
      ..orderBy([(op) => OrderingTerm.desc(op.sequence)]);

    if (kind != null) {
      query.where((op) => op.kind.equals(kind));
    }

    return query.watch().map((rows) => rows.map(LocalOp.fromRow).toList());
  }

  Future<List<LocalOp>> all(List<String> statuses, {String? kind}) {
    final query = _db.select(_db.pendingOps)
      ..where((op) => op.status.isIn(statuses))
      ..orderBy([(op) => OrderingTerm.asc(op.sequence)]);

    if (kind != null) {
      query.where((op) => op.kind.equals(kind));
    }

    return query.get().then((rows) => rows.map(LocalOp.fromRow).toList());
  }

  Stream<SyncCounts> watchCounts() {
    final count = _db.pendingOps.id.count();
    final query = _db.selectOnly(_db.pendingOps)
      ..addColumns([_db.pendingOps.status, count])
      ..groupBy([_db.pendingOps.status]);

    return query.watch().map((rows) {
      final totals = {for (final row in rows) row.read(_db.pendingOps.status): row.read(count) ?? 0};

      return SyncCounts(
        pending: totals[OpStatus.pending] ?? 0,
        conflict: totals[OpStatus.conflict] ?? 0,
        synced: totals[OpStatus.synced] ?? 0,
      );
    });
  }
}
