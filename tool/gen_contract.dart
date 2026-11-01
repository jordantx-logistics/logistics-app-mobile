// Genera `packages/logistics_core/lib/src/api/contract.g.dart` desde el contrato
// versionado del backend (ADR-0008).
//
//   dart run tool/gen_contract.dart           # regenera
//   dart run tool/gen_contract.dart --check   # falla si hay deriva
//
// `CONTRACT_PATH` apunta a otro `openapi.yaml`; por defecto, el del repo hermano.
//
// Genera rutas, no modelos: Scribe no emite `required`, así que unos modelos generados
// tendrían todos los campos opcionales y no protegerían de nada. Lo que sí protege es
// que una ruta retirada del backend deje de compilar en las apps.
import 'dart:io';

import 'package:yaml/yaml.dart';

const _output = 'packages/logistics_core/lib/src/api/contract.g.dart';

/// Lo que consumen las apps. Una ruta aquí que no esté en el contrato hace fallar el
/// generador: es la señal de que el backend cambió.
const _operations = <String, String>{
  'authToken': 'POST /api/v1/auth/token',
  'authMe': 'GET /api/v1/auth/me',
  'authLogout': 'POST /api/v1/auth/logout',
  'scansSync': 'POST /api/v1/operations/scans/sync',
  'embarks': 'GET /api/v1/operations/embarks',
  'shipments': 'GET /api/v1/operations/shipments',
  'inventoryCounts': 'POST /api/v1/operations/inventory-counts',
  'routeSheet': 'GET /api/v1/operations/deliveries/route-sheet',
  'deliveriesBatch': 'POST /api/v1/operations/deliveries/batch',
  'deliveryEvidence': 'POST /api/v1/operations/deliveries/{delivery}/evidence',
  'fleetRoutes': 'GET /api/v1/fleet/routes',
  'fleetRoute': 'GET /api/v1/fleet/routes/{route}',
  'fleetSync': 'POST /api/v1/fleet/sync',
  'fleetExpenses': 'POST /api/v1/fleet/expenses',
  'fleetMileage': 'POST /api/v1/fleet/routes/{route}/mileage',
  'attendanceMine': 'GET /api/v1/identity/attendance/mine',
  'attendance': 'POST /api/v1/identity/attendance',
};

void main(List<String> args) {
  final contractPath =
      Platform.environment['CONTRACT_PATH'] ?? '../logistics-app-backend/openapi/openapi.yaml';
  final contract = loadYaml(File(contractPath).readAsStringSync()) as YamlMap;
  final paths = contract['paths'] as YamlMap;

  final buffer = StringBuffer()
    ..writeln('// GENERADO por tool/gen_contract.dart desde openapi/openapi.yaml. No editar.')
    ..writeln()
    ..writeln('abstract final class ApiPaths {');

  for (final operation in _operations.entries) {
    final [method, path] = operation.value.split(' ');
    final declared = paths[path] as YamlMap?;

    if (declared == null || !declared.containsKey(method.toLowerCase())) {
      stderr.writeln('Contract drift: ${operation.value} is not in $contractPath.');
      exit(1);
    }

    final parameters = RegExp(r'\{(\w+)\}').allMatches(path).map((match) => match[1]!).toList();

    if (parameters.isEmpty) {
      buffer.writeln("  static const ${operation.key} = '$path';");
    } else {
      final signature = parameters.map((name) => 'Object $name').join(', ');
      final body = path.replaceAllMapped(RegExp(r'\{(\w+)\}'), (match) => '\$${match[1]}');

      buffer.writeln("  static String ${operation.key}($signature) => '$body';");
    }
  }

  buffer.writeln('}');

  final file = File(_output);
  final generated = buffer.toString();

  if (args.contains('--check')) {
    if (!file.existsSync() || file.readAsStringSync().replaceAll('\r\n', '\n') != generated) {
      stderr.writeln('Contract drift: run `dart run tool/gen_contract.dart` and commit the result.');
      exit(1);
    }

    stdout.writeln('Contract OK.');

    return;
  }

  file.writeAsStringSync(generated);
  stdout.writeln('Generated $_output.');
}
