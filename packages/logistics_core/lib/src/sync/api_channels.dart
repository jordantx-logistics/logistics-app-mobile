import '../api/api_client.dart';
import 'op_store.dart';
import 'sync_engine.dart';

/// Traduce los errores del API al lenguaje del motor.
///
/// Un rechazo de todo el envío (422 de forma, 403 de permiso) se reporta operación a
/// operación: reintentarlo daría lo mismo y el usuario debe verlo.
Future<List<OpResult>> runGuarded(List<LocalOp> ops, Future<List<OpResult>> Function() action) async {
  try {
    return await action();
  } on ApiException catch (error) {
    if (error.isUnauthorized) {
      throw const SyncUnauthorizedException();
    }

    if (error.isRetryable) {
      throw SyncRetryableException(error.message);
    }

    return [
      for (final op in ops)
        OpResult(
          op.id,
          OpOutcome.rejected,
          errorCode: error.errorCode ?? 'HTTP_${error.statusCode}',
          message: error.message,
        ),
    ];
  }
}

/// Convierte el resumen de un lote (`data.items`) en resultados del motor.
List<OpResult> parseBatch(Map<String, dynamic> response, String idKey) {
  final data = response['data'];
  final items = data is Map ? data['items'] : null;

  if (items is! List) {
    throw const SyncRetryableException('The server returned an unexpected batch response.');
  }

  return [
    for (final raw in items.cast<Map<dynamic, dynamic>>())
      OpResult(
        raw[idKey].toString(),
        switch (raw['status']) {
          'accepted' => OpOutcome.accepted,
          'duplicated' => OpOutcome.duplicated,
          _ => OpOutcome.rejected,
        },
        errorCode: raw['error_code']?.toString() ?? raw['reason']?.toString(),
        message: raw['message']?.toString() ?? raw['reason']?.toString(),
      ),
  ];
}

/// Canal que envía operaciones en lote JSON a un endpoint idempotente.
class JsonBatchChannel implements SyncChannel {
  JsonBatchChannel({
    required ApiClient api,
    required String path,
    required this.kinds,
    required String collectionKey,
    required String idKey,
    this.batchSize = 25,
  }) : _api = api,
       _path = path,
       _collectionKey = collectionKey,
       _idKey = idKey;

  final ApiClient _api;
  final String _path;
  final String _collectionKey;
  final String _idKey;

  @override
  final Set<String> kinds;

  @override
  final int batchSize;

  @override
  Future<List<OpResult>> send(List<LocalOp> ops) {
    return runGuarded(ops, () async {
      final response = await _api.post(
        _path,
        body: {
          _collectionKey: [
            for (final op in ops) {...op.payload, _idKey: op.id},
          ],
        },
      );

      return parseBatch(response, _idKey);
    });
  }
}
