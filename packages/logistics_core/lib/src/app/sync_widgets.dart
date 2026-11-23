import 'package:flutter/material.dart';

import '../db/app_database.dart';
import '../sync/op_store.dart';
import 'brand.dart';
import 'logistics_app.dart';
import 'widgets.dart';

/// El servidor responde en inglés y con códigos: el personal necesita saber qué hacer.
String friendlyRejection(String? code) {
  return switch (code) {
    'SHIPMENT_NOT_FOUND' => 'Esta guía no existe. Revisa el código.',
    'INVALID_SHIPMENT_TRANSITION' => 'Este paquete no puede hacer este paso todavía. Revisa el paso anterior.',
    'ATTENDANCE_SEQUENCE_INVALID' => 'Esta marcación no sigue el orden de la jornada.',
    'ATTENDANCE_DUPLICATE' => 'Esta marcación ya estaba registrada.',
    'LOCAL_FILE_MISSING' => 'La foto o la firma ya no están en este equipo.',
    'SCAN_AGENCY_NOT_ALLOWED' => 'No puedes registrar en esa agencia.',
    _ => 'No se pudo registrar. Avisa a tu supervisor.',
  };
}

/// Indicador de la cabecera. Dice lo que pasa con palabras y abre la pantalla de cola.
class SyncBadge extends StatelessWidget {
  const SyncBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final brand = AppScope.brandOf(context);

    return ValueListenableBuilder<bool>(
      valueListenable: services.online,
      builder: (context, online, _) => StreamBuilder<SyncCounts>(
        stream: services.ops.watchCounts(),
        builder: (context, snapshot) {
          final counts = snapshot.data ?? const SyncCounts();
          final (IconData icon, String? label, Color color) = counts.conflict > 0
              ? (Icons.warning_amber, '${counts.conflict}', Palette.bad)
              : !online
              ? (Icons.cloud_off, counts.pending > 0 ? '${counts.pending}' : null, brand.dark)
              : counts.pending > 0
              ? (Icons.cloud_upload_outlined, '${counts.pending}', brand.dark)
              : (Icons.cloud_done_outlined, null, brand.dark);

          return Tooltip(
            message: 'Envíos pendientes',
            child: Material(
              color: color,
              borderRadius: BorderRadius.circular(14),
              child: InkWell(
                key: const Key('sync.badge'),
                borderRadius: BorderRadius.circular(14),
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SyncScreen())),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      spacing: 4,
                      children: [
                        Icon(icon, color: Colors.white),
                        if (label != null)
                          Text(
                            label,
                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Colors.white),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Aviso de la pantalla principal: solo aparece si hay algo que atender o por enviar.
class SyncSummaryCard extends StatelessWidget {
  const SyncSummaryCard({super.key});

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);

    return StreamBuilder<SyncCounts>(
      stream: services.ops.watchCounts(),
      builder: (context, snapshot) {
        final counts = snapshot.data ?? const SyncCounts();

        if (counts.conflict == 0 && counts.pending == 0) {
          return const SizedBox.shrink();
        }

        final waiting = 'Se enviarán en cuanto haya señal';

        return ItemCard(
          key: const Key('sync.summary'),
          state: counts.conflict > 0 ? ItemState.rejected : ItemState.waiting,
          leadingText: counts.conflict > 0 ? '${counts.conflict}' : '${counts.pending}',
          title: counts.conflict > 0
              ? counts.conflict == 1
                    ? '1 registro necesita revisión'
                    : '${counts.conflict} registros necesitan revisión'
              : 'Por enviar',
          subtitle: counts.pending > 0 ? waiting : null,
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SyncScreen())),
        );
      },
    );
  }
}

/// Lo pendiente y lo rechazado. Lo sincronizado no aparece: ya es del servidor.
class SyncScreen extends StatelessWidget {
  const SyncScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final brand = AppScope.brandOf(context);

    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          BrandHeader(
            brand: brand,
            title: 'Envíos',
            subtitle: 'Lo que falta enviar o revisar',
            trailing: HeaderButton(
              key: const Key('sync.retry_all'),
              icon: Icons.sync,
              tooltip: 'Enviar ahora',
              color: brand.dark,
              onPressed: () => services.sync(manual: true),
            ),
          ),
          Expanded(
            child: StreamBuilder<List<LocalOp>>(
              stream: services.ops.watch([OpStatus.pending, OpStatus.conflict]),
              builder: (context, snapshot) {
                final ops = snapshot.data;

                if (ops == null) {
                  return const Center(child: CircularProgressIndicator());
                }

                if (ops.isEmpty) {
                  return const EmptyMessage(icon: Icons.cloud_done_outlined, title: 'Todo está enviado');
                }

                return ListView.separated(
                  padding: const EdgeInsets.all(20),
                  itemCount: ops.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, index) => _OpCard(op: ops[index]),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _OpCard extends StatelessWidget {
  const _OpCard({required this.op});

  final LocalOp op;

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);

    if (op.status != OpStatus.conflict) {
      return ItemCard(
        state: ItemState.waiting,
        title: opTitle(op),
        titleIsCode: true,
        subtitle: op.attempts == 0 ? 'Por enviar' : 'Se enviará al volver la señal',
      );
    }

    return ItemCard(
      state: ItemState.rejected,
      title: opTitle(op),
      titleIsCode: true,
      subtitle: friendlyRejection(op.errorCode),
      actions: Row(
        spacing: 8,
        children: [
          Expanded(
            child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Palette.bad, minimumSize: const Size.fromHeight(48)),
              onPressed: () async {
                await services.ops.retry(op.id);
                await services.sync(manual: true);
              },
              child: const Text('Reintentar'),
            ),
          ),
          Expanded(
            child: FilledButton(
              key: Key('sync.discard.${op.id}'),
              style: darkButton().copyWith(minimumSize: const WidgetStatePropertyAll(Size.fromHeight(48))),
              onPressed: () => services.ops.discard(op.id),
              child: const Text('Descartar'),
            ),
          ),
        ],
      ),
    );
  }
}

/// El nombre de lo que se está enviando: la guía de un paquete, si la lleva.
String opTitle(LocalOp op) => op.payload['ticket_code'] as String? ?? op.entityKey;
