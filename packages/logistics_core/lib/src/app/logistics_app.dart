import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/api_client.dart';
import '../auth/pin_lock.dart';
import '../auth/session.dart';
import '../db/app_database.dart';
import 'app_services.dart';
import 'app_theme.dart';
import 'brand.dart';
import 'sync_widgets.dart';
import 'widgets.dart';

/// Acceso a los servicios desde cualquier pantalla.
class AppScope extends InheritedWidget {
  const AppScope({super.key, required this.services, required this.brand, required super.child});

  final AppServices services;
  final AppBrand brand;

  static AppServices of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()!.services;

  static AppBrand brandOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()!.brand;

  @override
  bool updateShouldNotify(AppScope oldWidget) => services != oldWidget.services || brand != oldWidget.brand;
}

/// Raíz común: inicio de sesión → PIN → la pantalla de la app. Bloquea al volver de
/// segundo plano tras [lockAfter].
class LogisticsApp extends StatefulWidget {
  const LogisticsApp({
    super.key,
    required this.brand,
    required this.services,
    required this.permission,
    required this.home,
    this.lockAfter = const Duration(minutes: 5),
  });

  final AppBrand brand;
  final AppServices services;

  /// Permiso sin el que esta app no sirve a esa cuenta.
  final String permission;
  final WidgetBuilder home;
  final Duration lockAfter;

  @override
  State<LogisticsApp> createState() => _LogisticsAppState();
}

class _LogisticsAppState extends State<LogisticsApp> with WidgetsBindingObserver {
  final _navigator = GlobalKey<NavigatorState>();
  late final StreamSubscription<SessionStatus> _subscription;
  DateTime? _pausedAt;
  bool _restored = false;

  AppServices get _services => widget.services;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _subscription = _services.session.changes.listen(_onSession);
    unawaited(_restore());
  }

  Future<void> _restore() async {
    await _services.session.restore();

    if (mounted) {
      setState(() => _restored = true);
    }
  }

  void _onSession(SessionStatus status) {
    if (status == SessionStatus.unlocked) {
      _services.startBackgroundSync();
      // El perfil puede estar desactualizado; sin red se sigue con el guardado.
      unawaited(_refreshProfile());
    } else {
      _services.stopBackgroundSync();
      // El login y el PIN son la raíz: una pantalla abierta los taparía y seguiría a la
      // vista con la sesión cerrada o la app bloqueada.
      _navigator.currentState?.popUntil((route) => route.isFirst);
    }

    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _refreshProfile() async {
    try {
      await _services.session.refreshProfile();

      if (mounted) {
        setState(() {});
      }
    } on ApiException {
      // Se conserva el perfil guardado.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _pausedAt = DateTime.now();
    }

    if (state == AppLifecycleState.resumed) {
      final paused = _pausedAt;
      _pausedAt = null;

      if (paused != null && DateTime.now().difference(paused) >= widget.lockAfter) {
        _services.session.lock();
      } else {
        unawaited(_services.sync());
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_subscription.cancel());
    super.dispose();
  }

  Widget _screen(BuildContext context) {
    if (!_restored) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final session = _services.session;

    return switch (session.current) {
      SessionStatus.signedOut => LoginScreen(brand: widget.brand, session: session),
      SessionStatus.needsPin => PinScreen(brand: widget.brand, session: session, creating: true),
      SessionStatus.locked => PinScreen(brand: widget.brand, session: session, creating: false),
      SessionStatus.unlocked =>
        session.user != null && !session.user!.can(widget.permission)
            ? _ForbiddenScreen(session: session, brand: widget.brand)
            : widget.home(context),
    };
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      services: _services,
      brand: widget.brand,
      child: MaterialApp(
        title: widget.brand.name,
        navigatorKey: _navigator,
        debugShowCheckedModeBanner: false,
        theme: logisticsTheme(widget.brand),
        // Toda cabecera lleva un color fuerte o la cámara: la barra del sistema va en claro.
        builder: (_, child) => AnnotatedRegion<SystemUiOverlayStyle>(value: SystemUiOverlayStyle.light, child: child!),
        home: Builder(builder: _screen),
      ),
    );
  }
}

/// Entrada y PIN: toda la pantalla es del color de la app, con el formulario abajo.
class _BrandedEntry extends StatelessWidget {
  const _BrandedEntry({required this.brand, required this.title, required this.message, required this.form});

  final AppBrand brand;
  final String title;
  final String message;
  final Widget form;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: brand.primary,
      body: SafeArea(
        bottom: false,
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: IntrinsicHeight(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(28, 32, 28, 28),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.end,
                          spacing: 14,
                          children: [
                            LogoMark(brand: brand, size: 88),
                            Text(
                              title,
                              style: const TextStyle(
                                fontSize: 52,
                                height: 1,
                                fontWeight: FontWeight.w800,
                                color: Colors.white,
                              ),
                            ),
                            Text(
                              message,
                              style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w500, color: Colors.white),
                            ),
                          ],
                        ),
                      ),
                    ),
                    DecoratedBox(
                      decoration: const BoxDecoration(
                        color: Palette.surface,
                        borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
                      ),
                      child: Padding(padding: const EdgeInsets.fromLTRB(24, 28, 24, 32), child: form),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.brand, required this.session});

  final AppBrand brand;
  final SessionController session;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await widget.session.signIn(_email.text.trim(), _password.text);
    } on ApiException catch (error) {
      if (mounted) {
        setState(() {
          _error = error.isNetwork
              ? 'Sin conexión. Para entrar necesitas internet.'
              : error.statusCode == 429
              ? 'Demasiados intentos. Espera un minuto y vuelve a probar.'
              : 'Correo o contraseña incorrectos.';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return _BrandedEntry(
      brand: widget.brand,
      title: widget.brand.name,
      message: widget.brand.tagline,
      form: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const FieldLabel('Correo'),
          const SizedBox(height: 8),
          TextField(
            key: const Key('login.email'),
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.username],
            textInputAction: TextInputAction.next,
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w500),
            decoration: const InputDecoration(hintText: 'tu@empresa.pe'),
          ),
          const SizedBox(height: 16),
          const FieldLabel('Contraseña'),
          const SizedBox(height: 8),
          TextField(
            key: const Key('login.password'),
            controller: _password,
            obscureText: true,
            autofillHints: const [AutofillHints.password],
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w500),
            onSubmitted: (_) => _submit(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Palette.bad),
            ),
          ],
          const SizedBox(height: 20),
          FilledButton(
            key: const Key('login.submit'),
            onPressed: _busy ? null : _submit,
            child: Text(_busy ? 'Entrando…' : 'Entrar'),
          ),
        ],
      ),
    );
  }
}

