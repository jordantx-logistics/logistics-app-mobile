import 'package:flutter/material.dart';
import 'package:logistics_core/logistics_core.dart';

const scanKind = 'scan';
const embarksNamespace = 'embarks';

/// Los escaneos van en lotes al endpoint idempotente por `scan_id`.
SyncChannel scansChannel(ApiClient api) => JsonBatchChannel(
  api: api,
  path: ApiPaths.scansSync,
  kinds: const {scanKind},
  collectionKey: 'scans',
  idKey: 'scan_id',
  // Cada escaneo es una transacción en el servidor: con 50, el lote pasaba de 4 s.
  batchSize: 20,
);

/// Tipos de escaneo del backend (`Scan::TYPES`).
enum ScanType {
  reception('reception', 'Reception', Icons.move_to_inbox, needsEmbark: false),
  embark('embark', 'Embark', Icons.local_shipping, needsEmbark: true),
  disembark('disembark', 'Disembark', Icons.unarchive, needsEmbark: true),
  inventory('inventory', 'Inventory', Icons.inventory_2, needsEmbark: false),
  outForDelivery('out_for_delivery', 'Out for delivery', Icons.delivery_dining, needsEmbark: false);

  const ScanType(this.code, this.label, this.icon, {required this.needsEmbark});

  final String code;
  final String label;
  final IconData icon;
  final bool needsEmbark;
}

/// El código visible de la guía: 8 caracteres alfanuméricos. El resto lo valida el servidor.
final _ticketCode = RegExp(r'^[A-Z0-9]{8}$');

String? normalizeTicketCode(String raw) {
  final code = raw.trim().toUpperCase();

  return _ticketCode.hasMatch(code) ? code : null;
}

/// Manifiestos disponibles sin red. Los crea el supervisor desde la web.
class EmbarksRepository {
  EmbarksRepository(this._services);

  final AppServices _services;

  Future<void> refresh() async {
    final response = await _services.api.get(ApiPaths.embarks, query: {'per_page': 50});
    final rows = (response['data'] as List? ?? const []).cast<Map<dynamic, dynamic>>();

    await _services.cache.replaceAll(embarksNamespace, {
      for (final row in rows) row['id'].toString(): row.cast<String, dynamic>(),
    });
  }

  Future<List<Map<String, dynamic>>> all() => _services.cache.all(embarksNamespace);
}

/// Guarda el escaneo y responde al instante: la red es cosa del motor.
Future<String> recordScan({
  required OpStore ops,
  required ScanType type,
  required String ticketCode,
  required int? agencyId,
  required int? embarkId,
  DateTime? at,
}) {
  return ops.enqueue(
    kind: scanKind,
    entityKey: ticketCode,
    payload: {
      'ticket_code': ticketCode,
      'scan_type': type.code,
      'scanned_at': (at ?? DateTime.now()).toUtc().toIso8601String(),
      'agency_id': agencyId,
      'embark_id': embarkId,
    },
  );
}
