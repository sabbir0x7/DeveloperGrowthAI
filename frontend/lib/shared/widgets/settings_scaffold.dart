/// A scaffold wrapper that shows a settings gear icon in the top-right
/// corner on every authenticated screen (setup-key, connect, goal, dashboard).
///
/// Wrapping a screen in [SettingsScaffold] gives it a settings drawer
/// accessible from any page, so the user can update their AI key at any
/// time during onboarding — not just from the dashboard.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../features/dashboard/presentation/settings_drawer.dart';
import '../widgets/gradient_text.dart';

/// Wraps [body] in a [Scaffold] with a settings end-drawer and an
/// optional AppBar title. The settings gear icon is always visible in
/// the top-right corner.
class SettingsScaffold extends ConsumerStatefulWidget {
  const SettingsScaffold({
    super.key,
    required this.body,
    this.title,
    this.showKeyBanner = false,
  });

  /// The main screen content.
  final Widget body;

  /// Optional AppBar title text. If null, no AppBar is shown — the
  /// settings icon floats as an overlay in the top-right corner.
  final String? title;

  /// When true, passes the banner flag to the settings drawer so it
  /// shows the "please configure your AI key" prompt.
  final bool showKeyBanner;

  @override
  ConsumerState<SettingsScaffold> createState() => _SettingsScaffoldState();
}

class _SettingsScaffoldState extends ConsumerState<SettingsScaffold> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: Colors.transparent,
      endDrawer: SettingsDrawer(showKeyBanner: widget.showKeyBanner),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: widget.title != null
            ? GradientText(
                widget.title!,
                style: theme.textTheme.titleMedium,
              )
            : null,
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.settings_outlined, color: kNeonCyan),
            onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
            tooltip: 'Settings',
          ),
        ],
      ),
      body: widget.body,
    );
  }
}
