import 'dart:async';

import 'package:flutter/material.dart';
import 'package:logistics_core/logistics_core.dart';

import 'scan_screen.dart';
import 'scans_channel.dart';

/// Elegir el manifiesto antes de escanear. Se busca por placa porque es lo que se ve en
/// el camión; la ruta y el chofer confirman que es el correcto.
class ManifestScreen extends StatefulWidget {
  const ManifestScreen({
    super.key,
    required this.type,
    required this.agencyId,
    required this.embarks,
    this.cameraEnabled = true,
  });

  final ScanType type;
  final int agencyId;
  final EmbarksRepository embarks;
  final bool cameraEnabled;

  @override
  State<ManifestScreen> createState() => _ManifestScreenState();
}

class _ManifestScreenState extends State<ManifestScreen> {
  final _search = TextEditingController();
  Timer? _debounce;
  List<Map<String, dynamic>> _rows = const [];
  Map<String, dynamic>? _picked;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final rows = await widget.embarks.search(_search.text);

    if (mounted) {
      setState(() {
        _rows = rows;
        _loaded = true;

        if (_picked != null && !rows.any((row) => row['id'] == _picked!['id'])) {
          _picked = null;
        }
      });
    }
  }

  void _onChanged(String _) {
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => unawaited(_load()));
  }

  String _plateOf(Map<String, dynamic> row) => row['vehicle_plate'] as String? ?? '#${row['id']}';

  void _continue() {
    final picked = _picked;

    if (picked == null) {
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ScanScreen(
          type: widget.type,
          agencyId: widget.agencyId,
          embarkId: picked['id'] as int,
          context: _plateOf(picked),
          contextIsCode: true,
          cameraEnabled: widget.cameraEnabled,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final brand = AppScope.brandOf(context);
    final picked = _picked;

    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          BrandHeader(
            brand: brand,
            title: widget.type.label,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 8,
              children: [
                const Text(
                  'Busca por placa o ruta',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white),
                ),
                TextField(
                  key: const Key('manifest.search'),
                  controller: _search,
                  textCapitalization: TextCapitalization.characters,
                  style: codeStyle(20, color: Palette.ink),
                  decoration: InputDecoration(
                    fillColor: Palette.surface,
                    hintText: 'B7K-482',
                    prefixIcon: const Icon(Icons.search, color: Palette.ink),
                    suffixIcon: _search.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Borrar búsqueda',
                            icon: const Icon(Icons.close, color: Palette.ink),
                            onPressed: () {
                              _search.clear();
                              _onChanged('');
                            },
                          ),
                  ),
                  onChanged: _onChanged,
                ),
              ],
            ),
          ),
          Expanded(child: _results(brand)),
          if (picked != null)
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                child: FilledButton.icon(
                  key: const Key('manifest.go'),
                  icon: const Icon(Icons.qr_code_scanner),
                  onPressed: _continue,
                  label: Text('Escanear para ${_plateOf(picked)}'),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _results(AppBrand brand) {
    if (!_loaded) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_rows.isEmpty) {
      return _search.text.isEmpty
          ? ValueListenableBuilder<bool>(
              valueListenable: AppScope.of(context).online,
              builder: (_, online, _) => EmptyMessage(
                icon: Icons.local_shipping_outlined,
                title: 'Aún no hay manifiestos',
                detail: online
                    ? 'Los crea tu supervisor desde la web.'
                    : 'Sin señal: se descargarán cuando vuelva la conexión.',
              ),
            )
          : EmptyMessage(
              icon: Icons.search_off,
              title: 'Sin resultados',
              detail: 'Nada coincide con «${_search.text}».',
            );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(20),
      itemCount: _rows.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (_, index) {
        final row = _rows[index];

        return _ManifestCard(
          row: row,
          plate: _plateOf(row),
          selected: _picked?['id'] == row['id'],
          brand: brand,
          onTap: () => setState(() => _picked = row),
        );
      },
    );
  }
}

class _ManifestCard extends StatelessWidget {
  const _ManifestCard({
    required this.row,
    required this.plate,
    required this.selected,
    required this.brand,
    required this.onTap,
  });

  final Map<String, dynamic> row;
  final String plate;
  final bool selected;
  final AppBrand brand;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final foreground = selected ? Colors.white : Palette.ink;
    final details = [
      if (clockOfText(row['departed_at']) case final at?) 'Sale $at',
      if (row['driver_name'] case final String driver) driver,
      '${row['items_count'] ?? 0} paquetes',
    ].join(' · ');

    return Material(
      color: selected ? Palette.ink : Palette.surface,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        key: Key('manifest.${row['id']}'),
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 10,
            children: [
              Row(
                children: [
                  PlateTag(plate, background: selected ? Palette.surface : Palette.field),
                  const Spacer(),
                  if (selected)
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(color: brand.primary, shape: BoxShape.circle),
                      child: const Icon(Icons.check, color: Colors.white),
                    ),
                ],
              ),
              Text(
                row['route_ref'] as String? ?? 'Sin ruta asignada',
                style: TextStyle(fontSize: 21, height: 1.1, fontWeight: FontWeight.w700, color: foreground),
              ),
              Text(
                details,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: selected ? Colors.white : Palette.inkSoft,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
