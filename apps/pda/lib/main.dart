import 'package:flutter/material.dart';
import 'package:logistics_core/logistics_core.dart';

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
      title: 'Logistics PDA',
      services: services,
      permission: 'tracking.scan',
      home: (_) => PdaHome(embarks: repository),
    ),
  );
}

class PdaHome extends StatelessWidget {
  const PdaHome({super.key, required this.embarks});

  final EmbarksRepository embarks;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Warehouse'), actions: const [SyncBadge()]),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          for (final type in ScanType.values)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: OutlinedButton.icon(
                key: Key('pda.${type.code}'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => ScanScreen(type: type, embarks: embarks)),
                ),
                icon: Icon(type.icon),
                label: Text(type.label),
              ),
            ),
        ],
      ),
    );
  }
}
