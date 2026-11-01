import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:logistics_core/logistics_core.dart';
import 'package:logistics_core/testing.dart';
import 'package:logistics_corporativa/attendance.dart';

/// Marcaciones sin red, sin duplicar y con el historial propio.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('marca sin red, sincroniza una vez y aparece en el historial', (tester) async {
    final services = await signedInServices(role: 'employee', channels: (api, _) => [AttendanceChannel(api)]);
    final user = services.session.user!;

    expect(user.employeeId, isNotNull);
    expect(user.employeeAgencyId, isNotNull);

    final mark = await recordAttendance(
      ops: services.ops,
      employeeId: user.employeeId!,
      agencyId: user.employeeAgencyId!,
      type: 'in',
    );

    final offline = engineOver(services, [AttendanceChannel(offlineClient(services))]);

    expect(await offline.syncNow(), SyncRunResult.retryLater);

    final pending = await services.ops.all([OpStatus.pending]);

    expect(mergeHistory(pending, const []).single.label, 'Pending');

    final online = engineOver(services, [AttendanceChannel(services.api)]);

    expect(await online.retryNow(), SyncRunResult.completed);

    // Reenviar con la misma clave simula una respuesta perdida.
    await AttendanceChannel(services.api).send([(await services.ops.find(mark))!]);

    await refreshHistory(services);
    final history = await services.cache.all(historyNamespace);

    expect(history.where((row) => row['type'] == 'in').length, 1);

    await services.db.close();
  });

  testWidgets('la secuencia inválida se rechaza y queda visible', (tester) async {
    final services = await signedInServices(role: 'employee', channels: (api, _) => [AttendanceChannel(api)]);
    final user = services.session.user!;

    // Marcar por la ficha de otro empleado: el servidor lo rechaza, la app no lo decide.
    final repeated = await recordAttendance(
      ops: services.ops,
      employeeId: user.employeeId! + 100000,
      agencyId: user.employeeAgencyId!,
      type: 'in',
    );

    await services.engine.syncNow();

    final op = (await services.ops.find(repeated))!;

    expect(op.status, OpStatus.conflict);
    expect(mergeHistory([op], const []).single.label, 'Rejected');

    await services.db.close();
  });
}
