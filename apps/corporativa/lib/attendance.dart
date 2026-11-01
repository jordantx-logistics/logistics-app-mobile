import 'package:logistics_core/logistics_core.dart';

const attendanceKind = 'attendance';
const historyNamespace = 'attendance_history';

/// Las marcaciones van una a una: el endpoint es idempotente por `idempotency_key`.
class AttendanceChannel implements SyncChannel {
  AttendanceChannel(this._api);

  final ApiClient _api;

  @override
  Set<String> get kinds => const {attendanceKind};

  @override
  int get batchSize => 1;

  @override
  Future<List<OpResult>> send(List<LocalOp> ops) {
    return runGuarded(ops, () async {
      final op = ops.single;

      await _api.post(ApiPaths.attendance, body: {...op.payload, 'idempotency_key': op.id});

      return [OpResult(op.id, OpOutcome.accepted)];
    });
  }
}

Future<String> recordAttendance({
  required OpStore ops,
  required int employeeId,
  required int agencyId,
  required String type,
  double? latitude,
  double? longitude,
  DateTime? at,
}) {
  return ops.enqueue(
    kind: attendanceKind,
    // La secuencia de entrada y salida es del empleado: el orden importa.
    entityKey: 'employee-$employeeId',
    payload: {
      'employee_id': employeeId,
      'agency_id': agencyId,
      'type': type,
      'marked_at': (at ?? DateTime.now()).toUtc().toIso8601String(),
      'source': 'app',
      'latitude': latitude,
      'longitude': longitude,
    },
  );
}

Future<void> refreshHistory(AppServices services) async {
  final response = await services.api.get(ApiPaths.attendanceMine, query: {'per_page': 30});
  final rows = (response['data'] as List? ?? const []).cast<Map<dynamic, dynamic>>();

  await services.cache.replaceAll(historyNamespace, {
    for (final row in rows) row['id'].toString(): row.cast<String, dynamic>(),
  });
}

class HistoryRow {
  const HistoryRow(this.type, this.at, this.label);

  final String type;
  final DateTime at;
  final String label;
}

/// Lo pendiente se marca como tal: todavía no es dato del servidor.
List<HistoryRow> mergeHistory(List<LocalOp> pending, List<Map<String, dynamic>> history) {
  final rows = <HistoryRow>[
    for (final op in pending)
      HistoryRow(
        op.payload['type'] as String,
        DateTime.parse(op.payload['marked_at'] as String),
        op.status == OpStatus.conflict ? 'Rejected' : 'Pending',
      ),
    for (final row in history)
      HistoryRow(row['type'] as String, DateTime.parse(row['marked_at'] as String), row['status'] as String? ?? ''),
  ];

  rows.sort((a, b) => b.at.compareTo(a.at));

  return rows;
}
