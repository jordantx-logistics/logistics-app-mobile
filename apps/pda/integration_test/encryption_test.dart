import 'dart:io';

import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:logistics_core/logistics_core.dart';
import 'package:path_provider/path_provider.dart';

/// La base local debe quedar cifrada en el dispositivo real, no solo en el host.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const key = '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';

  testWidgets('el token y la clave se guardan en el Keystore real', (tester) async {
    const store = KeystoreSecureStore();
    const name = 'integration.test';

    await store.write(name, 'secret');
    expect(await store.read(name), 'secret');

    await store.delete(name);
    expect(await store.read(name), isNull);

    final generated = await databaseKey(store);

    expect(generated, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(await databaseKey(store), generated);
  });

  testWidgets('la base queda cifrada y no se abre sin la clave', (tester) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/encryption_test.sqlite');

    if (file.existsSync()) {
      file.deleteSync();
    }

    final db = AppDatabase.encrypted(file, key);
    final store = OpStore(db);
    const secret = 'DESTINATARIO-SECRETO-12345678';
    final id = await store.enqueue(kind: 'scan', entityKey: 'a', payload: {'recipient': secret});
    final cipher = await db.customSelect('PRAGMA cipher_version;').getSingle();
    await db.close();

    expect(cipher.data.values.first.toString(), isNotEmpty);

    final bytes = file.readAsBytesSync();
    final content = String.fromCharCodes(bytes);

    expect(content.startsWith('SQLite format 3'), isFalse, reason: 'cabecera en claro');
    expect(content.contains(secret), isFalse, reason: 'dato personal en claro');

    final reopened = AppDatabase.encrypted(file, key);
    expect((await OpStore(reopened).find(id))!.payload['recipient'], secret);
    await reopened.close();

    const otherKey = 'ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100';
    final wrong = AppDatabase.encrypted(file, otherKey);
    await expectLater(
      wrong.customSelect('SELECT count(*) FROM pending_ops', variables: const <Variable<Object>>[]).get(),
      throwsA(anything),
    );
    await wrong.close().catchError((_) {});
  });
}
