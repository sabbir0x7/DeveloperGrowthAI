/// The email + OTP login screen.
///
/// Implements a two-step state machine that backs the OTP login flow
/// described in `design.md` and Requirements 1.1 / 1.2:
///
/// 1. **Enter email** — user submits an email address; the screen calls
///    `supabase.auth.signInWithOtp(email: ...)` so Supabase emails them
///    a one-time password (Requirement 1.1).
/// 2. **Enter OTP** — user submits the 8-digit code; the screen calls
///    `supabase.auth.verifyOTP(email: ..., token: ..., type: OtpType.email)`
///    to exchange the code for a Supabase JWT (Requirement 1.2).
///
/// On success the Route_Guard in `core/router.dart` picks up the new
/// session via `authProvider` and forwards the user into onboarding or
/// the dashboard. This screen therefore does **not** push a route on
/// successful verification; it just lets the auth state stream do its
/// job.
///
/// The screen also satisfies the visual contract for top-level
/// authenticated entry points:
///   * [AnimatedBackground] — Requirement 10.5.
///   * [GradientText] heading — Requirement 10.4.
///   * [GlassCard] form container — Requirement 10.2.
///   * [NeonButton] primary CTA — Requirement 10.3.
///
/// Testability: the actual Supabase calls are routed through a small
/// [LoginAuthHandler] abstraction so widget tests can pump the screen
/// without standing up a real Supabase client. The default
/// implementation, [_SupabaseLoginAuthHandler], delegates to the
/// shared `supabase` getter from `core/supabase_client.dart`.
///
/// **Validates: Requirements 1.1, 1.2, 10.4, 10.5**
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/supabase_client.dart';
import '../../../core/theme.dart';
import '../../../shared/widgets/animated_background.dart';
import '../../../shared/widgets/glass_card.dart';
import '../../../shared/widgets/gradient_text.dart';
import '../../../shared/widgets/neon_button.dart';

/// Steps of the login state machine.
///
/// `enterEmail` is the initial state where the user types an email;
/// `enterOtp` is the post-`signInWithOtp` state where the user types
/// the 8-digit token Supabase emailed them.
enum LoginStep { enterEmail, enterOtp }

/// Thin abstraction over the two Supabase auth methods this screen
/// depends on.
///
/// The screen takes one of these via its constructor so widget tests
/// can pass a no-op or fake handler. Production code uses the default
/// [_SupabaseLoginAuthHandler] which delegates to the real client.
abstract class LoginAuthHandler {
  /// Calls `supabase.auth.signInWithOtp(email: email)`.
  Future<void> sendOtp(String email);

  /// Calls `supabase.auth.verifyOTP(email: email, token: token, type: OtpType.email)`.
  Future<void> verifyOtp({required String email, required String token});
}

/// Default [LoginAuthHandler] that talks to Supabase.
class _SupabaseLoginAuthHandler implements LoginAuthHandler {
  const _SupabaseLoginAuthHandler();

  @override
  Future<void> sendOtp(String email) {
    return supabase.auth.signInWithOtp(email: email);
  }

  @override
  Future<void> verifyOtp({required String email, required String token}) {
    return supabase.auth.verifyOTP(
      email: email,
      token: token,
      type: OtpType.email,
    );
  }
}

/// Email regex used by [LoginScreen] form validation.
///
/// Intentionally pragmatic: a single `@`, at least one character on
/// either side, and a `.` somewhere in the domain. The authoritative
/// check is Supabase's own server-side validation; this just keeps the
/// UX honest.
final RegExp _kEmailRegex = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

/// 8-digit OTP regex used by [LoginScreen] form validation.
final RegExp _kOtpRegex = RegExp(r'^\d{8}$');

