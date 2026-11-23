import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:logistics_core/logistics_core.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import 'delivery_sync.dart';
import 'signature_pad.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final services = await AppServices.create(
    appName: 'logistics_delivery',
    appVersion: '1.0.0',
    channels: (api, _) => [DeliveryChannel(api)],
  );
  final repository = StopsRepository(services);

  services.onPull = repository.refresh;

  runApp(
    LogisticsApp(
      brand: AppBrand.reparto,
      services: services,
      permission: 'delivery.execute',
      home: (_) => StopsHome(repository: repository),
    ),
  );
}

const _open = {'assigned', 'in_progress'};

/// Motivos de «no entregado». Elegir es más rápido que escribir en la calle.
const _failureReasons = [
  'Nadie en casa',
  'Dirección incorrecta',
  'Rechazó el paquete',
  'Pidió otra fecha',
  'Otro motivo',
];

bool isOpen(Map<String, dynamic> stop) => _open.contains(stop['status']);

String stopPlace(Map<String, dynamic> stop) => stop['recipient_address'] as String? ?? 'Recoge en agencia';

String stopPerson(Map<String, dynamic> stop) => stop['recipient_name'] as String? ?? 'Destinatario sin nombre';

void _openStop(BuildContext context, StopsRepository repository, Map<String, dynamic> stop) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => StopScreen(repository: repository, stop: stop),
    ),
  );
}

Future<void> _navigateTo(Map<String, dynamic> stop) {
  final address = Uri.encodeQueryComponent('${stop['recipient_address']}');

  return launchUrl(
    Uri.parse('https://www.google.com/maps/search/?api=1&query=$address'),
    mode: LaunchMode.externalApplication,
  );
}

Future<void> _callTo(Map<String, dynamic> stop) => launchUrl(Uri(scheme: 'tel', path: '${stop['recipient_phone']}'));

class StopsHome extends StatefulWidget {
  const StopsHome({super.key, required this.repository});

  final StopsRepository repository;

  @override
  State<StopsHome> createState() => _StopsHomeState();
}

class _StopsHomeState extends State<StopsHome> {
  bool _showDone = false;

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final brand = AppScope.brandOf(context);

