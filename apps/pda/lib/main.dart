import 'dart:async';

import 'package:flutter/material.dart';
import 'package:logistics_core/logistics_core.dart';

import 'manifest_screen.dart';
import 'scan_screen.dart';
import 'scans_channel.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final services = await AppServices.create(
    appName: 'logistics_pda',
    appVersion: '1.0.0',
    channels: (api, _) => [scansChannel(api)],
  );
  final repository = EmbarksRepository(services);

  services.onPull = repository.refresh;

  runApp(
    LogisticsApp(
      brand: AppBrand.almacen,
      services: services,
      permission: 'tracking.scan',
      home: (_) => PdaHome(embarks: repository),
    ),
  );
}

class PdaHome extends StatefulWidget {
  const PdaHome({super.key, required this.embarks, this.cameraEnabled = true});

  final EmbarksRepository embarks;

  /// Los tests de integración escanean escribiendo: la cámara no se puede automatizar.
  final bool cameraEnabled;

  @override
  State<PdaHome> createState() => _PdaHomeState();
}

class _PdaHomeState extends State<PdaHome> {
  static const _settings = 'pda_settings';

  int? _agencyId;
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    if (!_loaded) {
      _loaded = true;
      // Se puede empezar ya con la primera agencia; la guardada llega enseguida.
      _agencyId = AppScope.of(context).session.user?.agencies.firstOrNull;
      unawaited(_loadAgency());
    }
  }

  /// Vuelve a la última agencia elegida, si la cuenta aún la tiene.
  Future<void> _loadAgency() async {
    final services = AppScope.of(context);
    final agencies = services.session.user?.agencies ?? const <int>[];
    final saved = await services.cache.get(_settings, 'agency');
    final savedId = saved?['id'] as int?;

    if (mounted && agencies.contains(savedId)) {
      setState(() => _agencyId = savedId);
    }
  }

  Future<void> _pickAgency() async {
    final services = AppScope.of(context);
    final user = services.session.user;

    final picked = await showModalBottomSheet<int>(
      context: context,
      builder: (sheet) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(20),
          children: [
            const SectionLabel('¿En qué agencia trabajas?'),
            const SizedBox(height: 12),
            for (final id in user?.agencies ?? const <int>[])
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: FilledButton(
                  style: id == _agencyId ? null : quietButton(),
                  onPressed: () => Navigator.pop(sheet, id),
                  child: Text(user!.agencyName(id)),
                ),
              ),
          ],
        ),
      ),
    );

    if (picked != null) {
      await services.cache.put(_settings, 'agency', {'id': picked});
      setState(() => _agencyId = picked);
    }
  }

  void _open(ScanType type) {
    if (_agencyId == null) {
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => type.needsEmbark
            ? ManifestScreen(
                type: type,
                agencyId: _agencyId!,
                embarks: widget.embarks,
                cameraEnabled: widget.cameraEnabled,
              )
            : ScanScreen(
                type: type,
                agencyId: _agencyId!,
                context: AppScope.of(context).session.user?.agencyName(_agencyId) ?? '',
                cameraEnabled: widget.cameraEnabled,
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final brand = AppScope.brandOf(context);
    final user = services.session.user;
    final agencies = user?.agencies ?? const <int>[];

    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          BrandHeader(
            brand: brand,
            logo: true,
            title: 'Hola, ${user?.firstName ?? ''}',
            subtitle: 'Operación de almacén',
            trailing: const AccountButton(),
            child: Material(
              color: brand.dark,
              borderRadius: BorderRadius.circular(14),
              child: InkWell(
                key: const Key('pda.agency'),
                borderRadius: BorderRadius.circular(14),
                onTap: agencies.length > 1 ? _pickAgency : null,
                child: Container(
                  height: 56,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _agencyId == null ? 'Sin agencia asignada' : user!.agencyName(_agencyId),
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Colors.white),
                        ),
                      ),
                      if (agencies.length > 1)
                        const Text(
                          'Cambiar',
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Colors.white),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                _ReceiveButton(onTap: () => _open(ScanType.reception)),
                const SizedBox(height: 12),
                GridView.count(
                  crossAxisCount: 2,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                  childAspectRatio: 1.45,
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  physics: const NeverScrollableScrollPhysics(),
                  children: [
                    for (final type in ScanType.values)
                      if (type != ScanType.reception) _ActionTile(type: type, onTap: () => _open(type)),
                  ],
                ),
                const SizedBox(height: 12),
                const SyncSummaryCard(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ReceiveButton extends StatelessWidget {
  const _ReceiveButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Palette.ink,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        key: Key('pda.${ScanType.reception.code}'),
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: const Padding(
          padding: EdgeInsets.all(20),
          child: Row(
            spacing: 16,
            children: [
              Icon(Icons.move_to_inbox, size: 52, color: Colors.white),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Recibir',
                      style: TextStyle(fontSize: 30, height: 1.1, fontWeight: FontWeight.w800, color: Colors.white),
                    ),
                    Text(
                      'Paquetes que llegan al almacén',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: Colors.white),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({required this.type, required this.onTap});

  final ScanType type;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.primary,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        key: Key('pda.${type.code}'),
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Icon(type.icon, size: 34, color: Colors.white),
              Text(
                type.label,
                style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800, color: Colors.white),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
