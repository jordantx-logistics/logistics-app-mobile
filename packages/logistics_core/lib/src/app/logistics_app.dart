import 'dart:async';

import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../auth/pin_lock.dart';
import '../auth/session.dart';
import 'app_services.dart';
import 'app_theme.dart';

/// Acceso a los servicios desde cualquier pantalla.
class AppScope extends InheritedWidget {
  const AppScope({super.key, required this.services, required super.child});

  final AppServices services;

  static AppServices of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()!.services;

  @override
  bool updateShouldNotify(AppScope oldWidget) => services != oldWidget.services;
}

/// Raíz común: inicio de sesión → PIN → la pantalla de la app. Bloquea al volver de
/// segundo plano tras [lockAfter].
class LogisticsApp extends StatefulWidget {
  const LogisticsApp({
    super.key,
    required this.title,
    required this.services,
    required this.permission,
    required this.home,
    this.lockAfter = const Duration(minutes: 5),
  });

  final String title;
  final AppServices services;

  /// Permiso sin el que esta app no sirve a esa cuenta.
  final String permission;
  final WidgetBuilder home;
  final Duration lockAfter;

  @override
  State<LogisticsApp> createState() => _LogisticsAppState();
}

class _LogisticsAppState extends State<LogisticsApp> with WidgetsBindingObserver {
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
      SessionStatus.signedOut => LoginScreen(title: widget.title, session: session),
      SessionStatus.needsPin => PinScreen(session: session, creating: true),
      SessionStatus.locked => PinScreen(session: session, creating: false),
      SessionStatus.unlocked =>
        session.user != null && !session.user!.can(widget.permission)
            ? _ForbiddenScreen(session: session, title: widget.title)
            : widget.home(context),
    };
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      services: _services,
      child: MaterialApp(
        title: widget.title,
        debugShowCheckedModeBanner: false,
        theme: logisticsTheme(),
        home: Builder(builder: _screen),
      ),
    );
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.title, required this.session});

  final String title;
  final SessionController session;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

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
          _error = error.isNetwork ? 'No connection. Signing in requires network.' : error.message;
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
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const SizedBox(height: 48),
            Text(widget.title, style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 32),
            TextField(
              key: const Key('login.email'),
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.username],
              decoration: const InputDecoration(labelText: 'Email'),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('login.password'),
              controller: _password,
              obscureText: true,
              autofillHints: const [AutofillHints.password],
              decoration: const InputDecoration(labelText: 'Password'),
              onSubmitted: (_) => _submit(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: 24),
            FilledButton(
              key: const Key('login.submit'),
              onPressed: _busy ? null : _submit,
              child: Text(_busy ? 'Signing in…' : 'Sign in'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Crea o pide el PIN local.
class PinScreen extends StatefulWidget {
  const PinScreen({super.key, required this.session, required this.creating});

  final SessionController session;
  final bool creating;

  @override
  State<PinScreen> createState() => _PinScreenState();
}

class _PinScreenState extends State<PinScreen> {
  final _pin = TextEditingController();
  String? _error;

  Future<void> _submit() async {
    final value = _pin.text;

    if (widget.creating) {
      if (value.length < PinLock.minLength || int.tryParse(value) == null) {
        setState(() => _error = 'Use at least ${PinLock.minLength} digits.');

        return;
      }

      await widget.session.createPin(value);

      return;
    }

    if (!await widget.session.unlock(value) && mounted) {
      setState(() {
        _pin.clear();
        _error = 'Wrong PIN, or too many attempts. Wait a minute and try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const SizedBox(height: 48),
            Text(
              widget.creating ? 'Create your PIN' : 'Enter your PIN',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(widget.creating ? 'You will use it to reopen the app.' : 'The app is locked.'),
            const SizedBox(height: 24),
            TextField(
              key: const Key('pin.value'),
              controller: _pin,
              autofocus: true,
              obscureText: true,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: 'PIN', errorText: _error),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 24),
            FilledButton(
              key: const Key('pin.submit'),
              onPressed: _submit,
              child: Text(widget.creating ? 'Save PIN' : 'Unlock'),
            ),
            if (!widget.creating)
              TextButton(onPressed: widget.session.signOut, child: const Text('Sign in with another account')),
          ],
        ),
      ),
    );
  }
}

class _ForbiddenScreen extends StatelessWidget {
  const _ForbiddenScreen({required this.session, required this.title});

  final SessionController session;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('This account cannot use $title.', textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: session.signOut, child: const Text('Sign out')),
            ],
          ),
        ),
      ),
    );
  }
}
