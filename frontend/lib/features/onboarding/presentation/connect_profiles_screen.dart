/// Connect Profiles onboarding screen.
///
/// Implements GitHub OAuth connection and LinkedIn PDF upload.
/// - "Connect GitHub" button initiates OAuth flow via a popup/new tab.
/// - "Upload LinkedIn PDF" button opens a file picker for PDF upload.
/// - "Continue" button is enabled only when GitHub is connected.
///
/// **Validates: Requirements 3.1, 3.2, 2.4**
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/providers.dart';
import '../../../shared/widgets/animated_background.dart';
import '../../../shared/widgets/glass_card.dart';
import '../../../shared/widgets/gradient_text.dart';
import '../../../shared/widgets/neon_button.dart';
import '../domain/profile.dart';
import 'providers.dart';

/// Onboarding step — connect GitHub via OAuth and upload LinkedIn PDF.
///
/// Lives at `/connect`. Wired into [GoRouter] from `core/router.dart`.
class ConnectProfilesScreen extends ConsumerStatefulWidget {
  const ConnectProfilesScreen({super.key});

  static const Key connectGithubButtonKey = Key('connect-github-button');
  static const Key uploadLinkedinButtonKey = Key('connect-linkedin-button');
  static const Key continueButtonKey = Key('connect-continue-button');
  static const Key headingKey = Key('connect-heading');

  @override
  ConsumerState<ConnectProfilesScreen> createState() =>
      _ConnectProfilesScreenState();
}

