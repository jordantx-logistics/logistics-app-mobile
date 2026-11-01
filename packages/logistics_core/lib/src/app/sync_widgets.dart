import 'package:flutter/material.dart';

import '../db/app_database.dart';
import '../sync/op_store.dart';
import 'logistics_app.dart';

/// Indicador de la barra: sin red, pendientes y conflictos. Abre la pantalla de cola.
class SyncBadge extends StatelessWidget {
  const SyncBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);

    return ValueListenableBuilder<bool>(
      valueListenable: services.online,
      builder: (context, online, _) => StreamBuilder<SyncCounts>(
        stream: services.ops.watchCounts(),
        builder: (context, snapshot) {
          final counts = snapshot.data ?? const SyncCounts();
          final attention = counts.conflict > 0;

          return TextButton.icon(
            key: const Key('sync.badge'),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SyncScreen())),
            icon: Icon(
              !online
                  ? Icons.cloud_off
                  : attention
                  ? Icons.warning_amber
                  : counts.pending > 0
                  ? Icons.cloud_upload_outlined
                  : Icons.cloud_done_outlined,
              color: attention ? Theme.of(context).colorScheme.error : null,
            ),
            label: Text(attention ? '${counts.conflict} !' : '${counts.pending}'),
          );
        },
      ),
    );
  }
}

/// Lo pendiente y lo rechazado. Lo sincronizado no aparece: ya es del servidor.
class SyncScreen extends StatelessWidget {
  const SyncScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Synchronization'),
        actions: [
          IconButton(
            key: const Key('sync.retry_all'),
            tooltip: 'Sync now',
            onPressed: () => services.sync(manual: true),
            icon: const Icon(Icons.sync),
          ),
          PopupMenuButton<String>(
            onSelected: (_) => services.session.signOut(),
            itemBuilder: (_) => const [PopupMenuItem(value: 'signout', child: Text('Sign out'))],
          ),
        ],
      ),
      body: StreamBuilder<List<LocalOp>>(
        stream: services.ops.watch([OpStatus.pending, OpStatus.conflict]),
        builder: (context, snapshot) {
          final ops = snapshot.data;

          if (ops == null) {
            return const Center(child: CircularProgressIndicator());
          }

          if (ops.isEmpty) {
            return const Center(child: Text('Everything is synchronized.'));
          }

          return ListView.separated(
            itemCount: ops.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) => _OpTile(op: ops[index]),
          );
        },
      ),
    );
  }
}

class _OpTile extends StatelessWidget {
  const _OpTile({required this.op});

  final LocalOp op;

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final conflict = op.status == OpStatus.conflict;

    return ListTile(
      leading: Icon(
        conflict ? Icons.error_outline : Icons.schedule,
        color: conflict ? Theme.of(context).colorScheme.error : null,
      ),
      title: Text(op.entityKey),
      subtitle: Text(
        conflict
            ? '${op.errorMessage ?? 'Rejected by the server'} (${op.errorCode ?? 'error'})'
            : op.attempts == 0
            ? 'Waiting to send'
            : 'Retrying, ${op.attempts} attempts',
      ),
      trailing: conflict
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Try again',
                  onPressed: () async {
                    await services.ops.retry(op.id);
                    await services.sync(manual: true);
                  },
                  icon: const Icon(Icons.refresh),
                ),
                IconButton(
                  key: Key('sync.discard.${op.id}'),
                  tooltip: 'Discard',
                  onPressed: () => services.ops.discard(op.id),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            )
          : null,
    );
  }
}
