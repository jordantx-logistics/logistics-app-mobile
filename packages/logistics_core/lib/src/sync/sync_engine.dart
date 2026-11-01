import 'dart:async';
import 'dart:math';

import 'op_store.dart';

/// Resultado de una operación según el servidor.
enum OpOutcome { accepted, duplicated, rejected }

class OpResult {
  const OpResult(this.opId, this.outcome, {this.errorCode, this.message});

  final String opId;
  final OpOutcome outcome;
  final String? errorCode;
  final String? message;
}

/// La red o el servidor fallaron: nada se puede afirmar y se reintenta.
class SyncRetryableException implements Exception {
  const SyncRetryableException(this.message);

  final String message;

  @override
  String toString() => 'SyncRetryableException: $message';
}

/// La sesión caducó o se revocó: se detiene sin perder nada.
class SyncUnauthorizedException implements Exception {
  const SyncUnauthorizedException();
}

/// Envía las operaciones de un tipo. Cada app registra los suyos.
abstract class SyncChannel {
  /// Valores de `kind` que atiende.
  Set<String> get kinds;

  /// Máximo por envío. Lo que lleva archivos se envía de uno en uno.
  int get batchSize;

  /// Devuelve un resultado por operación. Lanza [SyncRetryableException] si no hay
  /// respuesta fiable, o [SyncUnauthorizedException] si la sesión ya no vale.
  Future<List<OpResult>> send(List<LocalOp> ops);
}

/// Espera antes de reintentar: exponencial, con tope y con desfase aleatorio para que
/// muchos dispositivos no reintenten a la vez al volver la señal.
class BackoffPolicy {
  const BackoffPolicy({
    this.base = const Duration(seconds: 5),
    this.cap = const Duration(minutes: 10),
    this.jitter = 0.2,
  });

  final Duration base;
  final Duration cap;
  final double jitter;

  Duration delay(int attempts, Random random) {
    final exponent = min(attempts, 16);
    final raw = base.inMilliseconds * pow(2, exponent);
    final capped = min(raw.toDouble(), cap.inMilliseconds.toDouble());
    final spread = capped * jitter * (random.nextDouble() * 2 - 1);

    return Duration(milliseconds: (capped + spread).round());
  }
}

enum SyncRunResult { idle, completed, retryLater, unauthorized }

/// Vacía la cola: toma lo que puede salir, lo agrupa por canal y aplica cada resultado.
class SyncEngine {
  SyncEngine({
    required OpStore store,
    required List<SyncChannel> channels,
    BackoffPolicy backoff = const BackoffPolicy(),
    Random? random,
    DateTime Function()? clock,
  }) : _store = store,
       _channels = {
         for (final channel in channels)
           for (final kind in channel.kinds) kind: channel,
       },
       _backoff = backoff,
       _random = random ?? Random(),
       _clock = clock ?? DateTime.now;

  final OpStore _store;
  final Map<String, SyncChannel> _channels;
  final BackoffPolicy _backoff;
  final Random _random;
  final DateTime Function() _clock;

  Future<SyncRunResult>? _running;

  /// Dos disparos a la vez (red que vuelve y temporizador) comparten la misma pasada.
  Future<SyncRunResult> syncNow() => _running ??= _run().whenComplete(() => _running = null);

  /// Reintento manual, o vuelta de la red: no espera a que venza el desfase.
  Future<SyncRunResult> retryNow() async {
    await _store.clearBackoff();

    return syncNow();
  }

  Future<SyncRunResult> _run() async {
    var result = SyncRunResult.idle;

    while (true) {
      final ready = await _store.nextBatch();

      if (ready.isEmpty) {
        return result;
      }

      result = SyncRunResult.completed;

      final outcome = await _sendFirstGroup(ready);

      if (outcome != SyncRunResult.completed) {
        return outcome;
      }
    }
  }

  /// Envía el primer tramo consecutivo de un mismo canal, para respetar el orden global.
  Future<SyncRunResult> _sendFirstGroup(List<LocalOp> ready) async {
    final first = ready.first;
    final channel = _channels[first.kind];

    if (channel == null) {
      await _store.markConflict(first.id, 'SYNC_NO_CHANNEL', 'No channel handles ${first.kind}.');

      return SyncRunResult.completed;
    }

    final group = <LocalOp>[];

    for (final op in ready) {
      if (!channel.kinds.contains(op.kind) || group.length == channel.batchSize) {
        break;
      }

      group.add(op);
    }

    try {
      final results = await channel.send(group);
      final byId = {for (final result in results) result.opId: result};

      for (final op in group) {
        final result = byId[op.id];

        if (result == null) {
          // Respuesta incompleta: no se puede afirmar nada de esta operación.
          await _scheduleRetry(op, 'The server did not report this operation.');
        } else if (result.outcome == OpOutcome.rejected) {
          await _store.markConflict(op.id, result.errorCode, result.message);
        } else {
          await _store.markSynced(op.id);
        }
      }

      return SyncRunResult.completed;
    } on SyncUnauthorizedException {
      return SyncRunResult.unauthorized;
    } on SyncRetryableException catch (error) {
      for (final op in group) {
        await _scheduleRetry(op, error.message);
      }

      return SyncRunResult.retryLater;
    }
  }

  Future<void> _scheduleRetry(LocalOp op, String message) {
    final wait = _backoff.delay(op.attempts, _random);

    return _store.markRetry(op.id, _clock().add(wait), message);
  }
}
