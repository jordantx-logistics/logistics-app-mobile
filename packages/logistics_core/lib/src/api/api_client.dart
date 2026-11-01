import 'package:dio/dio.dart';

/// Error del API ya normalizado: las apps no ven `DioException`.
class ApiException implements Exception {
  const ApiException({required this.message, this.statusCode, this.errorCode, this.fieldErrors = const {}});

  final String message;
  final int? statusCode;
  final String? errorCode;
  final Map<String, List<String>> fieldErrors;

  /// Sin respuesta del servidor.
  bool get isNetwork => statusCode == null;

  bool get isUnauthorized => statusCode == 401;

  bool get isValidation => statusCode == 422 && errorCode == null;

  /// Rechazo definitivo: reintentar daría lo mismo.
  bool get isRejection =>
      statusCode != null &&
      statusCode! >= 400 &&
      statusCode! < 500 &&
      !isUnauthorized &&
      statusCode != 408 &&
      statusCode != 429;

  /// Sin red, o el servidor falló: vale la pena reintentar.
  bool get isRetryable => !isRejection && !isUnauthorized;

  @override
  String toString() => 'ApiException($statusCode, $errorCode): $message';
}

/// Único punto de salida a la red de las apps.
class ApiClient {
  ApiClient({
    required String baseUrl,
    required Future<String?> Function() token,
    required String appVersion,
    Dio? dio,
    void Function()? onUnauthorized,
  }) : _dio = dio ?? Dio(),
       _onUnauthorized = onUnauthorized {
    _dio.options
      ..baseUrl = baseUrl
      ..connectTimeout = const Duration(seconds: 15)
      ..receiveTimeout = const Duration(seconds: 60)
      ..sendTimeout = const Duration(seconds: 60)
      ..headers = {'Accept': 'application/json', 'X-App-Version': appVersion};

    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          final value = await token();

          if (value != null) {
            options.headers['Authorization'] = 'Bearer $value';
          }

          handler.next(options);
        },
      ),
    );
  }

  final Dio _dio;
  final void Function()? _onUnauthorized;

  Future<Map<String, dynamic>> get(String path, {Map<String, dynamic>? query}) {
    return _send(() => _dio.get<dynamic>(path, queryParameters: query));
  }

  Future<Map<String, dynamic>> post(String path, {Map<String, dynamic>? body}) {
    return _send(() => _dio.post<dynamic>(path, data: body));
  }

  /// Multipart. `files` es nombre de campo → ruta local; se lee en cada intento.
  Future<Map<String, dynamic>> upload(
    String path, {
    Map<String, dynamic> fields = const {},
    required Map<String, String> files,
  }) async {
    return _send(() async {
      final form = FormData.fromMap({
        ...fields,
        for (final file in files.entries) file.key: await MultipartFile.fromFile(file.value),
      });

      return _dio.post<dynamic>(path, data: form);
    });
  }

  Future<Map<String, dynamic>> _send(Future<Response<dynamic>> Function() request) async {
    try {
      final response = await request();
      final data = response.data;

      return data is Map ? data.cast<String, dynamic>() : <String, dynamic>{};
    } on DioException catch (error) {
      final exception = _normalize(error);

      if (exception.isUnauthorized) {
        _onUnauthorized?.call();
      }

      throw exception;
    }
  }

  ApiException _normalize(DioException error) {
    final response = error.response;

    if (response == null) {
      return const ApiException(message: 'No connection to the server.');
    }

    final body = response.data;
    final map = body is Map ? body : const {};
    final data = map['data'];

    return ApiException(
      message: map['message']?.toString() ?? 'The server could not process the request.',
      statusCode: response.statusCode,
      errorCode: data is Map ? data['error_code']?.toString() : null,
      fieldErrors: _fieldErrors(map['errors'] ?? (data is Map ? data['errors'] : null)),
    );
  }

  Map<String, List<String>> _fieldErrors(Object? errors) {
    if (errors is! Map) {
      return const {};
    }

    return {
      for (final entry in errors.entries)
        entry.key.toString(): entry.value is List
            ? (entry.value as List).map((item) => item.toString()).toList()
            : [entry.value.toString()],
    };
  }
}
