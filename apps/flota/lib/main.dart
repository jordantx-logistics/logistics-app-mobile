import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:logistics_core/logistics_core.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'fleet_sync.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final services = await AppServices.create(
    appName: 'logistics_fleet',
    appVersion: '1.0.0',
    channels: (api, _) => [fleetEventsChannel(api), FleetReceiptChannel(api)],
  );
  final repository = RoutesRepository(services);

  services.onPull = repository.refresh;

  runApp(
    LogisticsApp(
      brand: AppBrand.flota,
      services: services,
      permission: 'routes.execute',
      home: (_) => RoutesHome(repository: repository),
    ),
  );
}

const _months = ['ENE', 'FEB', 'MAR', 'ABR', 'MAY', 'JUN', 'JUL', 'AGO', 'SEP', 'OCT', 'NOV', 'DIC'];

/// `Lima → Cusco`, o el número de la ruta si aún no se conocen las agencias.
String routeTitle(Map<String, dynamic> route) {
  final from = route['origin_agency_name'];
  final to = route['destination_agency_name'];

  return from != null && to != null ? '$from → $to' : '${route['ticket_number']}';
}

String kilometers(Object? value) => '${(double.tryParse('$value') ?? 0).round()} km';

DateTime? _departure(Map<String, dynamic> route) {
  final raw = route['planned_departure_at'];

  return raw is String ? DateTime.tryParse(raw)?.toLocal() : null;
}

class RoutesHome extends StatelessWidget {
  const RoutesHome({super.key, required this.repository});

  final RoutesRepository repository;

