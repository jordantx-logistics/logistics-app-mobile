import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:logistics_core/logistics_core.dart';

import 'attendance.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final services = await AppServices.create(
    appName: 'logistics_corporate',
    appVersion: '1.0.0',
    channels: (api, _) => [AttendanceChannel(api)],
  );

  services.onPull = () => refreshHistory(services);

  runApp(
    LogisticsApp(
      title: 'Logistics Staff',
      services: services,
      permission: 'attendance.register',
      home: (_) => const AttendanceHome(),
    ),
  );
}

class AttendanceHome extends StatefulWidget {
  const AttendanceHome({super.key});

  @override
  State<AttendanceHome> createState() => _AttendanceHomeState();
}

class _AttendanceHomeState extends State<AttendanceHome> {
  String? _message;

  /// La ubicación es opcional: sin permiso o sin señal la marcación se registra igual.
  Future<Position?> _position() async {
    try {
      var permission = await Geolocator.checkPermission();

      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        return null;
      }

      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(timeLimit: Duration(seconds: 5)),
      );
    } on Exception {
      return null;
    }
  }

  Future<void> _mark(String type) async {
    final services = AppScope.of(context);
    final user = services.session.user;

    if (user?.employeeId == null || user?.employeeAgencyId == null) {
      setState(() => _message = 'Your account has no employee record. Contact HR.');

      return;
    }

    final position = await _position();

    await recordAttendance(
      ops: services.ops,
      employeeId: user!.employeeId!,
      agencyId: user.employeeAgencyId!,
      type: type,
      latitude: position?.latitude,
      longitude: position?.longitude,
    );

    if (mounted) {
      setState(() => _message = type == 'in' ? 'Check-in saved.' : 'Check-out saved.');
    }

    unawaited(services.sync());
  }

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(services.session.user?.name ?? 'Attendance'), actions: const [SyncBadge()]),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FilledButton.icon(
              key: const Key('attendance.in'),
              onPressed: () => _mark('in'),
              icon: const Icon(Icons.login),
              label: const Text('Check in'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: const Key('attendance.out'),
              onPressed: () => _mark('out'),
              icon: const Icon(Icons.logout),
              label: const Text('Check out'),
            ),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(_message!, key: const Key('attendance.message')),
              ),
            const Divider(height: 32),
            Text('History', style: Theme.of(context).textTheme.titleMedium),
            Expanded(
              child: StreamBuilder<List<LocalOp>>(
                stream: services.ops.watch([OpStatus.pending, OpStatus.conflict], kind: attendanceKind),
                builder: (context, pending) => StreamBuilder<List<Map<String, dynamic>>>(
                  stream: services.cache.watchAll(historyNamespace),
                  builder: (context, history) {
                    final rows = mergeHistory(pending.data ?? const [], history.data ?? const []);

                    if (rows.isEmpty) {
                      return const Center(child: Text('No attendance yet.'));
                    }

                    return ListView.builder(
                      itemCount: rows.length,
                      itemBuilder: (_, index) {
                        final row = rows[index];

                        return ListTile(
                          leading: Icon(row.type == 'in' ? Icons.login : Icons.logout),
                          title: Text(row.type == 'in' ? 'Check in' : 'Check out'),
                          subtitle: Text(row.at.toLocal().toString().substring(0, 16)),
                          trailing: Text(row.label),
                        );
                      },
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