class _ConnectProfilesScreenState
    extends ConsumerState<ConnectProfilesScreen> {
  bool _githubConnected = false;
  bool _githubConnecting = false;
  bool _linkedinUploaded = false;
  bool _linkedinUploading = false;
  String? _linkedinPreview;
  bool _continuing = false;

  @override
  void initState() {
    super.initState();
    // Check if returning from GitHub OAuth with success parameter
    _checkGithubCallback();
  }

  void _checkGithubCallback() {
    // For Flutter web, check the URL fragment for github=success
    if (kIsWeb) {
      // ignore: avoid_web_libraries_in_flutter
      // The URL hash is checked via GoRouter's query parameters
      // We'll detect it from the URI
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final Uri uri = Uri.base;
        final String fragment = uri.fragment;
        if (fragment.contains('github=success')) {
          setState(() {
            _githubConnected = true;
          });
        }
      });
    }
  }

  Future<void> _connectGithub() async {
    if (_githubConnecting) return;

    setState(() => _githubConnecting = true);

    try {
      final Dio dio = ref.read(dioProvider);

      final Response<dynamic> response = await dio.get<dynamic>(
        '/api/v1/auth/github/connect',
      );

      final Map<String, dynamic> data = response.data as Map<String, dynamic>;
      final String authorizeUrl = data['authorize_url'] as String;

      // Open the GitHub OAuth URL in a new tab/window
      final Uri url = Uri.parse(authorizeUrl);
      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      }

      // After opening, we wait for the user to come back.
      // The callback will redirect to /#/connect?github=success
      // We poll or listen for the state change.
      // For simplicity, show a dialog telling the user to complete OAuth
      if (!mounted) return;
      final bool? result = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext ctx) => AlertDialog(
          title: const Text('GitHub Connection'),
          content: const Text(
            'Complete the GitHub authorization in your browser.\n\n'
            'Click "Done" once you\'ve authorized the app.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Done'),
            ),
          ],
        ),
      );

      if (result == true) {
        setState(() {
          _githubConnected = true;
        });
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to connect GitHub: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _githubConnecting = false);
      }
    }
  }

  Future<void> _uploadLinkedinPdf() async {
    if (_linkedinUploading) return;

    setState(() => _linkedinUploading = true);

    try {
      // Open file picker for PDF
      final FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: <String>['pdf'],
        withData: true,
      );

      if (result == null || result.files.isEmpty) {
        // User cancelled
        return;
      }

      final PlatformFile file = result.files.first;
      if (file.bytes == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not read file data.')),
        );
        return;
      }

      // Upload to backend
      final FormData formData = FormData.fromMap(<String, dynamic>{
        'file': MultipartFile.fromBytes(
          file.bytes!,
          filename: file.name,
        ),
      });

      final Dio dio = ref.read(dioProvider);
      final Response<dynamic> response = await dio.post<dynamic>(
        '/api/v1/profile/linkedin-pdf',
        data: formData,
      );

      final Map<String, dynamic> data = response.data as Map<String, dynamic>;
      final String preview = data['preview'] as String? ?? '';
      final int textLength = data['text_length'] as int? ?? 0;

      setState(() {
        _linkedinUploaded = true;
        _linkedinPreview = '$textLength chars extracted: $preview';
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('LinkedIn PDF uploaded ($textLength chars extracted)'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to upload PDF: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _linkedinUploading = false);
      }
    }
  }

  Future<void> _onContinue() async {
    if (_continuing || !_githubConnected) return;

    setState(() => _continuing = true);
    try {
      // Patch the profile to mark GitHub as connected
      await ref.read(profileProvider.notifier).patch(
            const ProfilePatch(
              githubUrl: 'https://github.com/connected',
              linkedinUrl: 'https://linkedin.com/in/connected',
            ),
          );
      if (!mounted) return;
      context.go('/goal');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save profile: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _continuing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AnimatedBackground(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(
                horizontal: 24,
                vertical: 32,
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: GlassCard(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      GradientText(
                        'Connect your profiles',
                        key: ConnectProfilesScreen.headingKey,
                        style: theme.textTheme.headlineMedium,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Connect your GitHub account and optionally upload '
                        'your LinkedIn PDF for a richer analysis.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 32),

                      // --- GitHub Connect ---
                      _buildConnectionCard(
                        icon: Icons.code,
                        title: 'GitHub',
                        subtitle: _githubConnected
                            ? 'Connected'
                            : 'Connect for repo analysis',
                        isConnected: _githubConnected,
                        isLoading: _githubConnecting,
                        buttonKey: ConnectProfilesScreen.connectGithubButtonKey,
                        buttonLabel:
                            _githubConnected ? 'Connected' : 'Connect GitHub',
                        onPressed: _githubConnected ? null : _connectGithub,
                      ),

                      const SizedBox(height: 16),

                      // --- LinkedIn PDF Upload ---
                      _buildConnectionCard(
                        icon: Icons.description,
                        title: 'LinkedIn PDF',
                        subtitle: _linkedinUploaded
                            ? _linkedinPreview ?? 'Uploaded'
                            : 'Upload your LinkedIn profile PDF (optional)',
                        isConnected: _linkedinUploaded,
                        isLoading: _linkedinUploading,
                        buttonKey:
                            ConnectProfilesScreen.uploadLinkedinButtonKey,
                        buttonLabel: _linkedinUploaded
                            ? 'Uploaded'
                            : 'Upload LinkedIn PDF',
                        onPressed:
                            _linkedinUploaded ? null : _uploadLinkedinPdf,
                      ),

                      const SizedBox(height: 32),

                      // --- Continue Button ---
                      Center(
                        child: NeonButton(
                          key: ConnectProfilesScreen.continueButtonKey,
                          label: 'Continue',
                          isLoading: _continuing,
                          onPressed:
                              _githubConnected && !_continuing
                                  ? _onContinue
                                  : null,
                        ),
                      ),

                      if (!_githubConnected) ...<Widget>[
                        const SizedBox(height: 8),
                        Text(
                          'Connect GitHub to continue',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurface
                                .withValues(alpha: 0.6),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildConnectionCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool isConnected,
    required bool isLoading,
    required Key buttonKey,
    required String buttonLabel,
    required VoidCallback? onPressed,
  }) {
    final ThemeData theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isConnected
              ? Colors.green.withValues(alpha: 0.5)
              : theme.colorScheme.outline.withValues(alpha: 0.3),
        ),
        color: isConnected
            ? Colors.green.withValues(alpha: 0.05)
            : theme.colorScheme.surface.withValues(alpha: 0.3),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            isConnected ? Icons.check_circle : icon,
            color: isConnected ? Colors.green : theme.colorScheme.primary,
            size: 32,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface
                        .withValues(alpha: 0.7),
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (isLoading)
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            FilledButton(
              key: buttonKey,
              onPressed: onPressed,
              child: Text(buttonLabel),
            ),
        ],
      ),
    );
  }
}