  void _open(BuildContext context, Map<String, dynamic> route) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RouteScreen(repository: repository, routeId: route['id'] as int),
      ),
    );
  }

  bool _isToday(Map<String, dynamic> route) {
    if (route['status'] == 'in_progress') {
      return true;
    }

    final at = _departure(route);
    final now = DateTime.now();

    return at == null || !DateTime(at.year, at.month, at.day).isAfter(DateTime(now.year, now.month, now.day));
  }

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
            logo: true,
            title: 'Hola, ${services.session.user?.firstName ?? ''}',
            subtitle: 'Mis rutas',
            trailing: const AccountButton(),
          ),
          Expanded(
            child: StreamBuilder<List<Map<String, dynamic>>>(
              stream: repository.watch(),
              builder: (context, snapshot) {
                final routes = snapshot.data;

                if (routes == null) {
                  return const Center(child: CircularProgressIndicator());
                }

                final open =
                    routes.where((route) => route['status'] == 'assigned' || route['status'] == 'in_progress').toList()
                      ..sort((a, b) => '${a['planned_departure_at']}'.compareTo('${b['planned_departure_at']}'));

                if (open.isEmpty) {
                  return ValueListenableBuilder<bool>(
                    valueListenable: services.online,
                    builder: (_, online, _) => EmptyMessage(
                      icon: Icons.local_shipping_outlined,
                      title: 'No tienes rutas asignadas',
                      detail: online ? null : 'Sin señal: las nuevas se descargarán cuando vuelva la conexión.',
                    ),
                  );
                }

                final today = open.where(_isToday).toList();
                final next = open.where((route) => !_isToday(route)).toList();

                return ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    if (today.isNotEmpty) ...[
                      const SectionLabel('Hoy'),
                      const SizedBox(height: 10),
                      for (final route in today)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _RouteHero(route: route, brand: brand, onTap: () => _open(context, route)),
                        ),
                    ],
                    if (next.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      const SectionLabel('Próximas'),
                      const SizedBox(height: 10),
                      for (final route in next)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: _NextRouteCard(route: route, brand: brand, onTap: () => _open(context, route)),
                        ),
                    ],
                    const SyncSummaryCard(),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _RouteHero extends StatelessWidget {
  const _RouteHero({required this.route, required this.brand, required this.onTap});

  final Map<String, dynamic> route;
  final AppBrand brand;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final running = route['status'] == 'in_progress';
    final segments = (route['segments'] as List?) ?? const [];
    final total = segments.fold<double>(
      0,
      (sum, segment) => sum + (double.tryParse('${(segment as Map)['distance_km']}') ?? 0),
    );
    final departure = clockOfText(route['planned_departure_at']);
    final details = [
      if (departure != null) 'Sale $departure',
      '${segments.length} ${segments.length == 1 ? 'tramo' : 'tramos'}',
      if (total > 0) kilometers(total),
    ].join(' · ');

    return Material(
      color: Palette.ink,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        key: Key('route.${route['id']}'),
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 12,
            children: [
              Row(
                children: [
                  if (route['vehicle_plate'] case final String plate) PlateTag(plate, background: Palette.surface),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(color: brand.primary, borderRadius: BorderRadius.circular(10)),
                    child: Text(
                      running ? 'En curso' : 'Por iniciar',
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white),
                    ),
                  ),
                ],
              ),
              Text(
                routeTitle(route),
                style: const TextStyle(fontSize: 30, height: 1.05, fontWeight: FontWeight.w800, color: Colors.white),
              ),
              Text(
                details,
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w500, color: Colors.white),
              ),
              Container(
                height: 60,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: brand.primary, borderRadius: BorderRadius.circular(16)),
                child: Text(
                  running ? 'Continuar ruta' : 'Iniciar ruta',
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NextRouteCard extends StatelessWidget {
  const _NextRouteCard({required this.route, required this.brand, required this.onTap});

  final Map<String, dynamic> route;
  final AppBrand brand;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final at = _departure(route);
    final details = [
      if (route['vehicle_plate'] case final String plate) plate,
      if (at != null) 'Sale ${clockOf(at)}',
    ].join(' · ');

    return Material(
      color: Palette.surface,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        key: Key('route.${route['id']}'),
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            spacing: 12,
            children: [
              Container(
                width: 60,
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(color: brand.tint, borderRadius: BorderRadius.circular(13)),
                child: Column(
                  children: [
                    Text(
                      at == null ? '-' : at.day.toString().padLeft(2, '0'),
                      style: TextStyle(fontSize: 22, height: 1, fontWeight: FontWeight.w800, color: brand.dark),
                    ),
                    Text(
                      at == null ? '' : _months[at.month - 1],
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: brand.dark),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      routeTitle(route),
                      style: const TextStyle(fontSize: 20, height: 1.15, fontWeight: FontWeight.w700),
                    ),
                    Text(
                      details,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: Palette.inkSoft),
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

class RouteScreen extends StatelessWidget {
  const RouteScreen({super.key, required this.repository, required this.routeId});

  final RoutesRepository repository;
  final int routeId;

  Future<String?> _ask(BuildContext context, String title, String label) {
    final controller = TextEditingController();

    return showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(title, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 8,
          children: [
            FieldLabel(label),
            TextField(
              key: const Key('route.value'),
              controller: controller,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
            ),
          ],
        ),
        actionsAlignment: MainAxisAlignment.spaceBetween,
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('Cancelar')),
          FilledButton(
            key: const Key('route.value_ok'),
            style: FilledButton.styleFrom(minimumSize: const Size(120, 52)),
            onPressed: () => Navigator.pop(dialog, controller.text.trim()),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
  }

  /// Un dato que no es un número no entra en la cola, y se dice por qué.
  double? _number(BuildContext context, String? value) {
    if (value == null) {
      return null;
    }

    final number = double.tryParse(value);

    if (number == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Escribe solo números.')));
    }

    return number;
  }

  Future<void> _reading(BuildContext context, String title, Future<void> Function(String value) save) async {
    final services = AppScope.of(context);
    final value = await _ask(context, title, 'Odómetro (km)');

    if (!context.mounted || _number(context, value) == null) {
      return;
    }

    await save(value!);
    unawaited(services.sync());
  }

  Future<void> _finish(BuildContext context, Map<String, dynamic> route) async {
    final services = AppScope.of(context);
    final navigator = Navigator.of(context);
    final value = await _ask(context, 'Finalizar ruta', 'Odómetro final (km)');

    if (!context.mounted || _number(context, value) == null) {
      return;
    }

    await repository.finishRoute(route, value!);

    final log = await repository.logOf(route['id'] as int);

    unawaited(services.sync());

    await navigator.pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => RouteFinishedScreen(route: route, log: log, finishedAt: DateTime.now()),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final brand = AppScope.brandOf(context);

    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: repository.watch(),
      builder: (context, snapshot) {
        final route = snapshot.data?.where((row) => row['id'] == routeId).firstOrNull;

        if (route == null) {
          return Scaffold(
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                BrandHeader(brand: brand, title: 'Ruta'),
                const Expanded(
                  child: EmptyMessage(
                    icon: Icons.swap_horiz,
                    title: 'Esta ruta ya no está a tu nombre',
                    detail: 'Consulta con tu supervisor si no lo esperabas.',
                  ),
                ),
              ],
            ),
          );
        }

        final status = route['status'] as String;
        final running = status == 'in_progress';
        final segments = ((route['segments'] as List?) ?? const []).cast<Map<dynamic, dynamic>>();
        final current = segments.where((segment) => segment['status'] != 'completed').firstOrNull;
        final since = clockOfText(route['started_at']);
        final departure = clockOfText(route['planned_departure_at']);

        return Scaffold(
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              BrandHeader(
                brand: brand,
                title: routeTitle(route),
                subtitle: running
                    ? 'En curso${since == null ? '' : ' desde las $since'}'
                    : 'Por iniciar${departure == null ? '' : ' · Sale $departure'}',
                trailing: const SyncBadge(),
                child: Row(
                  spacing: 8,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    if (route['vehicle_plate'] case final String plate) PlateTag(plate, background: Palette.surface),
                    if (current != null)
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(color: brand.dark, borderRadius: BorderRadius.circular(12)),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Tramo actual',
                                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white),
                              ),
                              Text(
                                _segmentName(current),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 17,
                                  height: 1.1,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    if (status == 'assigned') ...[
                      FilledButton(
                        key: const Key('route.start'),
                        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(68)),
                        onPressed: () =>
                            _reading(context, 'Iniciar ruta', (value) => repository.startRoute(route, value)),
                        child: const Text('Iniciar ruta'),
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (running) ...[
                      Row(
                        spacing: 8,
                        children: [
                          _ActionButton(
                            key: const Key('route.mileage'),
                            icon: Icons.speed,
                            label: 'Kilometraje',
                            onTap: () =>
                                _reading(context, 'Kilometraje', (value) => repository.addMileage(route, value)),
                          ),
                          _ActionButton(
                            key: const Key('route.per_diem'),
                            icon: Icons.payments_outlined,
                            label: 'Viático',
                            onTap: () async {
                              final amount = await _ask(context, 'Viático', 'Monto (S/)');

                              if (context.mounted && _number(context, amount) != null) {
                                await repository.addPerDiem(route, amount!);
                                unawaited(services.sync());
                              }
                            },
                          ),
                          _ActionButton(
                            key: const Key('route.fuel'),
                            icon: Icons.local_gas_station,
                            label: 'Combustible',
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => FuelScreen(repository: repository, route: route),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                    ],
                    const SectionLabel('Tramos'),
                    const SizedBox(height: 8),
                    for (final segment in segments)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _SegmentCard(
                          key: Key('segment.${segment['id']}'),
                          segment: segment,
                          brand: brand,
                          current: running && segment == current,
                          onComplete: running && segment == current
                              ? () async {
                                  await repository.completeSegment(route, segment['id'] as int);
                                  unawaited(services.sync());
                                }
                              : null,
                        ),
                      ),
                    StreamBuilder<List<Map<String, dynamic>>>(
                      stream: repository.watchLog(routeId),
                      builder: (context, log) {
                        final rows = log.data ?? const <Map<String, dynamic>>[];

                        if (rows.isEmpty) {
                          return const SizedBox.shrink();
                        }

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          spacing: 8,
                          children: [
                            const SizedBox(height: 8),
                            const SectionLabel('Registrado en esta ruta'),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                              decoration: BoxDecoration(
                                color: Palette.surface,
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Column(children: [for (final row in rows) _LogRow(row: row)]),
                            ),
                          ],
                        );
                      },
                    ),
                    if (running) ...[
                      const SizedBox(height: 20),
                      FilledButton(
                        key: const Key('route.finish'),
                        style: darkButton().copyWith(minimumSize: const WidgetStatePropertyAll(Size.fromHeight(64))),
                        onPressed: () => _finish(context, route),
                        child: const Text('Finalizar ruta'),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

String _segmentName(Map<dynamic, dynamic> segment) {
  final from = segment['from_agency_name'];
  final to = segment['to_agency_name'];

  return from != null && to != null ? '$from → $to' : 'Tramo ${segment['sequence']}';
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({super.key, required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Material(
        color: Theme.of(context).colorScheme.primary,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: SizedBox(
            height: 92,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              spacing: 6,
              children: [
                Icon(icon, size: 30, color: Colors.white),
                Text(
                  label,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SegmentCard extends StatelessWidget {
  const _SegmentCard({
    super.key,
    required this.segment,
    required this.brand,
    required this.current,
    required this.onComplete,
  });

  final Map<dynamic, dynamic> segment;
  final AppBrand brand;
  final bool current;
  final VoidCallback? onComplete;

  @override
  Widget build(BuildContext context) {
    final done = segment['status'] == 'completed';
    final distance = Text(
      kilometers(segment['distance_km']),
      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: current ? Colors.white : Palette.inkSoft),
    );

    if (done) {
      return ItemCard(state: ItemState.ok, title: _segmentName(segment), trailing: distance);
    }

    if (!current) {
      return ItemCard(
        state: ItemState.neutral,
        brand: brand,
        title: _segmentName(segment),
        leadingText: '${segment['sequence']}',
        trailing: distance,
      );
    }

    return Material(
      color: Palette.ink,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onComplete,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            spacing: 12,
            children: [
              Container(
                width: 48,
                height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: brand.primary, borderRadius: BorderRadius.circular(13)),
                child: Text(
                  '${segment['sequence']}',
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Colors.white),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _segmentName(segment),
                      style: const TextStyle(
                        fontSize: 19,
                        height: 1.15,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                    const Text(
                      'Toca para marcar completado',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: Colors.white),
                    ),
                  ],
                ),
              ),
              distance,
            ],
          ),
        ),
      ),
    );
  }
}

class _LogRow extends StatelessWidget {
  const _LogRow({required this.row});

  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final (String label, String value) = switch (row['type']) {
      'mileage' => ('Kilometraje', '${row['value']} km'),
      'fuel' => ('Combustible', 'S/ ${row['value']}'),
      _ => ('Viático', 'S/ ${row['value']}'),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          ),
          Text(
            '$value · ${clockOfText(row['at']) ?? ''}',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

/// Combustible: el servidor exige el comprobante. Se comprime y queda en disco hasta subir.
class FuelScreen extends StatefulWidget {
  const FuelScreen({super.key, required this.repository, required this.route});

  final RoutesRepository repository;
  final Map<String, dynamic> route;

  @override
  State<FuelScreen> createState() => _FuelScreenState();
}

class _FuelScreenState extends State<FuelScreen> {
  final _amount = TextEditingController();
  final _liters = TextEditingController();
  final _odometer = TextEditingController();
  String? _receipt;
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    _liters.dispose();
    _odometer.dispose();
    super.dispose();
  }

  Future<void> _capture() async {
    final dir = AppScope.of(context).filesDir;
    final photo = await ImagePicker().pickImage(source: ImageSource.camera, maxWidth: 1600, imageQuality: 70);

    if (photo != null) {
      final target = p.join(dir.path, 'receipt-${const Uuid().v4()}.jpg');

      await File(photo.path).copy(target);
      setState(() {
        _receipt = target;
        _error = null;
      });
    }
  }

  Future<void> _save() async {
    final services = AppScope.of(context);
    final missing = [
      if (double.tryParse(_amount.text) == null) 'monto',
      if (double.tryParse(_liters.text) == null) 'litros',
      if (_receipt == null) 'foto del comprobante',
    ];

    if (missing.isNotEmpty) {
      setState(() => _error = 'Falta: ${missing.join(', ')}.');

      return;
    }

    await widget.repository.addFuel(
      widget.route,
      amount: _amount.text.trim(),
      liters: _liters.text.trim(),
      receiptPath: _receipt!,
      odometer: _odometer.text.trim().isEmpty ? null : _odometer.text.trim(),
    );
    unawaited(services.sync());

    if (mounted) {
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Combustible guardado.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final brand = AppScope.brandOf(context);
    const decimal = TextInputType.numberWithOptions(decimal: true);
    const big = TextStyle(fontSize: 24, fontWeight: FontWeight.w700);

    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          BrandHeader(
            brand: brand,
            title: 'Combustible',
            subtitle: widget.route['vehicle_plate'] as String?,
            subtitleIsCode: true,
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Row(
                  spacing: 10,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        spacing: 8,
                        children: [
                          const FieldLabel('Monto (S/)'),
                          TextField(controller: _amount, keyboardType: decimal, style: big),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        spacing: 8,
                        children: [
                          const FieldLabel('Litros'),
                          TextField(controller: _liters, keyboardType: decimal, style: big),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                const FieldLabel('Odómetro (opcional)'),
                const SizedBox(height: 8),
                TextField(
                  controller: _odometer,
                  keyboardType: decimal,
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 14),
                const FieldLabel('Comprobante'),
                const SizedBox(height: 8),
                if (_receipt == null)
                  Material(
                    color: brand.primary,
                    borderRadius: BorderRadius.circular(18),
                    child: InkWell(
                      key: const Key('fuel.photo'),
                      borderRadius: BorderRadius.circular(18),
                      onTap: _capture,
                      child: const SizedBox(
                        height: 170,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          spacing: 10,
                          children: [
                            Icon(Icons.photo_camera, size: 52, color: Colors.white),
                            Text(
                              'Tomar foto del comprobante',
                              style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800, color: Colors.white),
                            ),
                          ],
                        ),
                      ),
                    ),
                  )
                else
                  ItemCard(
                    state: ItemState.ok,
                    title: 'Comprobante listo',
                    subtitle: 'Toca para cambiar la foto',
                    onTap: _capture,
                  ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: Palette.bad),
                  ),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  key: const Key('fuel.save'),
                  style: darkButton().copyWith(minimumSize: const WidgetStatePropertyAll(Size.fromHeight(68))),
                  onPressed: _save,
                  child: const Text('Guardar combustible'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Resumen al finalizar: el chofer ve que la ruta quedó cerrada y lo que registró.
class RouteFinishedScreen extends StatelessWidget {
  const RouteFinishedScreen({super.key, required this.route, required this.log, required this.finishedAt});

  final Map<String, dynamic> route;
  final List<Map<String, dynamic>> log;
  final DateTime finishedAt;

  String _sum(String type) {
    final total = log
        .where((row) => row['type'] == type)
        .fold<double>(0, (sum, row) => sum + (double.tryParse('${row['value']}') ?? 0));

    return 'S/ ${total.toStringAsFixed(2)}';
  }

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final brand = AppScope.brandOf(context);
    final segments = ((route['segments'] as List?) ?? const []).cast<Map<dynamic, dynamic>>();
    final total = segments.fold<double>(0, (sum, segment) => sum + (double.tryParse('${segment['distance_km']}') ?? 0));
    final started = route['started_at'] is String ? DateTime.tryParse(route['started_at'] as String) : null;

    return DoneScreen(
      brand: brand,
      title: 'Ruta finalizada',
      message: Text('${routeTitle(route)}. Terminaste a las ${clockOf(finishedAt)}.'),
      panel: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          GridView.count(
            crossAxisCount: 2,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            childAspectRatio: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              _Stat(value: kilometers(total), label: 'recorridos', brand: brand),
              _Stat(
                value: started == null ? '-' : durationLabel(finishedAt.difference(started).inMinutes),
                label: 'de viaje',
                brand: brand,
              ),
              _Stat(value: _sum('per_diem'), label: 'viáticos', brand: brand),
              _Stat(value: _sum('fuel'), label: 'combustible', brand: brand),
            ],
          ),
          StreamBuilder<SyncCounts>(
            stream: services.ops.watchCounts(),
            builder: (_, snapshot) {
              final pending = snapshot.data?.pending ?? 1;

              return ItemCard(
                state: pending == 0 ? ItemState.ok : ItemState.waiting,
                title: pending == 0 ? 'Todo quedó enviado a la central' : 'Se enviará al volver la señal',
              );
            },
          ),
          FilledButton(
            key: const Key('route.done'),
            onPressed: () => Navigator.of(context).popUntil((page) => page.isFirst),
            child: const Text('Volver a mis rutas'),
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label, required this.brand});

  final String value;
  final String label;
  final AppBrand brand;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(color: brand.tint, borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          FittedBox(
            child: Text(value, style: const TextStyle(fontSize: 28, height: 1, fontWeight: FontWeight.w800)),
          ),
          Text(
            label,
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: brand.dark),
          ),
        ],
      ),
    );
  }
}
