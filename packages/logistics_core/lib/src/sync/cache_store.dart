import 'dart:convert';

import 'package:drift/drift.dart';

import '../db/app_database.dart';

/// Copia local de los datos del servidor, por colección.
class CacheStore {
  CacheStore(this._db, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final AppDatabase _db;
  final DateTime Function() _clock;

  Future<void> put(String namespace, String key, Map<String, dynamic> value) {
    return _db
        .into(_db.cacheEntries)
        .insertOnConflictUpdate(
          CacheEntriesCompanion.insert(
            namespace: namespace,
            key: key,
            payload: jsonEncode(value),
            updatedAt: _clock().toUtc(),
          ),
        );
  }

  Future<Map<String, dynamic>?> get(String namespace, String key) async {
    final row = await (_db.select(
      _db.cacheEntries,
    )..where((entry) => entry.namespace.equals(namespace) & entry.key.equals(key))).getSingleOrNull();

    return row == null ? null : _decode(row.payload);
  }

  Future<void> remove(String namespace, String key) {
    return (_db.delete(
      _db.cacheEntries,
    )..where((entry) => entry.namespace.equals(namespace) & entry.key.equals(key))).go();
  }

  /// Sustituye la colección entera: lo que ya no está en el servidor desaparece.
  Future<void> replaceAll(String namespace, Map<String, Map<String, dynamic>> values) {
    return _db.transaction(() async {
      await (_db.delete(_db.cacheEntries)..where((entry) => entry.namespace.equals(namespace))).go();

      await _db.batch((batch) {
        batch.insertAll(_db.cacheEntries, [
          for (final item in values.entries)
            CacheEntriesCompanion.insert(
              namespace: namespace,
              key: item.key,
              payload: jsonEncode(item.value),
              updatedAt: _clock().toUtc(),
            ),
        ]);
      });
    });
  }

  Future<List<Map<String, dynamic>>> all(String namespace) async {
    final rows = await (_db.select(_db.cacheEntries)..where((entry) => entry.namespace.equals(namespace))).get();

    return rows.map((row) => _decode(row.payload)).toList();
  }

  Stream<List<Map<String, dynamic>>> watchAll(String namespace) {
    return (_db.select(_db.cacheEntries)..where((entry) => entry.namespace.equals(namespace))).watch().map(
      (rows) => rows.map((row) => _decode(row.payload)).toList(),
    );
  }

  Future<DateTime?> cursor(String entity) async {
    final row = await (_db.select(_db.syncCursors)..where((cursor) => cursor.entity.equals(entity))).getSingleOrNull();

    return row?.syncedAt;
  }

  Future<void> setCursor(String entity, DateTime at) {
    return _db
        .into(_db.syncCursors)
        .insertOnConflictUpdate(SyncCursorsCompanion.insert(entity: entity, syncedAt: at.toUtc()));
  }

  Map<String, dynamic> _decode(String payload) => (jsonDecode(payload) as Map).cast<String, dynamic>();
}
