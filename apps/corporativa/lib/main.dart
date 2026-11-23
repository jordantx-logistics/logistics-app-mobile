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
      brand: AppBrand.personal,
      services: services,
      permission: 'attendance.register',
      home: (_) => const AttendanceHome(),
    ),
  );
}

const _days = ['Lunes', 'Martes', 'Miércoles', 'Jueves', 'Viernes', 'Sábado', 'Domingo'];
const _months = [
  'enero',
  'febrero',
  'marzo',
  'abril',
  'mayo',
  'junio',
  'julio',
  'agosto',
  'septiembre',
  'octubre',
  'noviembre',
  'diciembre',
];
const _shortMonths = ['ENE', 'FEB', 'MAR', 'ABR', 'MAY', 'JUN', 'JUL', 'AGO', 'SEP', 'OCT', 'NOV', 'DIC'];

/// Duración por defecto si la agencia aún no se conoce: la de la migración.
const _defaultLunch = 60;

class AttendanceHome extends StatefulWidget {
  const AttendanceHome({super.key});

  @override
  State<AttendanceHome> createState() => _AttendanceHomeState();
}

class _AttendanceHomeState extends State<AttendanceHome> {
  Timer? _clock;
  DateTime _now = DateTime.now();
  bool _saving = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 15), (_) => setState(() => _now = DateTime.now()));
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

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
      setState(() => _message = 'Tu cuenta no tiene ficha de empleado. Avisa a RR. HH.');

      return;
    }

    setState(() {
      _saving = true;
      _message = null;
    });

    final at = DateTime.now();
    final position = await _position();

    await recordAttendance(
      ops: services.ops,
      employeeId: user!.employeeId!,
      agencyId: user.employeeAgencyId!,
      type: type,
      at: at,
      latitude: position?.latitude,
      longitude: position?.longitude,
    );

    if (mounted) {
      setState(() {
        _saving = false;
        _now = DateTime.now();
      });
    }

    unawaited(services.sync());
  }

  Future<void> _confirmOutWithoutLunch() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('¿Salir sin almorzar?'),
        content: const Text('Tu jornada quedará registrada sin almuerzo.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Cancelar')),
          TextButton(onPressed: () => Navigator.pop(dialog, true), child: const Text('Marcar salida')),
        ],
      ),
    );

    if (confirmed == true) {
      await _mark(Mark.clockOut);
    }
  }

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);

    return StreamBuilder<List<LocalOp>>(
      stream: services.ops.watch([OpStatus.pending, OpStatus.conflict], kind: attendanceKind),
      builder: (context, pending) => StreamBuilder<List<Map<String, dynamic>>>(
        stream: services.cache.watchAll(historyNamespace),
        builder: (context, history) {
          final rows = mergeHistory(pending.data ?? const [], history.data ?? const []);
          final day = WorkDay.today(rows, now: _now);

          if (day.finished) {
            return _FinishedView(day: day, now: _now);
          }

          return _ActiveDayView(
            day: day,
            now: _now,
            saving: _saving,
            message: _message,
            onMark: _mark,
            onOutWithoutLunch: _confirmOutWithoutLunch,
          );
        },
      ),
    );
  }
}

class _ActiveDayView extends StatelessWidget {
  const _ActiveDayView({
    required this.day,
    required this.now,
    required this.saving,
    required this.message,
    required this.onMark,
    required this.onOutWithoutLunch,
  });

  final WorkDay day;
  final DateTime now;
  final bool saving;
  final String? message;
  final Future<void> Function(String type) onMark;
  final VoidCallback onOutWithoutLunch;

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final brand = AppScope.brandOf(context);
    final user = services.session.user;
    final minutes = day.minutes(now: now);

