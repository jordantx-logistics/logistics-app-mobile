import 'dart:io';

import 'package:logistics_core/logistics_core.dart';

const deliveryKind = 'delivery';
const stopsNamespace = 'stops';

String stopEntity(int deliveryId) => 'delivery-$deliveryId';

/// Dos fases: primero la evidencia, luego el evento. Si la subida falla, la entrega
/// sigue pendiente con sus archivos en disco y se reintenta entera; reintentar la subida
/// reemplaza el archivo en el servidor. Los archivos se borran al quedar confirmada.
class DeliveryChannel implements SyncChannel {
  DeliveryChannel(this._api);

  final ApiClient _api;

  @override
  Set<String> get kinds => const {deliveryKind};

  @override
  int get batchSize => 25;

  @override
  Future<List<OpResult>> send(List<LocalOp> ops) {
    return runGuarded(ops, () async {
      final results = <OpResult>[];
      final items = <Map<String, dynamic>>[];
      final sent = <LocalOp>[];

      for (final op in ops) {
        final missing = op.files.values.where((path) => !File(path).existsSync());

        if (missing.isNotEmpty) {
          results.add(
            OpResult(
              op.id,
              OpOutcome.rejected,
              errorCode: 'LOCAL_FILE_MISSING',
              message: 'The evidence is no longer on this device.',
            ),
          );
          continue;
        }

        try {
          items.add({...op.payload, 'event_id': op.id, ...await _uploadEvidence(op)});
          sent.add(op);
        } on ApiException catch (error) {
          if (!error.isRejection) {
            rethrow;
          }

          results.add(
            OpResult(
              op.id,
              OpOutcome.rejected,
              errorCode: error.errorCode ?? 'HTTP_${error.statusCode}',
              message: error.message,
            ),
          );
        }
      }

      if (items.isEmpty) {
        return results;
      }

      final response = await _api.post(ApiPaths.deliveriesBatch, body: {'items': items});
      final batch = parseBatch(response, 'event_id');

      for (final result in batch) {
        if (result.outcome != OpOutcome.rejected) {
          _deleteFiles(sent.firstWhere((op) => op.id == result.opId));
        }
      }

      return [...results, ...batch];
    });
  }

  Future<Map<String, String>> _uploadEvidence(LocalOp op) async {
    final paths = <String, String>{};

    for (final entry in op.files.entries) {
      final response = await _api.upload(
        ApiPaths.deliveryEvidence(op.payload['delivery_id'] as int),
        fields: {'type': entry.key},
        files: {'file': entry.value},
      );

      paths['${entry.key}_path'] = (response['data'] as Map)['path'] as String;
    }

    return paths;
  }

  void _deleteFiles(LocalOp op) {
    for (final path in op.files.values) {
      final file = File(path);

      if (file.existsSync()) {
        file.deleteSync();
      }
    }
  }
}

/// Hoja de ruta local. Una parada con operaciones sin enviar conserva su estado local;
/// lo demás lo decide el servidor, incluida una reasignación.
class StopsRepository {
  StopsRepository(this._services);

  final AppServices _services;

  Future<void> refresh() async {
    // También lo cerrado hoy: el repartidor debe poder comprobar lo que ya hizo.
    final response = await _services.api.get(ApiPaths.routeSheet, query: {'closed_today': 1});
    final rows = (response['data'] as List? ?? const []).cast<Map<dynamic, dynamic>>();
    final pending = await _services.ops.all([OpStatus.pending, OpStatus.conflict], kind: deliveryKind);
    final busy = pending.map((op) => op.entityKey).toSet();
    final current = await _services.cache.all(stopsNamespace);

    await _services.cache.replaceAll(stopsNamespace, {
      for (final stop in current)
        if (busy.contains(stopEntity(stop['id'] as int))) stop['id'].toString(): stop,
      for (final row in rows)
        if (!busy.contains(stopEntity(row['id'] as int))) row['id'].toString(): row.cast<String, dynamic>(),
    });

    await _services.cache.setCursor(stopsNamespace, DateTime.now());
  }

  Stream<List<Map<String, dynamic>>> watch() => _services.cache.watchAll(stopsNamespace);

  Future<void> start(Map<String, dynamic> stop) async {
    await _enqueue(stop, {'action': 'start'});
    await _setStatus(stop, 'in_progress');
  }

  Future<void> complete(
    Map<String, dynamic> stop, {
    required String recipientName,
    required String recipientDocument,
    required double latitude,
    required double longitude,
    required String signaturePath,
    required String photoPath,
    DateTime? at,
  }) async {
    await _enqueue(
      stop,
      {
        'action': 'complete',
        'recipient_name': recipientName,
        'recipient_document': recipientDocument,
        'latitude': latitude,
        'longitude': longitude,
        'captured_at': (at ?? DateTime.now()).toUtc().toIso8601String(),
      },
      files: {'signature': signaturePath, 'photo': photoPath},
    );
    await _setStatus(stop, 'delivered');
  }

  Future<void> fail(Map<String, dynamic> stop, String reason) async {
    await _enqueue(stop, {'action': 'fail', 'failure_reason': reason});
    await _setStatus(stop, 'failed');
  }

  Future<String> _enqueue(
    Map<String, dynamic> stop,
    Map<String, dynamic> event, {
    Map<String, String> files = const {},
  }) {
    final id = stop['id'] as int;

    return _services.ops.enqueue(
      kind: deliveryKind,
      entityKey: stopEntity(id),
      payload: {...event, 'delivery_id': id},
      files: files,
    );
  }

  Future<void> _setStatus(Map<String, dynamic> stop, String status) {
    return _services.cache.put(stopsNamespace, stop['id'].toString(), {...stop, 'status': status});
  }
}
