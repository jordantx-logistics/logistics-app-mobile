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
      title: 'Logistics Delivery',
      services: services,
      permission: 'delivery.execute',
      home: (_) => StopsHome(repository: repository),
    ),
  );
}

const _open = {'assigned', 'in_progress'};

class StopsHome extends StatelessWidget {
  const StopsHome({super.key, required this.repository});

  final StopsRepository repository;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My deliveries'), actions: const [SyncBadge()]),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: repository.watch(),
        builder: (context, snapshot) {
          final stops = snapshot.data;

          if (stops == null) {
            return const Center(child: CircularProgressIndicator());
          }

          if (stops.isEmpty) {
            return const Center(child: Text('No deliveries assigned. They download when there is network.'));
          }

          return ListView(
            children: [
              for (final stop in stops)
                ListTile(
                  key: Key('stop.${stop['id']}'),
                  title: Text('${stop['recipient_name'] ?? stop['ticket_code']}'),
                  subtitle: Text('${stop['recipient_address'] ?? 'Pick up at agency'}\n${stop['status']}'),
                  isThreeLine: true,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (_) => StopScreen(repository: repository, stop: stop)),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class StopScreen extends StatelessWidget {
  const StopScreen({super.key, required this.repository, required this.stop});

  final StopsRepository repository;
  final Map<String, dynamic> stop;

  Future<void> _navigate() {
    final address = Uri.encodeQueryComponent('${stop['recipient_address']}');

    return launchUrl(
      Uri.parse('https://www.google.com/maps/search/?api=1&query=$address'),
      mode: LaunchMode.externalApplication,
    );
  }

  Future<void> _fail(BuildContext context) async {
    final services = AppScope.of(context);
    final navigator = Navigator.of(context);
    final controller = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Not delivered'),
        content: TextField(
          key: const Key('stop.reason'),
          controller: controller,
          decoration: const InputDecoration(labelText: 'Reason'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialog, controller.text.trim()), child: const Text('Save')),
        ],
      ),
    );

    if (reason != null && reason.isNotEmpty) {
      await repository.fail(stop, reason);
      unawaited(services.sync());
      navigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final open = _open.contains(stop['status']);
    final address = stop['recipient_address'];
    final phone = stop['recipient_phone'];

    return Scaffold(
      appBar: AppBar(title: Text('${stop['ticket_code']}'), actions: const [SyncBadge()]),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('${stop['recipient_name'] ?? 'Recipient unknown'}', style: Theme.of(context).textTheme.titleLarge),
          if (address != null) Text('$address'),
          if (phone != null) Text('$phone'),
          const SizedBox(height: 8),
          Text('Status: ${stop['status']}', key: const Key('stop.status')),
          const SizedBox(height: 16),
          if (address != null) ...[
            OutlinedButton.icon(onPressed: _navigate, icon: const Icon(Icons.navigation), label: const Text('Navigate')),
            const SizedBox(height: 8),
          ],
          if (stop['status'] == 'assigned') ...[
            FilledButton(
              key: const Key('stop.start'),
              onPressed: () async {
                final navigator = Navigator.of(context);

                await repository.start(stop);
                unawaited(services.sync());
                navigator.pop();
              },
              child: const Text('Start delivery'),
            ),
            const SizedBox(height: 8),
          ],
          if (open) ...[
            FilledButton(
              key: const Key('stop.complete'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => DeliverScreen(repository: repository, stop: stop)),
              ),
              child: const Text('Deliver'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(key: const Key('stop.fail'), onPressed: () => _fail(context), child: const Text('Not delivered')),
          ],
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

  @override
  void initState() {
    super.initState();
    _name.text = '${widget.stop['recipient_name'] ?? ''}';
  }

  Future<void> _capture() async {
    final dir = AppScope.of(context).filesDir;
    final photo = await ImagePicker().pickImage(source: ImageSource.camera, maxWidth: 1600, imageQuality: 70);

    if (photo != null) {
      final target = p.join(dir.path, 'photo-${const Uuid().v4()}.jpg');

      await File(photo.path).copy(target);
      setState(() => _photo = target);
    }
  }

  Future<Position?> _position() async {
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

    if (_name.text.trim().isEmpty || _document.text.trim().isEmpty || _signature.isEmpty || _photo == null) {
      setState(() => _error = 'Name, document, signature and photo are required.');

      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    final position = await _position();

    if (position == null) {
      setState(() {
        _saving = false;
        _error = 'The location is required. Allow it and try again.';
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
      ..pop()
      ..pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Deliver')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Received by')),
          const SizedBox(height: 12),
          TextField(controller: _document, decoration: const InputDecoration(labelText: 'Document')),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Signature'),
              TextButton(onPressed: _signature.clear, child: const Text('Clear')),
            ],
          ),
          SignaturePad(controller: _signature),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _capture,
            icon: Icon(_photo == null ? Icons.photo_camera : Icons.check),
            label: Text(_photo == null ? 'Take photo' : 'Photo attached'),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          const SizedBox(height: 16),
          FilledButton(onPressed: _saving ? null : _save, child: Text(_saving ? 'Saving…' : 'Confirm delivery')),
        ],
      ),
    );
  }
}