    return Scaffold(
      backgroundColor: day.atLunch ? brand.dark : brand.primary,
      // En pantallas pequeñas el reloj y los pasos no caben a la vez: se desplaza.
      body: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: IntrinsicHeight(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SafeArea(
                    bottom: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                      child: Row(
                        spacing: 12,
                        children: [
                          LogoMark(brand: brand),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Hola, ${user?.firstName ?? ''}',
                                  style: const TextStyle(
                                    fontSize: 24,
                                    height: 1.1,
                                    fontWeight: FontWeight.w800,
                                    color: Colors.white,
                                  ),
                                ),
                                Text(
                                  user?.agencyName(user.employeeAgencyId) ?? '',
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w500,
                                    color: Colors.white,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const AccountButton(),
                        ],
                      ),
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: day.atLunch
                          ? _LunchClock(
                              day: day,
                              now: now,
                              allowed: user?.lunchMinutes ?? _defaultLunch,
                              minutes: minutes.lunch,
                            )
                          : day.working
                          ? _WorkingClock(day: day, minutes: minutes.worked, brand: brand)
                          : _DayClock(now: now),
                    ),
                  ),
                  DecoratedBox(
                    decoration: const BoxDecoration(
                      color: Palette.ground,
                      borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
                    ),
                    child: SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          spacing: 12,
                          children: [
                            ..._actions(),
                            if (message != null)
                              Text(
                                message!,
                                key: const Key('attendance.message'),
                                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Palette.bad),
                              ),
                            const SyncSummaryCard(),
                            _Timeline(day: day),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _actions() {
    if (day.notStarted) {
      return [
        _BigAction(
          key: const Key('attendance.in'),
          icon: Icons.login,
          label: saving ? 'Guardando…' : 'Marcar entrada',
          onTap: saving ? null : () => onMark(Mark.clockIn),
        ),
      ];
    }

    if (day.atLunch) {
      return [
        _BigAction(
          key: const Key('attendance.lunch_end'),
          icon: Icons.check,
          label: saving ? 'Guardando…' : 'Ya volví',
          onTap: saving ? null : () => onMark(Mark.lunchEnd),
        ),
      ];
    }

    if (day.hadLunch) {
      return [
        _BigAction(
          key: const Key('attendance.out'),
          icon: Icons.logout,
          label: saving ? 'Guardando…' : 'Marcar salida',
          onTap: saving ? null : () => onMark(Mark.clockOut),
        ),
      ];
    }

    return [
      _BigAction(
        key: const Key('attendance.lunch_start'),
        icon: Icons.restaurant,
        label: saving ? 'Guardando…' : 'Salir a almorzar',
        onTap: saving ? null : () => onMark(Mark.lunchStart),
      ),
      FilledButton(
        key: const Key('attendance.out'),
        style: darkButton(),
        onPressed: saving ? null : onOutWithoutLunch,
        child: const Text('Marcar salida sin almuerzo'),
      ),
    ];
  }
}

class _BigAction extends StatelessWidget {
  const _BigAction({super.key, required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.primary,
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: SizedBox(
          height: 104,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            spacing: 14,
            children: [
              Icon(icon, size: 40, color: Colors.white),
              Text(
                label,
                style: const TextStyle(fontSize: 29, fontWeight: FontWeight.w800, color: Colors.white),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DayClock extends StatelessWidget {
  const _DayClock({required this.now});

  final DateTime now;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          '${_days[now.weekday - 1]} ${now.day} de ${_months[now.month - 1]}',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white),
        ),
        FittedBox(
          child: Text(
            clockOf(now),
            style: const TextStyle(fontSize: 92, height: 1.05, fontWeight: FontWeight.w800, color: Colors.white),
          ),
        ),
      ],
    );
  }
}

class _WorkingClock extends StatelessWidget {
  const _WorkingClock({required this.day, required this.minutes, required this.brand});

  final WorkDay day;
  final int minutes;
  final AppBrand brand;

  @override
  Widget build(BuildContext context) {
    final since = day.firstIn;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      spacing: 6,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(color: brand.dark, borderRadius: BorderRadius.circular(12)),
          child: const Text(
            'Estás trabajando',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: Colors.white),
          ),
        ),
        FittedBox(
          child: Text(
            durationLabel(minutes),
            style: const TextStyle(fontSize: 80, height: 1.05, fontWeight: FontWeight.w800, color: Colors.white),
          ),
        ),
        if (since != null)
          Text(
            'Entraste a las ${clockOf(since)}',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white),
          ),
      ],
    );
  }
}

/// Cuánto queda de almuerzo. Pasado el tiempo avisa, pero no bloquea: el servidor guarda
/// lo que duró y RR. HH. decide.
class _LunchClock extends StatelessWidget {
  const _LunchClock({required this.day, required this.now, required this.allowed, required this.minutes});

