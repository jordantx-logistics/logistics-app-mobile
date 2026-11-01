import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'secure_store.dart';

/// PIN local para reabrir la app. No sustituye a la sesión: protege un equipo
/// desbloqueado que cambia de manos. El PIN nunca se guarda, solo su derivación.
class PinLock {
  PinLock(this._store, {Random? random, DateTime Function()? clock})
    : _random = random ?? Random.secure(),
      _clock = clock ?? DateTime.now;

  static const minLength = 4;
  static const maxAttempts = 5;
  static const lockout = Duration(minutes: 1);
  static const _iterations = 20000;

  final SecureStore _store;
  final Random _random;
  final DateTime Function() _clock;

  Future<bool> isConfigured() async => await _store.read(SecureKeys.pinHash) != null;

  Future<void> configure(String pin) async {
    if (pin.length < minLength || int.tryParse(pin) == null) {
      throw ArgumentError('The PIN must have at least $minLength digits.');
    }

    final salt = base64Encode(List<int>.generate(16, (_) => _random.nextInt(256)));

    await _store.write(SecureKeys.pinSalt, salt);
    await _store.write(SecureKeys.pinHash, _derive(pin, salt));
    await _store.delete(SecureKeys.pinFailures);
    await _store.delete(SecureKeys.pinLockedUntil);
  }

  /// Hasta cuándo está bloqueado por demasiados intentos, si lo está.
  Future<DateTime?> lockedUntil() async {
    final raw = await _store.read(SecureKeys.pinLockedUntil);
    final until = raw == null ? null : DateTime.tryParse(raw);

    return until != null && until.isAfter(_clock()) ? until : null;
  }

  /// Comprueba el PIN. Los fallos y el bloqueo persisten: reiniciar la app no los borra.
  Future<bool> verify(String pin) async {
    if (await lockedUntil() != null) {
      return false;
    }

    final salt = await _store.read(SecureKeys.pinSalt);
    final hash = await _store.read(SecureKeys.pinHash);

    if (salt == null || hash == null) {
      return false;
    }

    if (_constantTimeEquals(_derive(pin, salt), hash)) {
      await _store.delete(SecureKeys.pinFailures);
      await _store.delete(SecureKeys.pinLockedUntil);

      return true;
    }

    final failures = int.parse(await _store.read(SecureKeys.pinFailures) ?? '0') + 1;

    if (failures >= maxAttempts) {
      await _store.write(SecureKeys.pinLockedUntil, _clock().add(lockout).toIso8601String());
      await _store.delete(SecureKeys.pinFailures);
    } else {
      await _store.write(SecureKeys.pinFailures, '$failures');
    }

    return false;
  }

  Future<void> clear() async {
    await _store.delete(SecureKeys.pinHash);
    await _store.delete(SecureKeys.pinSalt);
    await _store.delete(SecureKeys.pinFailures);
    await _store.delete(SecureKeys.pinLockedUntil);
  }

  String _derive(String pin, String salt) {
    var digest = sha256.convert(utf8.encode('$salt:$pin')).bytes;

    for (var i = 0; i < _iterations; i++) {
      digest = sha256.convert([...digest, ...utf8.encode(salt)]).bytes;
    }

    return base64Encode(digest);
  }

  bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) {
      return false;
    }

    var result = 0;

    for (var i = 0; i < a.length; i++) {
      result |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }

    return result == 0;
  }
}
