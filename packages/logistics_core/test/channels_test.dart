import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logistics_core/logistics_core.dart';

/// Responde lo que diga el test, sin red.
class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this.handler);

  final Future<ResponseBody> Function(RequestOptions options) handler;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<List<int>>? requestStream, Future<void>? cancelFuture) {
    requests.add(options);

    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody jsonBody(int status, String body) => ResponseBody.fromString(
  body,
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

LocalOp op(String id, {Map<String, dynamic> payload = const {'a': 1}}) => LocalOp(
  id: id,
  kind: 'scan',
  entityKey: id,
  payload: payload,
  files: const {},
  status: OpStatus.pending,
  attempts: 0,
  createdAt: DateTime.utc(2026),
);

void main() {
  late FakeAdapter adapter;
  var unauthorized = 0;

  ApiClient client(Future<ResponseBody> Function(RequestOptions) handler, {String? token = 'abc'}) {
    adapter = FakeAdapter(handler);
    unauthorized = 0;

    return ApiClient(
      baseUrl: 'https://api.test',
      appVersion: '1.2.3',
      token: () async => token,
      dio: Dio()..httpClientAdapter = adapter,
      onUnauthorized: () => unauthorized++,
    );
  }

  group('checkApiOrigin', () {
    test('en release solo admite HTTPS', () {
      expect(checkApiOrigin('https://api.test', release: true), 'https://api.test');
      expect(() => checkApiOrigin('http://api.test', release: true), throwsStateError);
    });

    test('en depuración admite el backend local', () {
      expect(checkApiOrigin('http://10.0.2.2:8100', release: false), 'http://10.0.2.2:8100');
    });

    test('exige un origen en cualquier modo', () {
      expect(() => checkApiOrigin('', release: false), throwsStateError);
    });
  });

  group('ApiClient', () {
    test('envía el token y la versión de la app', () async {
      final api = client((_) async => jsonBody(200, '{"data":{"ok":true}}'));

      final response = await api.get('/x');

      expect(response['data'], {'ok': true});
      expect(adapter.requests.single.headers['Authorization'], 'Bearer abc');
      expect(adapter.requests.single.headers['X-App-Version'], '1.2.3');
    });

    test('sin token no manda cabecera de autorización', () async {
      final api = client((_) async => jsonBody(200, '{}'), token: null);

      await api.get('/x');

      expect(adapter.requests.single.headers.containsKey('Authorization'), isFalse);
    });

    test('normaliza un rechazo de negocio', () async {
      final api = client((_) async => jsonBody(422, '{"message":"Nope","data":{"error_code":"RULE"}}'));

      await expectLater(
        api.post('/x'),
        throwsA(
          isA<ApiException>()
              .having((error) => error.errorCode, 'code', 'RULE')
              .having((error) => error.message, 'message', 'Nope')
              .having((error) => error.isRejection, 'rejection', isTrue)
              .having((error) => error.isRetryable, 'retryable', isFalse)
              .having((error) => error.isValidation, 'validation', isFalse),
        ),
      );
    });

    test('normaliza errores de validación por campo', () async {
      final api = client((_) async => jsonBody(422, '{"message":"Invalid","errors":{"email":["Required"]}}'));

      await expectLater(
        api.post('/x'),
        throwsA(
          isA<ApiException>().having((error) => error.isValidation, 'validation', isTrue).having(
            (error) => error.fieldErrors['email'],
            'field',
            ['Required'],
          ),
        ),
      );
    });

    test('un 401 avisa para cerrar la sesión', () async {
      final api = client((_) async => jsonBody(401, '{"message":"Unauthenticated."}'));

      await expectLater(
        api.get('/x'),
        throwsA(isA<ApiException>().having((error) => error.isUnauthorized, 'unauthorized', isTrue)),
      );
      expect(unauthorized, 1);
    });

    test('un 500, un 429 y la falta de red se pueden reintentar', () async {
      for (final status in [500, 429, 408]) {
        final api = client((_) async => jsonBody(status, '{"message":"x"}'));

        await expectLater(
          api.get('/x'),
          throwsA(isA<ApiException>().having((error) => error.isRetryable, 'retryable $status', isTrue)),
        );
      }

      final offline = client((options) async {
        throw DioException.connectionError(requestOptions: options, reason: 'down');
      });

      await expectLater(
        offline.get('/x'),
        throwsA(
          isA<ApiException>()
              .having((error) => error.isNetwork, 'network', isTrue)
              .having((error) => error.isRetryable, 'retryable', isTrue),
        ),
      );
    });

    test('un cuerpo que no es JSON no rompe', () async {
      final api = client((_) async => ResponseBody.fromString('<html>', 200));

      expect(await api.get('/x'), isEmpty);
    });
  });

  group('JsonBatchChannel', () {
    JsonBatchChannel channel(ApiClient api) => JsonBatchChannel(
      api: api,
      path: '/scans',
      kinds: const {'scan'},
      collectionKey: 'scans',
      idKey: 'scan_id',
      batchSize: 2,
    );

    test('envía el id de la operación y traduce cada resultado', () async {
      final api = client(
        (_) async => jsonBody(
          200,
          '{"data":{"items":['
          '{"scan_id":"a","status":"accepted"},'
          '{"scan_id":"b","status":"duplicated"},'
          '{"scan_id":"c","status":"rejected","error_code":"RULE","message":"No"}'
          ']}}',
        ),
      );

      final results = await channel(api).send([op('a'), op('b'), op('c')]);

      expect((adapter.requests.single.data as Map)['scans'][0], {'a': 1, 'scan_id': 'a'});
      expect(results.map((result) => result.outcome), [OpOutcome.accepted, OpOutcome.duplicated, OpOutcome.rejected]);
      expect(results.last.errorCode, 'RULE');
      expect(results.last.message, 'No');
    });

    test('la falta de red pide reintentar', () async {
      final api = client((options) async {
        throw DioException.connectionError(requestOptions: options, reason: 'down');
      });

      await expectLater(channel(api).send([op('a')]), throwsA(isA<SyncRetryableException>()));
    });

    test('una sesión revocada detiene el envío', () async {
      final api = client((_) async => jsonBody(401, '{}'));

      await expectLater(channel(api).send([op('a')]), throwsA(isA<SyncUnauthorizedException>()));
    });

    test('un rechazo de todo el lote se reporta operación a operación', () async {
      final api = client((_) async => jsonBody(403, '{"message":"Forbidden"}'));

      final results = await channel(api).send([op('a'), op('b')]);

      expect(results.map((result) => result.outcome), [OpOutcome.rejected, OpOutcome.rejected]);
      expect(results.first.errorCode, 'HTTP_403');
    });

    test('una respuesta inesperada no se da por buena', () async {
      final api = client((_) async => jsonBody(200, '{"data":{}}'));

      await expectLater(channel(api).send([op('a')]), throwsA(isA<SyncRetryableException>()));
    });
  });

  group('CacheStore', () {
    late AppDatabase db;
    late CacheStore cache;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      cache = CacheStore(db, clock: () => DateTime.utc(2026));
    });

    tearDown(() => db.close());

    test('guarda, lee y borra', () async {
      await cache.put('routes', '1', {'id': 1});

      expect(await cache.get('routes', '1'), {'id': 1});
      expect(await cache.get('routes', '2'), isNull);

      await cache.remove('routes', '1');

      expect(await cache.get('routes', '1'), isNull);
    });

    test('sustituir retira lo que ya no está y no toca otras colecciones', () async {
      await cache.put('routes', '1', {'id': 1});
      await cache.put('stops', '9', {'id': 9});

      await cache.replaceAll('routes', {
        '2': {'id': 2},
      });

      expect(await cache.all('routes'), [
        {'id': 2},
      ]);
      expect((await cache.all('stops')).length, 1);
      expect((await cache.watchAll('routes').first).single['id'], 2);
    });

    test('recuerda el cursor', () async {
      expect(await cache.cursor('routes'), isNull);

      await cache.setCursor('routes', DateTime.utc(2026, 1, 2));

      // Drift devuelve hora local: lo que importa es el instante.
      expect((await cache.cursor('routes'))!.toUtc(), DateTime.utc(2026, 1, 2));
    });
  });

  group('OpStore', () {
    late AppDatabase db;
    late OpStore store;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      store = OpStore(db, clock: () => DateTime.utc(2026));
    });

    tearDown(() => db.close());

    test('observa por estado y por tipo', () async {
      await store.enqueue(kind: 'scan', entityKey: 'a', payload: {});
      await store.enqueue(kind: 'fleet', entityKey: 'b', payload: {});

      expect((await store.watch([OpStatus.pending], kind: 'scan').first).length, 1);
      expect((await store.all([OpStatus.pending], kind: 'fleet')).length, 1);
      expect((await store.watch([OpStatus.pending]).first).length, 2);
    });

    test('acepta un id propio', () async {
      final id = await store.enqueue(kind: 'scan', entityKey: 'a', payload: {}, id: 'fixed');

      expect(id, 'fixed');
      expect(await store.find('fixed'), isNotNull);
    });
  });
}