  final WorkDay day;
  final DateTime now;
  final int allowed;
  final int minutes;

  @override
  Widget build(BuildContext context) {
    final brand = AppScope.brandOf(context);
    final left = allowed - minutes;
    final over = left < 0;
    final since = day.timeOf(Mark.lunchStart);
    final until = since?.add(Duration(minutes: allowed));

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      spacing: 8,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(color: over ? Palette.bad : brand.primary, borderRadius: BorderRadius.circular(12)),
          child: Text(
            over ? 'Tu almuerzo ya terminó' : 'En almuerzo desde las ${since == null ? '-' : clockOf(since)}',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: Colors.white),
          ),
        ),
        FittedBox(
          child: Text(
            '${left.abs()}',
            style: const TextStyle(fontSize: 104, height: 1, fontWeight: FontWeight.w800, color: Colors.white),
          ),
        ),
        Text(
          over ? 'minutos de más' : 'minutos te quedan',
          style: const TextStyle(fontSize: 24, height: 1.1, fontWeight: FontWeight.w700, color: Colors.white),
        ),
        ClipRRect(
          borderRadius: BorderRadius.circular(7),
          child: LinearProgressIndicator(
            minHeight: 14,
            value: allowed == 0 ? 1 : (minutes / allowed).clamp(0, 1).toDouble(),
            color: Colors.white,
            backgroundColor: const Color(0xFF0B4A46),
          ),
        ),
        if (until != null)
          Text(
            'Tienes $allowed min · Vuelves antes de las ${clockOf(until)}',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: Colors.white),
          ),
      ],
    );
  }
}

/// Los cuatro pasos del día, con lo hecho y lo que sigue.
class _Timeline extends StatelessWidget {
  const _Timeline({required this.day});

  final WorkDay day;

  @override
  Widget build(BuildContext context) {
    final brand = AppScope.brandOf(context);
    final next = day.notStarted
        ? Mark.clockIn
        : day.atLunch
        ? Mark.lunchEnd
        : day.hadLunch
        ? Mark.clockOut
        : Mark.lunchStart;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      decoration: BoxDecoration(color: Palette.surface, borderRadius: BorderRadius.circular(18)),
      child: Column(
        children: [
          for (final (index, (type, label)) in const [
            (Mark.clockIn, 'Entrada'),
            (Mark.lunchStart, 'Salida a almorzar'),
            (Mark.lunchEnd, 'Vuelta del almuerzo'),
            (Mark.clockOut, 'Salida'),
          ].indexed)
            _TimelineRow(number: index + 1, label: label, doneAt: day.timeOf(type), isNext: type == next, brand: brand),
        ],
      ),
    );
  }
}

class _TimelineRow extends StatelessWidget {
  const _TimelineRow({
    required this.number,
    required this.label,
    required this.doneAt,
    required this.isNext,
    required this.brand,
  });

  final int number;
  final String label;
  final DateTime? doneAt;
  final bool isNext;
  final AppBrand brand;

  @override
  Widget build(BuildContext context) {
    final done = doneAt != null;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        spacing: 12,
        children: [
          Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: done ? Palette.ok : (isNext ? brand.primary : Palette.field),
              shape: BoxShape.circle,
            ),
            child: done
                ? const Icon(Icons.check, size: 20, color: Colors.white)
                : Text(
                    '$number',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: isNext ? Colors.white : Palette.ink,
                    ),
                  ),
          ),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 18,
                fontWeight: done || isNext ? FontWeight.w700 : FontWeight.w500,
                color: done || isNext ? Palette.ink : Palette.inkSoft,
              ),
            ),
          ),
          if (done)
            Text(clockOf(doneAt!), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700))
          else if (isNext)
            Text(
              'Sigue',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: brand.dark),
            ),
        ],
      ),
    );
  }
}

class _FinishedView extends StatelessWidget {
  const _FinishedView({required this.day, required this.now});

  final WorkDay day;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final brand = AppScope.brandOf(context);
    final user = services.session.user;

