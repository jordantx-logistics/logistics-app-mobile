import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../api/api_client.dart';
import '../auth/pin_lock.dart';
import '../auth/secure_store.dart';
import '../auth/session.dart';
import '../db/app_database.dart';
import '../sync/cache_store.dart';
import '../sync/op_store.dart';
import '../sync/sync_engine.dart';

/// Origen del API. Sin valor por defecto en release: una app mal compilada no debe
/// hablar con un servidor equivocado.
const apiBaseUrl = String.fromEnvironment('API_BASE_URL');

/// Valida el origen del API. En release solo HTTPS: `dart:io` abre sus propios sockets y
/// no obedece la política de tráfico en claro de Android, así que hay que exigirlo aquí.
String checkApiOrigin(String origin, {required bool release}) {
  if (origin.isEmpty) {
    throw StateError('Build with --dart-define=API_BASE_URL=<https origin>.');
  }

  if (release && !origin.startsWith('https://')) {
    throw StateError('Release builds only talk HTTPS: $origin.');
  }

  return origin;
}

/// Dependencias de una app, creadas una vez al arrancar.
class AppServices {
  AppServices._({
    required this.db,
    required this.api,
    required this.session,
    required this.ops,
    required this.cache,
    required this.engine,
    required this.filesDir,
  });

  final AppDatabase db;
  final ApiClient api;
  final SessionController session;
  final OpStore ops;
  final CacheStore cache;
  final SyncEngine engine;

  /// Donde viven firmas, fotos y comprobantes hasta subirlos.
  final Directory filesDir;

  /// Se ejecuta tras cada pasada, para refrescar lo descargado.
  Future<void> Function()? onPull;

  StreamSubscription<List<ConnectivityResult>>? _connectivity;
  Timer? _timer;

  final online = ValueNotifier<bool>(true);

  static Future<AppServices> create({
    required String appName,
    required String appVersion,
    required List<SyncChannel> Function(ApiClient api, Directory files) channels,
    SecureStore store = const KeystoreSecureStore(),
    String? baseUrl,
  }) async {
    final origin = checkApiOrigin(baseUrl ?? apiBaseUrl, release: kReleaseMode);

    final documents = await getApplicationDocumentsDirectory();
    final files = Directory(p.join(documents.path, 'evidence'))..createSync(recursive: true);
    final db = AppDatabase.encrypted(File(p.join(documents.path, '$appName.sqlite')), await databaseKey(store));

    late final SessionController session;

    final api = ApiClient(
      baseUrl: origin,
      appVersion: appVersion,
      token: () => session.token(),
      onUnauthorized: () => unawaited(session.expire()),
    );

    session = SessionController(
      store: store,
      pin: PinLock(store),
      api: () => api,
      deviceName: appName,
      appVersion: appVersion,
    );

    final ops = OpStore(db);

    return AppServices._(
      db: db,
      api: api,
      session: session,
      ops: ops,
      cache: CacheStore(db),
      engine: SyncEngine(store: ops, channels: channels(api, files)),
      filesDir: files,
    );
  }

  /// Sincroniza al volver la red, y cada minuto por si la red nunca se fue.
  void startBackgroundSync({Duration every = const Duration(minutes: 1)}) {
    _connectivity ??= Connectivity().onConnectivityChanged.listen((results) {
      final connected = results.any((result) => result != ConnectivityResult.none);
      final wasOffline = !online.value;

      online.value = connected;

      if (connected && wasOffline) {
        unawaited(sync(manual: true));
      }
    });

    _timer ??= Timer.periodic(every, (_) => unawaited(sync()));
    unawaited(sync());
  }

  /// Envía la cola y refresca. Nunca lanza: sin red, simplemente queda para luego.
  Future<SyncRunResult> sync({bool manual = false}) async {
    if (session.current != SessionStatus.unlocked) {
      return SyncRunResult.idle;
    }

    final result = manual ? await engine.retryNow() : await engine.syncNow();

    if (result != SyncRunResult.unauthorized && result != SyncRunResult.retryLater) {
      try {
        await onPull?.call();
        await ops.purgeSynced(const Duration(days: 7));
      } on ApiException {
        // Sin red se opera con la copia local.
      }
    }

    return result;
  }

  void stopBackgroundSync() {
    unawaited(_connectivity?.cancel());
    _connectivity = null;
    _timer?.cancel();
    _timer = null;
  }
}