    return Scaffold(
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: widget.repository.watch(),
        builder: (context, snapshot) {
          final stops = snapshot.data ?? const <Map<String, dynamic>>[];

          // Lo que ya se empezó va primero: es adonde va el repartidor.
          final open = stops.where(isOpen).toList()
            ..sort((a, b) {
              final byStatus = (b['status'] == 'in_progress' ? 1 : 0) - (a['status'] == 'in_progress' ? 1 : 0);

              return byStatus != 0 ? byStatus : (a['id'] as int).compareTo(b['id'] as int);
            });
          final done = stops.where((stop) => !isOpen(stop)).toList();
          final total = stops.length;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              BrandHeader(
                brand: brand,
                logo: true,
                title: '${done.length} de $total hechas',
                subtitle: 'Hola, ${services.session.user?.firstName ?? ''}',
                trailing: const AccountButton(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 12,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(5),
                      child: LinearProgressIndicator(
                        minHeight: 10,
                        value: total == 0 ? 0 : done.length / total,
                        color: Colors.white,
                        backgroundColor: brand.dark,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.all(5),
                      decoration: BoxDecoration(color: brand.dark, borderRadius: BorderRadius.circular(14)),
                      child: Row(
                        spacing: 6,
                        children: [
                          _Tab(
                            key: const Key('stops.pending'),
                            label: 'Pendientes ${open.length}',
                            selected: !_showDone,
                            brand: brand,
                            onTap: () => setState(() => _showDone = false),
                          ),
                          _Tab(
                            key: const Key('stops.done'),
                            label: 'Hechas ${done.length}',
                            selected: _showDone,
                            brand: brand,
                            onTap: () => setState(() => _showDone = true),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: snapshot.data == null
                    ? const Center(child: CircularProgressIndicator())
                    : _showDone
                    ? _DoneList(stops: done)
                    : _PendingList(stops: open, repository: widget.repository, brand: brand),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({super.key, required this.label, required this.selected, required this.brand, required this.onTap});

  final String label;
  final bool selected;
  final AppBrand brand;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Material(
        color: selected ? Palette.surface : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: SizedBox(
            height: 44,
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: selected ? brand.dark : Colors.white,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PendingList extends StatelessWidget {
  const _PendingList({required this.stops, required this.repository, required this.brand});

  final List<Map<String, dynamic>> stops;
  final StopsRepository repository;
  final AppBrand brand;

  @override
  Widget build(BuildContext context) {
    if (stops.isEmpty) {
      return ValueListenableBuilder<bool>(
        valueListenable: AppScope.of(context).online,
        builder: (_, online, _) => EmptyMessage(
          icon: Icons.task_alt,
          title: 'No tienes entregas pendientes',
          detail: online ? null : 'Sin señal: las nuevas se descargarán cuando vuelva la conexión.',
        ),
      );
    }

    final next = stops.first;

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _NextStop(stop: next, repository: repository, brand: brand),
        const SizedBox(height: 10),
        const SyncSummaryCard(),
        for (final (index, stop) in stops.skip(1).indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: ItemCard(
              key: Key('stop.${stop['id']}'),
              state: ItemState.neutral,
              brand: brand,
              leadingText: '${index + 2}',
              title: stopPlace(stop),
              subtitle: stopPerson(stop),
              onTap: () => _openStop(context, repository, stop),
            ),
          ),
      ],
    );
  }
}

/// La siguiente parada, con lo que hace falta para llegar sin abrir nada más.
class _NextStop extends StatelessWidget {
  const _NextStop({required this.stop, required this.repository, required this.brand});

  final Map<String, dynamic> stop;
  final StopsRepository repository;
  final AppBrand brand;

  @override
  Widget build(BuildContext context) {
    final hasAddress = stop['recipient_address'] != null;
    final hasPhone = stop['recipient_phone'] != null;
    final compact = FilledButton.styleFrom(
      backgroundColor: Palette.surface,
      foregroundColor: Palette.ink,
      minimumSize: const Size.fromHeight(56),
    );

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Palette.ink, borderRadius: BorderRadius.circular(22)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 10,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  stop['status'] == 'in_progress' ? 'En camino' : 'Siguiente parada',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white),
                ),
              ),
              Text('${stop['ticket_code']}', style: codeStyle(16, color: Colors.white)),
            ],
          ),
          Text(
            stopPlace(stop),
            style: const TextStyle(fontSize: 26, height: 1.1, fontWeight: FontWeight.w800, color: Colors.white),
          ),
          Text(
            stopPerson(stop),
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w500, color: Colors.white),
          ),
          if (hasAddress || hasPhone)
            Row(
              spacing: 8,
              children: [
                if (hasAddress)
                  Expanded(
                    child: FilledButton.icon(
                      style: compact,
                      icon: const Icon(Icons.navigation),
                      onPressed: () => _navigateTo(stop),
                      label: const Text('Navegar'),
                    ),
                  ),
                if (hasPhone)
                  Expanded(
                    child: FilledButton.icon(
                      style: compact,
                      icon: const Icon(Icons.call),
                      onPressed: () => _callTo(stop),
                      label: const Text('Llamar'),
                    ),
                  ),
              ],
            ),
          FilledButton(
            key: Key('stop.${stop['id']}'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
            onPressed: () => _openStop(context, repository, stop),
            child: const Text('Abrir entrega'),
          ),
        ],
      ),
    );
  }
}

class _DoneList extends StatelessWidget {
  const _DoneList({required this.stops});

  final List<Map<String, dynamic>> stops;

  @override
  Widget build(BuildContext context) {
    if (stops.isEmpty) {
      return const EmptyMessage(icon: Icons.inventory_2_outlined, title: 'Aún no hay entregas hechas hoy');
    }

    return ListView.separated(
      padding: const EdgeInsets.all(20),
      itemCount: stops.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (_, index) {
        final stop = stops[index];
        final delivered = stop['status'] == 'delivered';
        final at = clockOfText(stop['delivered_at']);

        return ItemCard(
          state: delivered ? ItemState.ok : ItemState.rejected,
          title: stopPlace(stop),
          subtitle: delivered
              ? 'Entregada${at == null ? '' : ' · $at'} · ${stopPerson(stop)}'
              : 'No entregada · ${stop['failure_reason'] ?? 'Sin motivo'}',
        );
      },
    );
  }
}

/// Una parada: quién, dónde y qué hacer. Entregar es la acción principal.
class StopScreen extends StatelessWidget {
  const StopScreen({super.key, required this.repository, required this.stop});

