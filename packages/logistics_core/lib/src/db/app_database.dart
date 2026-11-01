import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

part 'app_database.g.dart';

/// Estados de una operación local.
abstract final class OpStatus {
  /// Espera turno de envío, también tras un fallo de red.
  static const pending = 'pending';

  /// El servidor la aplicó, o ya la había aplicado.
  static const synced = 'synced';

  /// El servidor la rechazó por una regla de negocio: el usuario debe verla.
  static const conflict = 'conflict';
}

/// Cola de salida. Cada fila sobrevive a reinicios hasta que el servidor responde.
class PendingOps extends Table {
  /// UUID del cliente: es la clave de idempotencia en el servidor.
  TextColumn get id => text()();

  /// Canal que la envía (`scan`, `delivery`, `fleet`, `attendance`...).
  TextColumn get kind => text()();

  /// Entidad a la que pertenece. El orden se respeta dentro de cada entidad.
  TextColumn get entityKey => text()();

  TextColumn get payload => text()();

  /// Archivos locales asociados (JSON `nombre → ruta`).
  TextColumn get files => text().withDefault(const Constant('{}'))();

  TextColumn get status => text().withDefault(const Constant(OpStatus.pending))();

  IntColumn get attempts => integer().withDefault(const Constant(0))();

  DateTimeColumn get nextAttemptAt => dateTime().nullable()();

  TextColumn get errorCode => text().nullable()();

  TextColumn get errorMessage => text().nullable()();

  DateTimeColumn get createdAt => dateTime()();

  DateTimeColumn get syncedAt => dateTime().nullable()();

  /// Secuencia local: desempata operaciones creadas en el mismo instante.
  IntColumn get sequence => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Copia local de lo que la app necesita para operar sin red.
class CacheEntries extends Table {
  TextColumn get namespace => text()();

  TextColumn get key => text()();

  TextColumn get payload => text()();

  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {namespace, key};
}

/// Última descarga incremental de cada colección.
class SyncCursors extends Table {
  TextColumn get entity => text()();

  DateTimeColumn get syncedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {entity};
}

@DriftDatabase(tables: [PendingOps, CacheEntries, SyncCursors])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.executor);

  /// Abre la base cifrada. La clave solo vive en el almacén seguro del sistema.
  factory AppDatabase.encrypted(File file, String key) {
    return AppDatabase(
      NativeDatabase.createInBackground(
        file,
        setup: (database) {
          // La clave es hexadecimal generada por la app: no admite inyección.
          database.execute("PRAGMA key = \"x'$key'\";");

          final cipher = database.select('PRAGMA cipher_version;');

          if (cipher.isEmpty) {
            throw StateError('SQLCipher is not available: refusing to store data unencrypted.');
          }
        },
      ),
    );
  }

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (migrator) async {
      await migrator.createAll();
      await customStatement('CREATE INDEX pending_ops_status ON pending_ops (status, next_attempt_at, sequence)');
    },
  );
}