/// Crea o pide el PIN local.
class PinScreen extends StatefulWidget {
  const PinScreen({super.key, required this.brand, required this.session, required this.creating});

  final AppBrand brand;
  final SessionController session;
  final bool creating;

  @override
  State<PinScreen> createState() => _PinScreenState();
}

class _PinScreenState extends State<PinScreen> {
  final _pin = TextEditingController();
  final _focus = FocusNode();
  String? _error;

  @override
  void dispose() {
    _pin.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final value = _pin.text;

    if (widget.creating) {
      if (value.length < PinLock.minLength || int.tryParse(value) == null) {
        setState(() => _error = 'Usa al menos ${PinLock.minLength} números.');
        _focus.requestFocus();

        return;
      }

      await widget.session.createPin(value);

      return;
    }

    if (!await widget.session.unlock(value) && mounted) {
      setState(() {
        _pin.clear();
        _error = 'PIN incorrecto. Si fallas varias veces, espera un minuto y vuelve a probar.';
      });
      _focus.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    return _BrandedEntry(
      brand: widget.brand,
      title: widget.creating ? 'Crea tu PIN' : 'Hola de nuevo',
      message: widget.creating ? 'Lo usarás para volver a abrir la app.' : 'Escribe tu PIN para continuar.',
      form: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const FieldLabel('PIN'),
          const SizedBox(height: 8),
          TextField(
            key: const Key('pin.value'),
            controller: _pin,
            focusNode: _focus,
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.number,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700, letterSpacing: 6),
            decoration: InputDecoration(errorText: _error),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 20),
          FilledButton(
            key: const Key('pin.submit'),
            onPressed: _submit,
            child: Text(widget.creating ? 'Guardar PIN' : 'Entrar'),
          ),
          if (!widget.creating) ...[
            const SizedBox(height: 8),
            TextButton(onPressed: widget.session.signOut, child: const Text('Entrar con otra cuenta')),
          ],
        ],
      ),
    );
  }
}

/// Botón de la cabecera que abre la cuenta: quién soy, envíos y cerrar sesión.
class AccountButton extends StatelessWidget {
  const AccountButton({super.key});

  @override
  Widget build(BuildContext context) {
    return HeaderButton(
      key: const Key('account.open'),
      icon: Icons.person,
      tooltip: 'Mi cuenta y cerrar sesión',
      color: AppScope.brandOf(context).dark,
      onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AccountScreen())),
    );
  }
}

class AccountScreen extends StatelessWidget {
  const AccountScreen({super.key});

  Future<void> _signOut(BuildContext context) async {
    final services = AppScope.of(context);
    final pending = await services.ops.all([OpStatus.pending, OpStatus.conflict]);

    if (pending.isNotEmpty && context.mounted) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: const Text('Tienes registros sin enviar'),
          content: Text(
            '${pending.length} ${pending.length == 1 ? 'registro queda' : 'registros quedan'} en este equipo '
            'y se enviarán cuando vuelvas a entrar.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Quedarme')),
            TextButton(onPressed: () => Navigator.pop(dialog, true), child: const Text('Cerrar sesión')),
          ],
        ),
      );

      if (confirmed != true) {
        return;
      }
    }

    await services.session.signOut();
  }

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final brand = AppScope.brandOf(context);
    final user = services.session.user;

    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          BrandHeader(brand: brand, title: user?.name ?? 'Mi cuenta', subtitle: user?.email),
          Expanded(
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 12,
                  children: [
                    if (user != null && user.agencyNames.isNotEmpty) ...[
                      const SectionLabel('Tus agencias'),
                      for (final name in user.agencyNames.values)
                        ItemCard(
                          state: ItemState.neutral,
                          brand: brand,
                          title: name,
                          leadingText: name.characters.first,
                        ),
                    ],
                    const SyncSummaryCard(),
                    FilledButton(
                      style: darkButton(),
                      onPressed: () =>
                          Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SyncScreen())),
                      child: const Text('Ver envíos'),
                    ),
                    const Spacer(),
                    FilledButton(
                      key: const Key('account.signout'),
                      style: quietButton(),
                      onPressed: () => _signOut(context),
                      child: const Text('Cerrar sesión'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ForbiddenScreen extends StatelessWidget {
  const _ForbiddenScreen({required this.session, required this.brand});

  final SessionController session;
  final AppBrand brand;

  @override
  Widget build(BuildContext context) {
    return _BrandedEntry(
      brand: brand,
      title: brand.name,
      message: 'Esta cuenta no tiene acceso a ${brand.name}.',
      form: FilledButton(onPressed: session.signOut, child: const Text('Entrar con otra cuenta')),
    );
  }
}
