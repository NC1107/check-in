import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../../api/models.dart';
import '../../state/app_state.dart';

// Design tokens — Check-In dark design system
const _bgMain = Color(0xFF0A0A0B);
const _bgSurface = Color(0xFF1C1C1E);
const _bgSurfaceHover = Color(0xFF232326);
const _border = Color(0xFF27272A);
const _fgPrimary = Color(0xFFEDEDEF);
const _fgSecondary = Color(0xFFABABB0);
const _fgMuted = Color(0xFF848490);
const _accent = Color(0xFF5557E0);
const _accentLight = Color(0x295557E0);
const _online = Color(0xFF22C55E);
const _danger = Color(0xFFEF4444);

enum _Step { phone, profile, done }

/// AuthScreen is the stepped onboarding/signup flow that runs after the user has
/// connected to a server: verify number → set up profile → done. A login path is
/// available for returning members.
class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key});

  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  _Step _step = _Step.phone;
  bool _loginMode = false;

  final _phone = TextEditingController();
  final _name = TextEditingController();
  final _password = TextEditingController();
  DateTime? _birthday;
  XFile? _photo;

  bool _busy = false;
  String? _error;
  bool _isFirstAdmin = false;
  bool? _phoneAllowed; // null = not yet checked
  AuthResult? _pendingAuth; // captured from signup, applied on "Enter Check-In"

  @override
  void dispose() {
    _phone.dispose();
    _name.dispose();
    _password.dispose();
    super.dispose();
  }

  // --- actions ---

  Future<void> _verifyPhone() async {
    // Second tap once verified → advance to profile.
    if (_phoneAllowed == true) {
      setState(() {
        _step = _Step.profile;
        _error = null;
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await ref.read(apiProvider).checkPhone(_phone.text.trim());
      setState(() {
        _phoneAllowed = res.allowed;
        _isFirstAdmin = res.isFirstAdmin;
      });
    } on DioException catch (e) {
      setState(() => _error = _msg(e, 'Could not check that number'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _login() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await ref
          .read(apiProvider)
          .login(phone: _phone.text.trim(), password: _password.text);
      await ref.read(sessionProvider.notifier).signIn(res.token, res.user);
    } on DioException catch (e) {
      setState(() => _error = _msg(e, 'Login failed'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _finishSignup() async {
    if (_birthday == null) {
      setState(() => _error = 'Please pick your birthday.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final api = ref.read(apiProvider);
      int? mediaId;
      if (_photo != null) mediaId = await api.uploadImage(_photo!.path);
      final res = await api.signup(
        phone: _phone.text.trim(),
        name: _name.text.trim(),
        birthday: DateFormat('yyyy-MM-dd').format(_birthday!),
        password: _password.text,
        mediaId: mediaId,
      );
      // Hold the credentials so the Done screen can show before we enter the app.
      setState(() {
        _pendingAuth = res;
        _step = _Step.done;
      });
    } on DioException catch (e) {
      setState(() => _error = _msg(e, 'Sign up failed'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _enterApp() async {
    final auth = _pendingAuth;
    if (auth == null) return;
    await ref.read(sessionProvider.notifier).signIn(auth.token, auth.user);
  }

  void _back() {
    setState(() {
      _error = null;
      if (_step == _Step.profile) {
        _step = _Step.phone;
      } else {
        // From the phone step, "back" returns to the connect screen.
        ref.read(sessionProvider.notifier).setServer('');
      }
    });
  }

  Future<void> _pickPhoto() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (x != null && mounted) setState(() => _photo = x);
  }

  Future<void> _pickBirthday() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _birthday ?? DateTime(now.year - 25),
      firstDate: DateTime(1900),
      lastDate: now,
      builder: (ctx, child) => Theme(
        data: ThemeData.dark().copyWith(
          colorScheme: const ColorScheme.dark(primary: _accent, surface: _bgSurface),
        ),
        child: child!,
      ),
    );
    if (picked != null) setState(() => _birthday = picked);
  }

  // --- build ---

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgMain,
      body: SafeArea(
        child: Column(
          children: [
            if (_step != _Step.done) _header(),
            Expanded(
              child: switch (_step) {
                _Step.phone => _phoneStep(),
                _Step.profile => _profileStep(),
                _Step.done => _doneStep(),
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    // server(0) already done before this screen; phone=1, profile=2.
    final pIndex = _step == _Step.profile ? 2 : 1;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 20, 4),
      child: Row(
        children: [
          GestureDetector(
            onTap: _back,
            behavior: HitTestBehavior.opaque,
            child: const Icon(Icons.arrow_back, size: 24, color: _fgSecondary),
          ),
          const SizedBox(width: 12),
          _ProgressDot(active: pIndex >= 0),
          const SizedBox(width: 7),
          _ProgressDot(active: pIndex >= 1),
          const SizedBox(width: 7),
          _ProgressDot(active: pIndex >= 2),
        ],
      ),
    );
  }

  // ---- Step: phone verify / login ----

  Widget _phoneStep() {
    final digits = _phone.text.replaceAll(RegExp(r'\D'), '');
    final canSubmit = _loginMode
        ? (digits.length >= 7 && _password.text.isNotEmpty)
        : digits.length >= 7;
    final showStatus = !_loginMode && _phoneAllowed != null;

    return _StepScaffold(
      footer: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _PrimaryButton(
            label: _loginMode
                ? 'Log in'
                : (_phoneAllowed == true ? 'Continue' : 'Verify'),
            enabled: canSubmit && !_busy,
            busy: _busy,
            onTap: _loginMode ? _login : _verifyPhone,
          ),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: () => setState(() {
              _loginMode = !_loginMode;
              _phoneAllowed = null;
              _error = null;
            }),
            behavior: HitTestBehavior.opaque,
            child: Text(
              _loginMode ? 'New here? Verify your number' : 'Already a member? Log in',
              style: const TextStyle(color: _accent, fontWeight: FontWeight.w600, fontSize: 13),
            ),
          ),
        ],
      ),
      children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: _accentLight,
            borderRadius: BorderRadius.circular(12),
          ),
          alignment: Alignment.center,
          child: const Icon(Icons.verified_user, size: 24, color: _accent),
        ),
        const SizedBox(height: 20),
        Text(
          _loginMode ? 'Welcome back' : 'Verify your number',
          style: const TextStyle(color: _fgPrimary, fontWeight: FontWeight.w700, fontSize: 22),
        ),
        const SizedBox(height: 8),
        Text(
          _loginMode
              ? 'Enter your number and password to sign back in.'
              : "Your phone number must be on the host's invite list to join this server.",
          style: const TextStyle(color: _fgSecondary, fontSize: 14, height: 1.5),
        ),
        const SizedBox(height: 22),
        const _FieldLabel('Phone number'),
        Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 13),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: _bgSurface,
                border: Border.all(color: _border),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Text('+1',
                  style: TextStyle(color: _fgSecondary, fontWeight: FontWeight.w500, fontSize: 15)),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: _DarkInput(
                controller: _phone,
                hint: '(415) 555-0148',
                keyboardType: TextInputType.phone,
                onChanged: (_) => setState(() => _phoneAllowed = null),
              ),
            ),
          ],
        ),
        if (_loginMode) ...[
          const SizedBox(height: 16),
          const _FieldLabel('Password'),
          _DarkInput(
            controller: _password,
            hint: 'Your password',
            obscure: true,
            onChanged: (_) => setState(() {}),
          ),
        ],
        if (showStatus) _statusRow(),
        if (!_loginMode) ...[
          const SizedBox(height: 16),
          const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline, size: 17, color: _fgMuted),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Not on the list? Ask whoever set up the server to add your number.',
                  style: TextStyle(color: _fgMuted, fontSize: 12, height: 1.5),
                ),
              ),
            ],
          ),
        ],
        if (_error != null) _errorRow(_error!),
      ],
    );
  }

  Widget _statusRow() {
    final ok = _phoneAllowed == true;
    final color = ok ? _online : _danger;
    final text = ok
        ? (_isFirstAdmin
            ? "You're the first user — you'll be the host."
            : "You're on the invite list.")
        : "This number isn't on the invite list, or it's already registered.";
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Row(
        children: [
          Icon(ok ? Icons.check_circle : Icons.cancel, size: 18, color: color),
          const SizedBox(width: 7),
          Expanded(
            child: Text(text,
                style: TextStyle(color: color, fontWeight: FontWeight.w500, fontSize: 13)),
          ),
        ],
      ),
    );
  }

  // ---- Step: profile ----

  Widget _profileStep() {
    final canFinish = _name.text.trim().isNotEmpty &&
        _birthday != null &&
        _password.text.length >= 6 &&
        !_busy;
    return _StepScaffold(
      footer: _PrimaryButton(
        label: 'Finish',
        enabled: canFinish,
        busy: _busy,
        onTap: _finishSignup,
      ),
      children: [
        const Text('Set up your profile',
            style: TextStyle(color: _fgPrimary, fontWeight: FontWeight.w700, fontSize: 22)),
        const SizedBox(height: 6),
        const Text('This is how your circle will see you.',
            style: TextStyle(color: _fgSecondary, fontSize: 14, height: 1.5)),
        const SizedBox(height: 18),
        Center(
          child: GestureDetector(
            onTap: _pickPhoto,
            child: SizedBox(
              width: 104,
              height: 104,
              child: Stack(
                children: [
                  if (_photo != null)
                    ClipOval(
                      child: Image.file(File(_photo!.path),
                          width: 104, height: 104, fit: BoxFit.cover),
                    )
                  else
                    Container(
                      width: 104,
                      height: 104,
                      decoration: BoxDecoration(
                        color: _bgSurface,
                        shape: BoxShape.circle,
                        border: Border.all(color: const Color(0xFF3A3A3F), style: BorderStyle.solid),
                      ),
                      child: const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.add_a_photo, size: 26, color: _fgMuted),
                          SizedBox(height: 5),
                          Text('Add photo',
                              style: TextStyle(color: _fgMuted, fontSize: 11, fontWeight: FontWeight.w500)),
                        ],
                      ),
                    ),
                  Positioned(
                    right: 0,
                    bottom: 2,
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: _accent,
                        shape: BoxShape.circle,
                        border: Border.all(color: _bgMain, width: 3),
                      ),
                      child: const Icon(Icons.photo_camera, size: 16, color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 24),
        const _FieldLabel('Name'),
        _DarkInput(
          controller: _name,
          hint: 'Your name',
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 18),
        const _FieldLabel('Birthday'),
        GestureDetector(
          onTap: _pickBirthday,
          behavior: HitTestBehavior.opaque,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: _bgSurface,
              border: Border.all(color: _border),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Text(
                  _birthday == null ? 'Pick your birthday' : DateFormat.yMMMMd().format(_birthday!),
                  style: TextStyle(
                    color: _birthday == null ? _fgMuted : _fgPrimary,
                    fontSize: 15,
                  ),
                ),
                const Spacer(),
                const Icon(Icons.calendar_today_outlined, size: 18, color: _fgMuted),
              ],
            ),
          ),
        ),
        const SizedBox(height: 18),
        const _FieldLabel('Password'),
        _DarkInput(
          controller: _password,
          hint: 'At least 6 characters',
          obscure: true,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 10),
        const Row(
          children: [
            Icon(Icons.cake_outlined, size: 16, color: _fgMuted),
            SizedBox(width: 8),
            Text('Your circle gets a gentle reminder on your day.',
                style: TextStyle(color: _fgMuted, fontSize: 12)),
          ],
        ),
        if (_error != null) _errorRow(_error!),
      ],
    );
  }

  // ---- Step: done ----

  Widget _doneStep() {
    final sub = _isFirstAdmin
        ? 'Your server is live and ready. Invite your circle from the Admin tab, then start checking in.'
        : 'Welcome to the circle. Time to check in.';
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 0, 32, 40),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 84,
            height: 84,
            decoration: const BoxDecoration(
              color: _accent,
              shape: BoxShape.circle,
              boxShadow: [BoxShadow(color: _accentLight, blurRadius: 0, spreadRadius: 8)],
            ),
            child: const Icon(Icons.check, size: 44, color: Colors.white),
          ),
          const SizedBox(height: 26),
          const Text("You're all set",
              style: TextStyle(color: _fgPrimary, fontWeight: FontWeight.w700, fontSize: 24)),
          const SizedBox(height: 10),
          Text(
            sub,
            textAlign: TextAlign.center,
            style: const TextStyle(color: _fgSecondary, fontSize: 15, height: 1.55),
          ),
          const SizedBox(height: 34),
          _PrimaryButton(label: 'Enter Check-In', enabled: !_busy, busy: _busy, onTap: _enterApp),
        ],
      ),
    );
  }

  Widget _errorRow(String msg) => Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Text(msg, style: const TextStyle(color: _danger, fontSize: 13)),
      );
}