/// Email + OTP login screen.
///
/// See the library doc-comment for the full contract.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({
    super.key,
    LoginAuthHandler? authHandler,
  }) : _authHandler = authHandler ?? const _SupabaseLoginAuthHandler();

  /// Auth handler used for the OTP send/verify calls. Defaults to the
  /// real Supabase implementation; widget tests inject a fake.
  final LoginAuthHandler _authHandler;

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _otpController = TextEditingController();

  LoginStep _step = LoginStep.enterEmail;
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _emailController.dispose();
    _otpController.dispose();
    super.dispose();
  }

  String? _validateEmail(String? value) {
    final String trimmed = (value ?? '').trim();
    if (trimmed.isEmpty) {
      return 'Email is required';
    }
    if (!_kEmailRegex.hasMatch(trimmed)) {
      return 'Enter a valid email address';
    }
    return null;
  }

  String? _validateOtp(String? value) {
    final String trimmed = (value ?? '').trim();
    if (trimmed.isEmpty) {
      return 'Enter the 8-digit code';
    }
    if (!_kOtpRegex.hasMatch(trimmed)) {
      return 'Code must be 8 digits';
    }
    return null;
  }

  Future<void> _submit() async {
    if (_loading) {
      return;
    }
    final FormState? form = _formKey.currentState;
    if (form == null || !form.validate()) {
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      if (_step == LoginStep.enterEmail) {
        final String email = _emailController.text.trim();
        await widget._authHandler.sendOtp(email);
        if (!mounted) {
          return;
        }
        setState(() {
          _step = LoginStep.enterOtp;
        });
      } else {
        final String email = _emailController.text.trim();
        final String token = _otpController.text.trim();
        await widget._authHandler.verifyOtp(email: email, token: token);
        // On success the Route_Guard reacts to authProvider and routes
        // the user away from /login automatically.
      }
    } on AuthException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = e.message;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'Something went wrong. Please try again.';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Something went wrong. Please try again.')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  void _backToEmail() {
    setState(() {
      _step = LoginStep.enterEmail;
      _otpController.clear();
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool isOtpStep = _step == LoginStep.enterOtp;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AnimatedBackground(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    // Top-level gradient heading (Requirement 10.4).
                    GradientText(
                      'DevGrowth AI',
                      style: theme.textTheme.displaySmall,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      isOtpStep
                          ? 'Enter the 8-digit code we just emailed you.'
                          : 'Sign in with a one-time code sent to your email.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 24),
                    GlassCard(
                      padding: const EdgeInsets.all(20),
                      child: Form(
                        key: _formKey,
                        autovalidateMode: AutovalidateMode.onUserInteraction,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            TextFormField(
                              controller: _emailController,
                              enabled: !isOtpStep && !_loading,
                              keyboardType: TextInputType.emailAddress,
                              textInputAction: TextInputAction.next,
                              autocorrect: false,
                              autofillHints: const <String>[AutofillHints.email],
                              decoration: const InputDecoration(
                                labelText: 'Email',
                                hintText: 'you@example.com',
                                prefixIcon: Icon(Icons.alternate_email),
                                border: OutlineInputBorder(),
                              ),
                              validator: _validateEmail,
                            ),
                            if (isOtpStep) ...<Widget>[
                              const SizedBox(height: 16),
                              TextFormField(
                                controller: _otpController,
                                enabled: !_loading,
                                keyboardType: TextInputType.number,
                                textInputAction: TextInputAction.done,
                                autofocus: true,
                                maxLength: 8,
                                inputFormatters: <TextInputFormatter>[
                                  FilteringTextInputFormatter.digitsOnly,
                                ],
                                autofillHints: const <String>[
                                  AutofillHints.oneTimeCode,
                                ],
                                decoration: const InputDecoration(
                                  labelText: 'One-time code',
                                  hintText: '123456',
                                  counterText: '',
                                  prefixIcon: Icon(Icons.lock_outline),
                                  border: OutlineInputBorder(),
                                ),
                                validator: _validateOtp,
                                onFieldSubmitted: (_) => _submit(),
                              ),
                            ],
                            if (_error != null) ...<Widget>[
                              const SizedBox(height: 12),
                              Text(
                                _error!,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: kNeonPink,
                                ),
                              ),
                            ],
                            const SizedBox(height: 20),
                            NeonButton(
                              label: isOtpStep ? 'Verify code' : 'Send code',
                              onPressed: _loading ? null : _submit,
                              isLoading: _loading,
                              icon: isOtpStep
                                  ? Icons.check_circle_outline
                                  : Icons.email_outlined,
                            ),
                            if (isOtpStep) ...<Widget>[
                              const SizedBox(height: 8),
                              TextButton(
                                onPressed: _loading ? null : _backToEmail,
                                child: const Text('Use a different email'),
                              ),
                            ],
                          ],
                        ),
                      ),
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