  final StopsRepository repository;
  final Map<String, dynamic> stop;

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final brand = AppScope.brandOf(context);
    final hasAddress = stop['recipient_address'] != null;
    final hasPhone = stop['recipient_phone'] != null;

    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          BrandHeader(
            brand: brand,
            title: 'Entrega',
            subtitle: '${stop['ticket_code']}',
            subtitleIsCode: true,
            trailing: const SyncBadge(),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(stopPlace(stop), style: const TextStyle(fontSize: 30, height: 1.1, fontWeight: FontWeight.w800)),
                const SizedBox(height: 6),
                Text(
                  stopPerson(stop),
                  style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w500, color: Palette.inkSoft),
                ),
                const SizedBox(height: 20),
                if (hasAddress || hasPhone) ...[
                  Row(
                    spacing: 8,
                    children: [
                      if (hasAddress)
                        Expanded(
                          child: FilledButton.icon(
                            style: darkButton(),
                            icon: const Icon(Icons.navigation),
                            onPressed: () => _navigateTo(stop),
                            label: const Text('Navegar'),
                          ),
                        ),
                      if (hasPhone)
                        Expanded(
                          child: FilledButton.icon(
                            style: darkButton(),
                            icon: const Icon(Icons.call),
                            onPressed: () => _callTo(stop),
                            label: const Text('Llamar'),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
                if (isOpen(stop)) ...[
                  FilledButton(
                    key: const Key('stop.complete'),
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(72)),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => DeliverScreen(repository: repository, stop: stop),
                      ),
                    ),
                    child: const Text('Entregar'),
                  ),
                  const SizedBox(height: 12),
                  if (stop['status'] == 'assigned') ...[
                    FilledButton(
                      key: const Key('stop.start'),
                      style: quietButton(),
                      onPressed: () async {
                        final navigator = Navigator.of(context);

                        await repository.start(stop);
                        unawaited(services.sync());
                        navigator.pop();
                      },
                      child: const Text('Voy en camino'),
                    ),
                    const SizedBox(height: 12),
                  ],
                  FilledButton(
                    key: const Key('stop.fail'),
                    style: quietButton(),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => NotDeliveredScreen(repository: repository, stop: stop),
                      ),
                    ),
                    child: const Text('No se pudo entregar'),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Firma, foto y ubicación se guardan al instante en disco: la entrega no espera a la red.
class DeliverScreen extends StatefulWidget {
  const DeliverScreen({super.key, required this.repository, required this.stop});

  final StopsRepository repository;
  final Map<String, dynamic> stop;

  @override
  State<DeliverScreen> createState() => _DeliverScreenState();
}

class _DeliverScreenState extends State<DeliverScreen> {
  final _name = TextEditingController();
  final _document = TextEditingController();
  final _signature = SignatureController();
  String? _photo;
  String? _error;
  bool _saving = false;
  Position? _position;
  bool _locating = true;

  @override
  void initState() {
    super.initState();
    _name.text = '${widget.stop['recipient_name'] ?? ''}';
    // Se pide al entrar, no con el destinatario esperando la confirmación.
    unawaited(_locate());
  }

  @override
  void dispose() {
    _name.dispose();
    _document.dispose();
    super.dispose();
  }

  Future<void> _capture() async {
    final dir = AppScope.of(context).filesDir;
    final photo = await ImagePicker().pickImage(source: ImageSource.camera, maxWidth: 1600, imageQuality: 70);

    if (photo != null) {
      final target = p.join(dir.path, 'photo-${const Uuid().v4()}.jpg');

      await File(photo.path).copy(target);
      setState(() {
        _photo = target;
        _error = null;
      });
    }
  }

  Future<void> _locate() async {
    setState(() => _locating = true);

    final position = await _currentPosition();

    if (mounted) {
      setState(() {
        _position = position;
        _locating = false;
      });
    }
  }

  Future<Position?> _currentPosition() async {
    var permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      return null;
    }

    try {
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(timeLimit: Duration(seconds: 10)),
      );
    } on Exception {
      return Geolocator.getLastKnownPosition();
    }
  }

  Future<void> _save() async {
    final services = AppScope.of(context);
    final navigator = Navigator.of(context);
    final missing = [
      if (_name.text.trim().isEmpty) 'quién recibe',
      if (_document.text.trim().isEmpty) 'DNI',
      if (_signature.isEmpty) 'firma',
      if (_photo == null) 'foto',
    ];

    if (missing.isNotEmpty) {
      setState(() => _error = 'Falta: ${missing.join(', ')}.');

      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    final position = _position ?? await _currentPosition();

    if (position == null) {
      setState(() {
        _saving = false;
        _error = 'Hace falta la ubicación. Actívala y vuelve a confirmar.';
      });

      return;
    }

    final signaturePath = p.join(services.filesDir.path, 'signature-${const Uuid().v4()}.png');

    await _signature.saveTo(signaturePath);
    await widget.repository.complete(
      widget.stop,
      recipientName: _name.text.trim(),
      recipientDocument: _document.text.trim(),
      latitude: position.latitude,
      longitude: position.longitude,
      signaturePath: signaturePath,
      photoPath: _photo!,
    );
    unawaited(services.sync());

    navigator
      ..popUntil((route) => route.isFirst)
      ..push(
        MaterialPageRoute<void>(
          builder: (_) => StopClosedScreen(
            repository: widget.repository,
            stop: widget.stop,
            title: 'Entrega registrada',
            message: '${_name.text.trim()} recibió el paquete a las ${clockOf(DateTime.now())}.',
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final brand = AppScope.brandOf(context);
    const fieldStyle = TextStyle(fontSize: 19, fontWeight: FontWeight.w600);

    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          BrandHeader(
            brand: brand,
            title: 'Entregar',
            subtitle: '${widget.stop['ticket_code']}',
            subtitleIsCode: true,
            trailing: _LocationChip(locating: _locating, position: _position, onRetry: _locate),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                const FieldLabel('Recibe'),
                const SizedBox(height: 8),
                TextField(controller: _name, style: fieldStyle),
                const SizedBox(height: 12),
                const FieldLabel('DNI'),
                const SizedBox(height: 8),
                TextField(
                  controller: _document,
                  keyboardType: TextInputType.number,
                  style: codeStyle(20, color: Palette.ink),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Expanded(child: FieldLabel('Firma')),
                    FilledButton(
                      style: quietButton().copyWith(
                        minimumSize: const WidgetStatePropertyAll(Size(88, 44)),
                        textStyle: const WidgetStatePropertyAll(TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                      ),
                      onPressed: _signature.clear,
                      child: const Text('Borrar'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SignaturePad(controller: _signature),
                const SizedBox(height: 12),
                if (_photo == null)
                  FilledButton.icon(
                    key: const Key('deliver.photo'),
                    style: darkButton(),
                    icon: const Icon(Icons.photo_camera),
                    onPressed: _capture,
                    label: const Text('Tomar foto del paquete'),
                  )
                else
                  ItemCard(state: ItemState.ok, title: 'Foto lista', subtitle: 'Toca para cambiarla', onTap: _capture),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: Palette.bad),
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton(
                  key: const Key('deliver.confirm'),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(68)),
                  onPressed: _saving ? null : _save,
                  child: Text(_saving ? 'Guardando…' : 'Confirmar entrega'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LocationChip extends StatelessWidget {
  const _LocationChip({required this.locating, required this.position, required this.onRetry});

  final bool locating;
  final Position? position;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final ready = position != null;
    final (Color background, Color ink, String label) = locating
        ? (Palette.surface, Palette.inkSoft, 'Buscando\nubicación')
        : ready
        ? (Palette.surface, Palette.okInk, 'Ubicación\nlista')
        : (Palette.badTint, Palette.badInk, 'Sin ubicación\nReintentar');

    return Material(
      color: background,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: !locating && !ready ? onRetry : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, height: 1.1, fontWeight: FontWeight.w700, color: ink),
          ),
        ),
      ),
    );
  }
}

class NotDeliveredScreen extends StatefulWidget {
  const NotDeliveredScreen({super.key, required this.repository, required this.stop});

  final StopsRepository repository;
  final Map<String, dynamic> stop;

  @override
  State<NotDeliveredScreen> createState() => _NotDeliveredScreenState();
}

class _NotDeliveredScreenState extends State<NotDeliveredScreen> {
  final _note = TextEditingController();
  String? _reason;
  String? _error;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final services = AppScope.of(context);
    final navigator = Navigator.of(context);
    final reason = _reason;
    final note = _note.text.trim();

    if (reason == null) {
      setState(() => _error = 'Elige qué pasó.');

      return;
    }

    if (reason == _failureReasons.last && note.isEmpty) {
      setState(() => _error = 'Cuenta en la nota qué pasó.');

      return;
    }

    await widget.repository.fail(widget.stop, note.isEmpty ? reason : '$reason: $note');
    unawaited(services.sync());

    navigator
      ..popUntil((route) => route.isFirst)
      ..push(
        MaterialPageRoute<void>(
          builder: (_) => StopClosedScreen(
            repository: widget.repository,
            stop: widget.stop,
            title: 'Quedó anotado',
            message: 'No entregada: $reason.',
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final brand = AppScope.brandOf(context);

    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          BrandHeader(
            brand: brand,
            title: 'No se pudo entregar',
            subtitle: '${widget.stop['ticket_code']}',
            subtitleIsCode: true,
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                const Text('¿Qué pasó?', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                const SizedBox(height: 10),
                for (final reason in _failureReasons)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _ReasonButton(
                      label: reason,
                      selected: _reason == reason,
                      onTap: () => setState(() {
                        _reason = reason;
                        _error = null;
                      }),
                    ),
                  ),
                const SizedBox(height: 4),
                const FieldLabel('Nota (opcional)'),
                const SizedBox(height: 8),
                TextField(
                  key: const Key('stop.reason'),
                  controller: _note,
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w500),
                  decoration: const InputDecoration(hintText: 'Ej.: vuelve a las 18:00'),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: Palette.bad),
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton(
                  key: const Key('stop.fail_ok'),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(68)),
                  onPressed: _save,
                  child: const Text('Guardar y seguir'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ReasonButton extends StatelessWidget {
  const _ReasonButton({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? Palette.ink : Palette.surface,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          height: 64,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                    color: selected ? Colors.white : Palette.ink,
                  ),
                ),
              ),
              if (selected) const Icon(Icons.check, color: Colors.white),
            ],
          ),
        ),
      ),
    );
  }
}

/// Parada cerrada: confirma lo que pasó y deja lista la siguiente.
class StopClosedScreen extends StatelessWidget {
  const StopClosedScreen({
    super.key,
    required this.repository,
    required this.stop,
    required this.title,
    required this.message,
  });

  final StopsRepository repository;
  final Map<String, dynamic> stop;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final brand = AppScope.brandOf(context);

    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: repository.watch(),
      builder: (context, snapshot) {
        final stops = snapshot.data ?? const <Map<String, dynamic>>[];
        final open = stops.where(isOpen).toList()..sort((a, b) => (a['id'] as int).compareTo(b['id'] as int));
        final done = stops.length - open.length;
        final next = open.firstOrNull;

        return DoneScreen(
          brand: brand,
          title: title,
          message: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 8,
            children: [
              Text(message),
              Text('${stop['ticket_code']}', style: codeStyle(19, color: Colors.white)),
            ],
          ),
          panel: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 12,
            children: [
              Text(
                '$done de ${stops.length} hechas',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              ClipRRect(
                borderRadius: BorderRadius.circular(5),
                child: LinearProgressIndicator(
                  minHeight: 10,
                  value: stops.isEmpty ? 0 : done / stops.length,
                  color: brand.primary,
                  backgroundColor: Palette.field,
                ),
              ),
              StreamBuilder<SyncCounts>(
                stream: services.ops.watchCounts(),
                builder: (_, counts) {
                  if ((counts.data?.pending ?? 0) == 0) {
                    return const SizedBox.shrink();
                  }

                  return const ItemCard(state: ItemState.waiting, title: 'Se enviará al volver la señal');
                },
              ),
              if (next != null) ...[
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: brand.tint, borderRadius: BorderRadius.circular(18)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Siguiente parada',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: brand.dark),
                      ),
                      Text(
                        stopPlace(next),
                        style: const TextStyle(fontSize: 22, height: 1.15, fontWeight: FontWeight.w800),
                      ),
                      Text(
                        stopPerson(next),
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: Palette.inkSoft),
                      ),
                    ],
                  ),
                ),
                FilledButton(
                  key: const Key('closed.next'),
                  onPressed: () {
                    final navigator = Navigator.of(context);

                    navigator.pushReplacement(
                      MaterialPageRoute<void>(
                        builder: (_) => StopScreen(repository: repository, stop: next),
                      ),
                    );
                  },
                  child: const Text('Ir a la siguiente'),
                ),
              ],
              FilledButton(
                key: const Key('closed.home'),
                style: next == null ? null : quietButton(),
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Ver mi hoja de ruta'),
              ),
            ],
          ),
        );
      },
    );
  }
}