    final stamps = [
      ('Entrada', day.firstIn),
      ('Almuerzo', day.timeOf(Mark.lunchStart)),
      ('Vuelta', day.timeOf(Mark.lunchEnd)),
      ('Salida', day.timeOf(Mark.clockOut)),
    ];

    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            color: brand.primary,
            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(32)),
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 6,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Jornada completa',
                            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Colors.white),
                          ),
                        ),
                        const AccountButton(),
                      ],
                    ),
                    Text(
                      durationLabel(day.minutes(now: now).worked),
                      style: const TextStyle(fontSize: 60, height: 1, fontWeight: FontWeight.w800, color: Colors.white),
                    ),
                    Text(
                      'Trabajadas hoy · Hasta mañana, ${user?.firstName ?? ''}',
                      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: Colors.white),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      spacing: 6,
                      children: [
                        for (final (label, at) in stamps)
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(color: brand.dark, borderRadius: BorderRadius.circular(12)),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  FittedBox(
                                    child: Text(
                                      at == null ? '--:--' : clockOf(at),
                                      style: const TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.w800,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                  FittedBox(
                                    child: Text(
                                      label,
                                      style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: StreamBuilder<List<Map<String, dynamic>>>(
              stream: services.cache.watchAll(daysNamespace),
              builder: (context, snapshot) {
                final today = DateUtils.dateOnly(now);
                final days =
                    (snapshot.data ?? const <Map<String, dynamic>>[])
                        .where((row) => DateTime.tryParse('${row['work_date']}')?.isBefore(today) ?? false)
                        .toList()
                      ..sort((a, b) => '${b['work_date']}'.compareTo('${a['work_date']}'));

                return ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    const SyncSummaryCard(),
                    const SizedBox(height: 12),
                    const SectionLabel('Días anteriores'),
                    const SizedBox(height: 10),
                    if (days.isEmpty)
                      const Text('Aún no hay días anteriores.', style: TextStyle(fontSize: 17, color: Palette.inkSoft)),
                    for (final row in days)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _DayCard(row: row, allowed: user?.lunchMinutes ?? _defaultLunch, brand: brand),
                      ),
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

class _DayCard extends StatelessWidget {
  const _DayCard({required this.row, required this.allowed, required this.brand});

  final Map<String, dynamic> row;
  final int allowed;
  final AppBrand brand;

  /// El consolidado llega sin zona y en UTC, como lo guarda el servidor.
  String? _time(Object? value) {
    final raw = '${value ?? ''}'.trim();

    if (raw.isEmpty) {
      return null;
    }

    return clockOfText('${raw.replaceFirst(' ', 'T')}Z');
  }

  @override
  Widget build(BuildContext context) {
    final date = DateTime.tryParse('${row['work_date']}');
    final lunch = row['lunch_minutes'] as int? ?? 0;
    final extra = lunch - allowed;
    final from = _time(row['first_in_at']);
    final to = _time(row['last_out_at']);
    final detail = extra > 0
        ? 'Almuerzo $lunch min · $extra min de más'
        : '${from ?? '-'} a ${to ?? '-'} · ${lunch == 0 ? 'Sin almuerzo' : 'Almuerzo $lunch min'}';

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: extra > 0 ? Palette.waitTint : Palette.surface,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        spacing: 12,
        children: [
          Container(
            width: 56,
            padding: const EdgeInsets.symmetric(vertical: 7),
            decoration: BoxDecoration(
              color: extra > 0 ? Palette.wait : brand.tint,
              borderRadius: BorderRadius.circular(13),
            ),
            child: Column(
              children: [
                Text(
                  date == null ? '-' : date.day.toString().padLeft(2, '0'),
                  style: TextStyle(
                    fontSize: 22,
                    height: 1,
                    fontWeight: FontWeight.w800,
                    color: extra > 0 ? Colors.white : brand.dark,
                  ),
                ),
                Text(
                  date == null ? '' : _shortMonths[date.month - 1],
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: extra > 0 ? Colors.white : brand.dark,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  durationLabel(row['worked_minutes'] as int? ?? 0),
                  style: const TextStyle(fontSize: 20, height: 1.1, fontWeight: FontWeight.w700),
                ),
                Text(
                  detail,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: extra > 0 ? FontWeight.w600 : FontWeight.w500,
                    color: extra > 0 ? Palette.waitInk : Palette.inkSoft,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
