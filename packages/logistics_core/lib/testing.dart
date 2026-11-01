/// Ayudas para los tests de integración de las apps, contra el stack aislado del backend.
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'logistics_core.dart';

/// Contraseña de prueba de `E2eSeeder`: solo existe en el stack aislado.
const e2ePassword = 'E2e-Password-2026!';

/// Origen que no responde: simula el corte de red sin depender del emulador.
const offlineOrigin = 'http://10.0.2.2:9';

/// Almacén en memoria: cada test empieza sin sesión, sin tocar el Keystore del equipo.
class MemorySecureStore implements SecureStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// Servicios con base y almacén propios, ya autenticados y desbloqueados.
Future<AppServices> signedInServices({
  required String role,
  required List<SyncChannel> Function(ApiClient api, Directory files) channels,
}) async {
  final services = await AppServices.create(
    appName: 'test_${const Uuid().v4()}',
    appVersion: 'test',
    channels: channels,
    store: MemorySecureStore(),
  );

  await services.session.signIn('e2e.$role@logistics.test', e2ePassword);
  await services.session.createPin('4821');

  return services;
}

/// Cliente de otro origen con el token de la misma sesión: el motor offline del test.
ApiClient offlineClient(AppServices services) =>
    ApiClient(baseUrl: offlineOrigin, appVersion: 'test', token: services.session.token);

/// Motor sobre la misma cola, con otros canales.
SyncEngine engineOver(AppServices services, List<SyncChannel> channels) => SyncEngine(
  store: services.ops,
  channels: channels,
  backoff: const BackoffPolicy(base: Duration(milliseconds: 1), cap: Duration(milliseconds: 1)),
);

/// Crea un archivo de evidencia mínimo en el directorio de la app.
Future<String> evidenceFile(String name) async {
  final dir = await getTemporaryDirectory();
  final file = File('${dir.path}/${const Uuid().v4()}-$name');

  // PNG de 1×1: basta para pasar la validación de imagen del backend.
  await file.writeAsBytes(const <int>[
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
    0x00,
    0x00,
    0x00,
    0x0D,
    0x49,
    0x48,
    0x44,
    0x52,
    0x00,
    0x00,
    0x00,
    0x01,
    0x00,
    0x00,
    0x00,
    0x01,
    0x08,
    0x06,
    0x00,
    0x00,
    0x00,
    0x1F,
    0x15,
    0xC4,
    0x89,
    0x00,
    0x00,
    0x00,
    0x0D,
    0x49,
    0x44,
    0x41,
    0x54,
    0x78,
    0x9C,
    0x63,
    0xF8,
    0xCF,
    0xC0,
    0xF0,
    0x1F,
    0x00,
    0x05,
    0x00,
    0x01,
    0xFF,
    0x89,
    0x99,
    0x3D,
    0x1D,
    0x00,
    0x00,
    0x00,
    0x00,
    0x49,
    0x45,
    0x4E,
    0x44,
    0xAE,
    0x42,
    0x60,
    0x82,
  ]);

  return file.path;
}

/// Percentil de una lista de duraciones.
Duration percentile(List<Duration> values, double p) {
  final sorted = [...values]..sort();

  return sorted[((sorted.length - 1) * p).round()];
}
