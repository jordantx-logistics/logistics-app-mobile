import 'dart:io';

import 'package:logistics_core/logistics_core.dart';

const fleetEventKind = 'fleet';
const fleetReceiptKind = 'fleet_receipt';
const routesNamespace = 'routes';
const routeLogNamespace = 'route_log';

String routeEntity(int routeId) => 'route-$routeId';

/// Eventos sin archivo: van en lote, idempotentes por `event_id`.
SyncChannel fleetEventsChannel(ApiClient api) => JsonBatchChannel(
  api: api,
  path: ApiPaths.fleetSync,
  kinds: const {fleetEventKind},
  collectionKey: 'items',
  idKey: 'event_id',
);

/// Gastos con comprobante: uno a uno por su endpoint multipart, con el id de la
/// operación como `idempotency_key`. El archivo se borra al quedar confirmado.
class FleetReceiptChannel implements SyncChannel {
  FleetReceiptChannel(this._api);

  final ApiClient _api;

  @override
  Set<String> get kinds => const {fleetReceiptKind};

  @override
  int get batchSize => 1;

  @override
  Future<List<OpResult>> send(List<LocalOp> ops) {
    return runGuarded(ops, () async {
      final op = ops.single;
      final path = op.files['receipt'];

      if (path == null || !File(path).existsSync()) {
        return [
          OpResult(
            op.id,
            OpOutcome.rejected,
            errorCode: 'LOCAL_FILE_MISSING',
            message: 'The receipt file is no longer on this device.',
          ),
        ];
      }

      await _api.upload(
        ApiPaths.fleetExpenses,
        fields: {
          for (final entry in op.payload.entries)
            if (entry.value != null) entry.key: entry.value.toString(),
          'idempotency_key': op.id,
        },
        files: {'receipt': path},
      );

      File(path).deleteSync();

      return [OpResult(op.id, OpOutcome.accepted)];
    });
  }
}

/// Rutas del chofer. Las que tienen operaciones sin enviar conservan su copia local: el
/// estado del servidor aún no las refleja.
class RoutesRepository {
  RoutesRepository(this._services);

  final AppServices _services;

  Future<void> refresh() async {
    final response = await _services.api.get(
      ApiPaths.fleetRoutes,
      query: {'status': 'assigned,in_progress', 'per_page': 20},
    );
    final rows = (response['data'] as List? ?? const []).cast<Map<dynamic, dynamic>>();
    final pending = await _services.ops.all([OpStatus.pending, OpStatus.conflict]);
    final busy = pending.map((op) => op.entityKey).toSet();
    final current = await _services.cache.all(routesNamespace);
    final next = <String, Map<String, dynamic>>{
      for (final route in current)
        if (busy.contains(routeEntity(route['id'] as int))) route['id'].toString(): route,
    };

    for (final row in rows) {
      final id = row['id'] as int;

      if (!busy.contains(routeEntity(id))) {
        final detail = await _services.api.get(ApiPaths.fleetRoute(id));

        next[id.toString()] = (detail['data'] as Map).cast<String, dynamic>();
      }
    }

    await _services.cache.replaceAll(routesNamespace, next);
  }

  Stream<List<Map<String, dynamic>>> watch() => _services.cache.watchAll(routesNamespace);

  /// Lo que el chofer ha registrado en esta ruta. Se guarda aquí porque la cola se purga
  /// y el chofer debe poder comprobar lo que ya anotó, con o sin señal.
  Stream<List<Map<String, dynamic>>> watchLog(int routeId) {
    return _services.cache
        .watchAll(routeLogNamespace)
        .map(
          (rows) => [
            for (final row in rows)
              if (row['route_id'] == routeId) row,
          ]..sort((a, b) => '${b['at']}'.compareTo('${a['at']}')),
        );
  }

  Future<List<Map<String, dynamic>>> logOf(int routeId) async {
    return [
      for (final row in await _services.cache.all(routeLogNamespace))
        if (row['route_id'] == routeId) row,
    ];
  }

  Future<void> _log(int routeId, String type, String value) {
    final at = DateTime.now().toUtc().toIso8601String();

    return _services.cache.put(routeLogNamespace, '$routeId-$at', {
      'route_id': routeId,
      'type': type,
      'value': value,
      'at': at,
    });
  }

  Future<void> startRoute(Map<String, dynamic> route, String odometer, {DateTime? at}) {
    return _reading(route, 'route.start', odometer, 'in_progress', at);
  }

  Future<void> finishRoute(Map<String, dynamic> route, String odometer, {DateTime? at}) {
    return _reading(route, 'route.finish', odometer, 'finished', at);
  }

  Future<void> addMileage(Map<String, dynamic> route, String odometer, {DateTime? at}) async {
    await _reading(route, 'mileage', odometer, null, at);
    await _log(route['id'] as int, 'mileage', odometer);
  }

  Future<void> completeSegment(Map<String, dynamic> route, int segmentId) async {
    final routeId = route['id'] as int;

    await _services.ops.enqueue(
      kind: fleetEventKind,
      entityKey: routeEntity(routeId),
      payload: {'type': 'segment.complete', 'route_id': routeId, 'segment_id': segmentId},
    );

    final segments = [
      for (final raw in route['segments'] as List)
        {...(raw as Map).cast<String, dynamic>(), if (raw['id'] == segmentId) 'status': 'completed'},
    ];

    await _save({...route, 'segments': segments});
  }

  Future<void> addPerDiem(Map<String, dynamic> route, String amount) async {
    final routeId = route['id'] as int;

    await _services.ops.enqueue(
      kind: fleetEventKind,
      entityKey: routeEntity(routeId),
      payload: {'type': 'expense', 'route_id': routeId, 'expense_type': 'per_diem', 'amount': amount},
    );
    await _log(routeId, 'per_diem', amount);
  }

  /// El servidor exige comprobante para el combustible: viaja por el canal de archivos.
  Future<void> addFuel(
    Map<String, dynamic> route, {
    required String amount,
    required String liters,
    required String receiptPath,
    String? odometer,
  }) async {
    final routeId = route['id'] as int;

    await _services.ops.enqueue(
      kind: fleetReceiptKind,
      entityKey: routeEntity(routeId),
      payload: {'route_id': routeId, 'type': 'fuel', 'amount': amount, 'liters': liters, 'odometer_km': odometer},
      files: {'receipt': receiptPath},
    );
    await _log(routeId, 'fuel', amount);
  }

  Future<void> _reading(Map<String, dynamic> route, String type, String odometer, String? status, DateTime? at) async {
    final routeId = route['id'] as int;

    await _services.ops.enqueue(
      kind: fleetEventKind,
      entityKey: routeEntity(routeId),
      payload: {
        'type': type,
        'route_id': routeId,
        'odometer_km': odometer,
        'recorded_at': (at ?? DateTime.now()).toUtc().toIso8601String(),
      },
    );

    if (status != null) {
      final now = (at ?? DateTime.now()).toUtc().toIso8601String();

      await _save({
        ...route,
        'status': status,
        if (status == 'in_progress') 'started_at': now,
        if (status == 'finished') 'finished_at': now,
      });
    }
  }

  Future<void> _save(Map<String, dynamic> route) {
    return _services.cache.put(routesNamespace, route['id'].toString(), route);
  }
}
