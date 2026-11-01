import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:uuid/uuid.dart';

import '../api/api_client.dart';
import '../api/contract.g.dart';
import 'pin_lock.dart';
import 'secure_store.dart';

/// Lo que el backend sabe del usuario (`GET /auth/me`).
class SessionUser {
  const SessionUser({
    required this.id,
    required this.name,
    required this.email,
    required this.roles,
    required this.permissions,
    required this.agencies,
    this.employeeId,
    this.employeeAgencyId,
  });

  factory SessionUser.fromJson(Map<String, dynamic> json) {
    final user = (json['user'] as Map).cast<String, dynamic>();

    return SessionUser(
      id: user['id'] as int,
      name: user['name'] as String,
      email: user['email'] as String,
      roles: (json['roles'] as List? ?? const []).cast<String>(),
      permissions: (json['permissions'] as List? ?? const []).cast<String>(),
      agencies: (json['agencies'] as List? ?? const []).cast<int>(),
      employeeId: json['employee_id'] as int?,
      employeeAgencyId: json['employee_agency_id'] as int?,
    );
  }

  final int id;
  final String name;
  final String email;
  final List<String> roles;
  final List<String> permissions;
  final List<int> agencies;
  final int? employeeId;
  final int? employeeAgencyId;

  bool can(String permission) => permissions.contains(permission);

  Map<String, dynamic> toJson() => {
    'user': {'id': id, 'name': name, 'email': email},
    'roles': roles,
    'permissions': permissions,
    'agencies': agencies,
    'employee_id': employeeId,
    'employee_agency_id': employeeAgencyId,
  };
}

enum SessionStatus {
  /// Sin sesión.
  signedOut,

  /// Con sesión, pendiente de crear el PIN.
  needsPin,

  /// Con sesión y PIN: hay que desbloquear.
  locked,

  unlocked,
}

/// Ciclo de sesión. El perfil se guarda en el almacén seguro para abrir sin red; la
/// sesión solo se cierra si el servidor lo dice, nunca por falta de conexión.
class SessionController {
  SessionController({
    required SecureStore store,
    required PinLock pin,
    required ApiClient Function() api,
    required this.deviceName,
    required this.appVersion,
    Uuid? uuid,
  }) : _store = store,
       _pin = pin,
       _api = api,
       _uuid = uuid ?? const Uuid();

  static const _profileKey = 'auth.profile';

  final SecureStore _store;
  final PinLock _pin;
  final ApiClient Function() _api;
  final String deviceName;
  final String appVersion;
  final Uuid _uuid;

  final _status = StreamController<SessionStatus>.broadcast();

  SessionStatus current = SessionStatus.signedOut;
  SessionUser? user;

  Stream<SessionStatus> get changes => _status.stream;

  Future<String?> token() => _store.read(SecureKeys.token);

  Future<SessionStatus> restore() async {
    final stored = await token();

    if (stored == null) {
      return _emit(SessionStatus.signedOut);
    }

    final profile = await _store.read(_profileKey);

    if (profile != null) {
      user = SessionUser.fromJson((jsonDecode(profile) as Map).cast<String, dynamic>());
    }

    return _emit(await _pin.isConfigured() ? SessionStatus.locked : SessionStatus.needsPin);
  }

  Future<void> signIn(String email, String password) async {
    final response = await _api().post(
      ApiPaths.authToken,
      body: {
        'email': email,
        'password': password,
        'device_name': deviceName,
        'platform': 'android',
        'device_uuid': await _deviceUuid(),
        'app_version': appVersion,
      },
    );

    final data = (response['data'] as Map).cast<String, dynamic>();

    await _store.write(SecureKeys.token, data['token'] as String);
    await refreshProfile();
    await _pin.clear();
    _emit(SessionStatus.needsPin);
  }

  /// Sin red conserva el perfil guardado; un 401 cierra la sesión por el interceptor.
  Future<void> refreshProfile() async {
    final response = await _api().get(ApiPaths.authMe);
    final data = (response['data'] as Map).cast<String, dynamic>();

    user = SessionUser.fromJson(data);
    await _store.write(_profileKey, jsonEncode(user!.toJson()));
  }

  Future<void> createPin(String pin) async {
    await _pin.configure(pin);
    _emit(SessionStatus.unlocked);
  }

  Future<bool> unlock(String pin) async {
    final ok = await _pin.verify(pin);

    if (ok) {
      _emit(SessionStatus.unlocked);
    }

    return ok;
  }

  void lock() {
    if (current == SessionStatus.unlocked) {
      _emit(SessionStatus.locked);
    }
  }

  /// El servidor revocó el token. La cola y su base se conservan, para no perder lo
  /// capturado: se envía al volver a iniciar sesión.
  Future<void> expire() async {
    await _store.delete(SecureKeys.token);
    await _pin.clear();
    user = null;
    _emit(SessionStatus.signedOut);
  }

  Future<void> signOut() async {
    try {
      await _api().post(ApiPaths.authLogout);
    } on ApiException {
      // Sin red el token sigue vivo en el servidor, pero el dispositivo lo olvida.
    }

    await expire();
  }

  Future<String> _deviceUuid() async {
    final existing = await _store.read(SecureKeys.deviceUuid);

    if (existing != null) {
      return existing;
    }

    final created = _uuid.v4();
    await _store.write(SecureKeys.deviceUuid, created);

    return created;
  }

  SessionStatus _emit(SessionStatus status) {
    current = status;
    _status.add(status);

    return status;
  }
}

/// Clave de la base cifrada: se genera una vez y solo vive en el almacén seguro.
Future<String> databaseKey(SecureStore store, {Random? random}) async {
  final existing = await store.read(SecureKeys.databaseKey);

  if (existing != null) {
    return existing;
  }

  final source = random ?? Random.secure();
  final key = List.generate(32, (_) => source.nextInt(256).toRadixString(16).padLeft(2, '0')).join();

  await store.write(SecureKeys.databaseKey, key);

  return key;
}
