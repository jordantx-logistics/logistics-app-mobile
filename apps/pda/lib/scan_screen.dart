import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logistics_core/logistics_core.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'scans_channel.dart';

/// Escaneo continuo. Un lector integrado escribe como teclado en el campo con foco y
/// termina con Enter; la cámara es la alternativa para equipos sin lector.
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key, required this.type, required this.embarks});

  final ScanType type;
  final EmbarksRepository embarks;

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _recent = <String>[];
  final _sessionCodes = <String>{};

  List<Map<String, dynamic>> _embarks = const [];
  int? _embarkId;
  int? _agencyId;
  bool _camera = false;
  String? _feedback;
  bool _feedbackIsError = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    if (_agencyId == null) {
      final agencies = AppScope.of(context).session.user?.agencies ?? const <int>[];
      _agencyId = agencies.isEmpty ? null : agencies.first;
    }

    if (widget.type.needsEmbark && _embarks.isEmpty) {
      unawaited(_loadEmbarks());
    }
  }

  Future<void> _loadEmbarks() async {
    final embarks = await widget.embarks.all();

    if (mounted) {
      setState(() => _embarks = embarks);
    }
  }

  Future<void> _onCode(String raw) async {
    final services = AppScope.of(context);
    final code = normalizeTicketCode(raw);

    _input.clear();
    _focus.requestFocus();

    if (code == null) {
      await _notify('Invalid code: $raw', error: true);

      return;
    }

    if (widget.type.needsEmbark && _embarkId == null) {
      await _notify('Select a manifest first.', error: true);

      return;
    }

    if (!_sessionCodes.add(code)) {
      await _notify('$code already scanned here.', error: true);

      return;
    }

    await recordScan(ops: services.ops, type: widget.type, ticketCode: code, agencyId: _agencyId, embarkId: _embarkId);

    setState(() => _recent.insert(0, code));
    await _notify('$code saved.');
    unawaited(services.sync());
  }

  Future<void> _notify(String message, {bool error = false}) async {
    setState(() {
      _feedback = message;
      _feedbackIsError = error;
    });

    await (error ? HapticFeedback.heavyImpact() : HapticFeedback.lightImpact());
    await SystemSound.play(error ? SystemSoundType.alert : SystemSoundType.click);
  }

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.type.label),
        actions: [
          IconButton(
            tooltip: 'Camera',
            onPressed: () => setState(() => _camera = !_camera),
            icon: Icon(_camera ? Icons.keyboard : Icons.qr_code_scanner),
          ),
          const SyncBadge(),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.type.needsEmbark) ...[
              DropdownButtonFormField<int>(
                key: const Key('scan.embark'),
                initialValue: _embarkId,
                decoration: const InputDecoration(labelText: 'Manifest'),
                items: [
                  for (final embark in _embarks)
                    DropdownMenuItem(
                      value: embark['id'] as int,
                      child: Text('#${embark['id']} · ${embark['route_ref'] ?? 'no route'}'),
                    ),
                ],
                onChanged: (value) => setState(() => _embarkId = value),
              ),
              if (_embarks.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('No manifests here yet. They download when there is network.'),
                ),
              const SizedBox(height: 12),
            ],
            if (_camera)
              SizedBox(
                height: 220,
                child: MobileScanner(
                  onDetect: (capture) {
                    final value = capture.barcodes.firstOrNull?.rawValue;

                    if (value != null) {
                      unawaited(_onCode(value));
                    }
                  },
                ),
              )
            else
              TextField(
                key: const Key('scan.input'),
                controller: _input,
                focusNode: _focus,
                autofocus: true,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(labelText: 'Ticket code'),
                onSubmitted: _onCode,
              ),
            if (_feedback != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  _feedback!,
                  key: const Key('scan.feedback'),
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: _feedbackIsError ? Theme.of(context).colorScheme.error : Colors.green.shade800,
                  ),
                ),
              ),
            Text('${_recent.length} scanned in this session'),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: _recent.length,
                itemBuilder: (_, index) =>
                    ListTile(dense: true, leading: const Icon(Icons.schedule, size: 18), title: Text(_recent[index])),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