// ---- shared pieces ----

/// Scrollable content area with a pinned footer button, matching the design's
/// flex column (scroll body + fixed bottom action).
class _StepScaffold extends StatelessWidget {
  const _StepScaffold({required this.children, required this.footer});
  final List<Widget> children;
  final Widget footer;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(26, 16, 26, 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: footer,
        ),
      ],
    );
  }
}

class _ProgressDot extends StatelessWidget {
  const _ProgressDot({required this.active});
  final bool active;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      height: 6,
      width: active ? 22 : 6,
      decoration: BoxDecoration(
        color: active ? _accent : _border,
        borderRadius: BorderRadius.circular(9999),
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(text,
          style: const TextStyle(color: _fgMuted, fontWeight: FontWeight.w600, fontSize: 12)),
    );
  }
}

class _DarkInput extends StatelessWidget {
  const _DarkInput({
    required this.controller,
    required this.hint,
    this.keyboardType,
    this.obscure = false,
    this.onChanged,
  });

  final TextEditingController controller;
  final String hint;
  final TextInputType? keyboardType;
  final bool obscure;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      obscureText: obscure,
      onChanged: onChanged,
      style: const TextStyle(color: _fgPrimary, fontSize: 15),
      cursorColor: _accent,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: _fgMuted),
        filled: true,
        fillColor: _bgSurface,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: _border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: _accent),
        ),
      ),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({
    required this.label,
    required this.enabled,
    required this.onTap,
    this.busy = false,
  });

  final String label;
  final bool enabled;
  final VoidCallback onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton(
        onPressed: enabled ? onTap : null,
        style: FilledButton.styleFrom(
          backgroundColor: _accent,
          disabledBackgroundColor: _bgSurfaceHover,
          foregroundColor: Colors.white,
          disabledForegroundColor: _fgMuted,
          padding: const EdgeInsets.symmetric(vertical: 15),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        child: busy
            ? const SizedBox(
                height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : Text(label, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
      ),
    );
  }
}

/// _msg extracts the server's error message from a Dio error when available.
String _msg(DioException e, String fallback) {
  final data = e.response?.data;
  if (data is Map && data['error'] is String) return data['error'] as String;
  return fallback;
}
