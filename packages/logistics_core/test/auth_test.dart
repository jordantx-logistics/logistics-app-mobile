import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:logistics_core/src/auth/pin_lock.dart';
import 'package:logistics_core/src/auth/secure_store.dart';
import 'package:logistics_core/src/auth/session.dart';

class MemoryStore implements SecureStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

void main() {
  late MemoryStore store;
  late DateTime now;
  late PinLock pin;

  setUp(() {
    store = MemoryStore();
    now = DateTime(2026, 11, 1, 12);
    pin = PinLock(store, random: Random(1), clock: () => now);
  });

  group('PinLock', () {
    test('nunca guarda el PIN en claro', () async {
      await pin.configure('4821');

      expect(store.values.values, isNot(contains('4821')));
      expect(await pin.isConfigured(), isTrue);
    });

    test('acepta el PIN correcto y rechaza otro', () async {
      await pin.configure('4821');

      expect(await pin.verify('0000'), isFalse);
      expect(await pin.verify('4821'), isTrue);
    });

    test('rechaza un PIN corto o no numérico', () async {
      await expectLater(pin.configure('12'), throwsArgumentError);
      await expectLater(pin.configure('abcd'), throwsArgumentError);
    });

    test('bloquea tras 5 fallos, incluso con el PIN correcto', () async {
      await pin.configure('4821');

      for (var i = 0; i < PinLock.maxAttempts; i++) {
        expect(await pin.verify('0000'), isFalse);
      }

      expect(await pin.lockedUntil(), isNotNull);
      expect(await pin.verify('4821'), isFalse);

      now = now.add(PinLock.lockout + const Duration(seconds: 1));

      expect(await pin.lockedUntil(), isNull);
      expect(await pin.verify('4821'), isTrue);
    });

    test('el bloqueo sobrevive a reiniciar la app', () async {
      await pin.configure('4821');

      for (var i = 0; i < PinLock.maxAttempts; i++) {
        await pin.verify('0000');
      }

      final reopened = PinLock(store, clock: () => now);

      expect(await reopened.verify('4821'), isFalse);
    });

    test('acertar reinicia los fallos', () async {
      await pin.configure('4821');
      await pin.verify('0000');
      await pin.verify('4821');

      for (var i = 0; i < PinLock.maxAttempts - 1; i++) {
        await pin.verify('0000');
      }

      expect(await pin.lockedUntil(), isNull);
    });

    test('sin configurar no valida nada', () async {
      expect(await pin.isConfigured(), isFalse);
      expect(await pin.verify('4821'), isFalse);
    });
  });

  group('databaseKey', () {
    test('se genera una vez y es hexadecimal de 256 bits', () async {
      final key = await databaseKey(store, random: Random(1));

      expect(key, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(await databaseKey(store), key);
    });
  });

  group('SessionUser', () {
    test('lee el perfil y conserva los permisos al serializar', () {
      final user = SessionUser.fromJson({
        'user': {'id': 1, 'name': 'Ana', 'email': 'a@b.c'},
        'roles': ['courier'],
        'permissions': ['delivery.execute'],
        'agencies': [3],
        'employee_id': 9,
        'employee_agency_id': 3,
      });

      expect(user.can('delivery.execute'), isTrue);
      expect(user.can('orders.view'), isFalse);
      expect(SessionUser.fromJson(user.toJson()).employeeId, 9);
    });
  });
}
