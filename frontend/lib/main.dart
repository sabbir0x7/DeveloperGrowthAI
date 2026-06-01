import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/router.dart';
import 'core/supabase_client.dart';
import 'core/theme.dart';
import 'features/auth/presentation/providers.dart';
import 'features/dashboard/presentation/providers.dart' show settingsProvider;
import 'features/onboarding/presentation/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initSupabase();
  runApp(const ProviderScope(child: DevGrowthApp()));
}

/// Root widget for the DevGrowth AI Flutter app.
///
/// Wires together:
///   - `core/theme.dart`           dark + neon ColorScheme via [buildDarkTheme]
///   - `core/supabase_client.dart` Supabase init + session stream
///   - `core/router.dart`          GoRouter + Route_Guard
///   - feature providers           auth / profile / settings / analysis
class DevGrowthApp extends ConsumerStatefulWidget {
  const DevGrowthApp({super.key});

  @override
  ConsumerState<DevGrowthApp> createState() => _DevGrowthAppState();
}

class _DevGrowthAppState extends ConsumerState<DevGrowthApp> {
  late final GoRouter _router;
  late final _AuthRefreshNotifier _refreshNotifier;

  @override
  void initState() {
    super.initState();
    _refreshNotifier = _AuthRefreshNotifier();
    _router = buildRouter(
      hasSession: () => ref.read(hasSessionProvider),
      profile: () => ref.read(routeGuardProfileProvider),
      refreshListenable: _refreshNotifier,
    );
  }

  @override
  void dispose() {
    _refreshNotifier.dispose();
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Watch auth + profile + settings so the widget rebuilds and the
    // refresh notifier fires when any changes.
    ref.listen(authProvider, (_, __) => _refreshNotifier.notify());
    ref.listen(profileProvider, (_, __) => _refreshNotifier.notify());
    ref.listen(settingsProvider, (_, __) => _refreshNotifier.notify());

    return MaterialApp.router(
      title: 'DevGrowth AI',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: buildDarkTheme(),
      theme: buildDarkTheme(),
      routerConfig: _router,
    );
  }
}

/// A [ChangeNotifier] that fires whenever auth or profile state changes,
/// causing GoRouter to re-evaluate its redirect.
class _AuthRefreshNotifier extends ChangeNotifier {
  void notify() {
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    notifyListeners();
  }
}
