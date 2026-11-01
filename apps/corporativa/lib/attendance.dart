import 'package:logistics_core/logistics_core.dart';

const attendanceKind = 'attendance';
const historyNamespace = 'attendance_history';
const daysNamespace = 'attendance_days';

/// Tipos de marcación del backend, en el orden de una jornada.
abstract final class Mark {
  static const clockIn = 'in';
  static const lunchStart = 'break-start';
  static const lunchEnd = 'break-end';
  static const clockOut = 'out';
}

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

  final days = await services.api.get(ApiPaths.attendanceMineDays, query: {'per_page': 30});
  final dayRows = (days['data'] as List? ?? const []).cast<Map<dynamic, dynamic>>();

  await services.cache.replaceAll(daysNamespace, {
    for (final row in dayRows) row['work_date'].toString(): row.cast<String, dynamic>(),
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
      if (row['status'] != 'voided')
        HistoryRow(row['type'] as String, DateTime.parse(row['marked_at'] as String), row['status'] as String? ?? ''),
  ];

  rows.sort((a, b) => b.at.compareTo(a.at));

  return rows;
}

/// Cómo va la jornada de hoy, a partir de sus marcaciones.
class WorkDay {
  WorkDay._(this.marks);

  /// [rows] puede traer otros días y lo rechazado: no cuenta para el estado.
  factory WorkDay.today(List<HistoryRow> rows, {DateTime? now}) {
    final today = (now ?? DateTime.now()).toLocal();
    final marks = rows.where((row) {
      final at = row.at.toLocal();

      return row.label != 'Rejected' && at.year == today.year && at.month == today.month && at.day == today.day;
    }).toList()..sort((a, b) => a.at.compareTo(b.at));

    return WorkDay._(marks);
  }

  final List<HistoryRow> marks;

  String? get lastType => marks.lastOrNull?.type;

  bool get notStarted => marks.isEmpty;
  bool get atLunch => lastType == Mark.lunchStart;
  bool get finished => lastType == Mark.clockOut;
  bool get working => !notStarted && !atLunch && !finished;

  /// Ya almorzó hoy: solo queda la salida.
  bool get hadLunch => marks.any((mark) => mark.type == Mark.lunchEnd);

  DateTime? timeOf(String type) => marks.where((mark) => mark.type == type).lastOrNull?.at;

  DateTime? get firstIn => marks.where((mark) => mark.type == Mark.clockIn).firstOrNull?.at;

  /// La misma cuenta que el consolidado del servidor, para verla sin esperar a la señal.
  ({int worked, int lunch}) minutes({DateTime? now}) {
    final end = now ?? DateTime.now();
    var worked = 0;
    var lunch = 0;
    DateTime? working;
    DateTime? eating;

    for (final mark in marks) {
      if (mark.type == Mark.clockIn) {
        working ??= mark.at;
        continue;
      }

      if (working != null) {
        worked += mark.at.difference(working).inMinutes;
        working = null;
      }

      if (eating != null) {
        lunch += mark.at.difference(eating).inMinutes;
        eating = null;
      }

      if (mark.type == Mark.lunchStart) {
        eating = mark.at;
      } else if (mark.type == Mark.lunchEnd) {
        working = mark.at;
      }
    }

    if (working != null) {
      worked += end.difference(working).inMinutes;
    }

    if (eating != null) {
      lunch += end.difference(eating).inMinutes;
    }

    return (worked: worked, lunch: lunch);
  }
}
