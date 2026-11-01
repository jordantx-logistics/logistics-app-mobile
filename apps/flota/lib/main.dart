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
      title: 'Logistics Fleet',
      services: services,
      permission: 'routes.execute',
      home: (_) => RoutesHome(repository: repository),
    ),
  );
}

class RoutesHome extends StatelessWidget {
  const RoutesHome({super.key, required this.repository});

  final RoutesRepository repository;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My routes'), actions: const [SyncBadge()]),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: repository.watch(),
        builder: (context, snapshot) {
          final routes = snapshot.data;

          if (routes == null) {
            return const Center(child: CircularProgressIndicator());
          }

          if (routes.isEmpty) {
            return const Center(child: Text('No routes assigned. They download when there is network.'));
          }

          return ListView(
            children: [
              for (final route in routes)
                ListTile(
                  key: Key('route.${route['id']}'),
                  title: Text('${route['ticket_number']}'),
                  subtitle: Text('${route['status']}'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => RouteScreen(repository: repository, routeId: route['id'] as int),
                    ),
                  ),
                ),
            ],
          );
        },
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
        title: Text(title),
        content: TextField(
          key: const Key('route.value'),
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: label),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('Cancel')),
          FilledButton(
            key: const Key('route.value_ok'),
            onPressed: () => Navigator.pop(dialog, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _reading(
    BuildContext context,
    String title,
    Future<void> Function(String value) save,
  ) async {
    final services = AppScope.of(context);
    final value = await _ask(context, title, 'Odometer (km)');

    if (value == null || double.tryParse(value) == null) {
      return;
    }

    await save(value);
    unawaited(services.sync());
  }

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);

    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: repository.watch(),
      builder: (context, snapshot) {
        final route = snapshot.data?.where((row) => row['id'] == routeId).firstOrNull;

        if (route == null) {
          return Scaffold(appBar: AppBar(), body: const Center(child: Text('This route is no longer assigned to you.')));
        }

        final status = route['status'] as String;
        final running = status == 'in_progress';
        final segments = ((route['segments'] as List?) ?? const []).cast<Map<dynamic, dynamic>>();

        return Scaffold(
          appBar: AppBar(title: Text('${route['ticket_number']}'), actions: const [SyncBadge()]),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text('Status: $status', key: const Key('route.status')),
              const SizedBox(height: 16),
              if (status == 'assigned')
                FilledButton(
                  key: const Key('route.start'),
                  onPressed: () => _reading(context, 'Start route', (value) => repository.startRoute(route, value)),
                  child: const Text('Start route'),
                ),
              if (running) ...[
                OutlinedButton(
                  key: const Key('route.mileage'),
                  onPressed: () => _reading(context, 'Odometer reading', (value) => repository.addMileage(route, value)),
                  child: const Text('Register mileage'),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  key: const Key('route.per_diem'),
                  onPressed: () async {
                    final amount = await _ask(context, 'Per diem', 'Amount (S/)');

                    if (amount != null && double.tryParse(amount) != null) {
                      await repository.addPerDiem(route, amount);
                      unawaited(services.sync());
                    }
                  },
                  child: const Text('Add per diem'),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  key: const Key('route.fuel'),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (_) => FuelScreen(repository: repository, route: route)),
                  ),
                  child: const Text('Add fuel'),
                ),
                const SizedBox(height: 8),
                FilledButton(
                  key: const Key('route.finish'),
                  onPressed: () => _reading(context, 'Finish route', (value) => repository.finishRoute(route, value)),
                  child: const Text('Finish route'),
                ),
              ],
              const Divider(height: 32),
              Text('Segments', style: Theme.of(context).textTheme.titleMedium),
              for (final segment in segments)
                CheckboxListTile(
                  key: Key('segment.${segment['id']}'),
                  value: segment['status'] == 'completed',
                  title: Text('Segment ${segment['sequence']}'),
                  subtitle: Text('${segment['distance_km']} km'),
                  onChanged: running && segment['status'] != 'completed'
                      ? (_) async {
                          await repository.completeSegment(route, segment['id'] as int);
                          unawaited(services.sync());
                        }
                      : null,
                ),
            ],
          ),
        );
      },
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

  Future<void> _capture() async {
    final dir = AppScope.of(context).filesDir;
    final photo = await ImagePicker().pickImage(source: ImageSource.camera, maxWidth: 1600, imageQuality: 70);

    if (photo != null) {
      final target = p.join(dir.path, 'receipt-${const Uuid().v4()}.jpg');

      await File(photo.path).copy(target);
      setState(() => _receipt = target);
    }
  }

  Future<void> _save() async {
    final services = AppScope.of(context);

    if (double.tryParse(_amount.text) == null || double.tryParse(_liters.text) == null || _receipt == null) {
      setState(() => _error = 'Amount, liters and the receipt photo are required.');

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
    }
  }

  @override
  Widget build(BuildContext context) {
    const decimal = TextInputType.numberWithOptions(decimal: true);

    return Scaffold(
      appBar: AppBar(title: const Text('Add fuel')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(controller: _amount, keyboardType: decimal, decoration: const InputDecoration(labelText: 'Amount (S/)')),
          const SizedBox(height: 12),
          TextField(controller: _liters, keyboardType: decimal, decoration: const InputDecoration(labelText: 'Liters')),
          const SizedBox(height: 12),
          TextField(controller: _odometer, keyboardType: decimal, decoration: const InputDecoration(labelText: 'Odometer (optional)')),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _capture,
            icon: Icon(_receipt == null ? Icons.photo_camera : Icons.check),
            label: Text(_receipt == null ? 'Take receipt photo' : 'Receipt attached'),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          const SizedBox(height: 16),
          FilledButton(onPressed: _save, child: const Text('Save')),
        ],
      ),
    );
  }
}
