import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Claves del almacén seguro.
abstract final class SecureKeys {
  static const token = 'auth.token';
  static const deviceUuid = 'auth.device_uuid';
  static const databaseKey = 'db.key';
  static const pinHash = 'pin.hash';
  static const pinSalt = 'pin.salt';
  static const pinFailures = 'pin.failures';
  static const pinLockedUntil = 'pin.locked_until';
}

/// Secretos de la app. En producción, Keystore de Android.
abstract class SecureStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

class KeystoreSecureStore implements SecureStore {
  const KeystoreSecureStore([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}
