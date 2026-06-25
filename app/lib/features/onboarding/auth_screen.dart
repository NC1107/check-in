import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../../api/api_client.dart';
import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../theme/tokens.dart';
import '../admin/contacts_picker_screen.dart';

// Theme tokens (centralized in theme/tokens.dart).
const _bgMain = kBgMain;
const _bgSurface = kBgSurface;
const _bgSurfaceHover = kBgSurfaceHover;
const _border = kBorder;
const _fgPrimary = kFgPrimary;
const _fgSecondary = kFgSecondary;
const _fgMuted = kFgMuted;
const _accent = kAccent;
const _accentLight = kAccentLight;
const _online = kSuccess;
const _danger = kLike;

enum _Step { phone, profile, invite, done }

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
  final _firstName = TextEditingController();
  final _lastName = TextEditingController();
  final _displayName = TextEditingController();
  final _password = TextEditingController();
  DateTime? _birthday;
  XFile? _photo;

  bool _busy = false;
  String? _error;
  bool _isFirstAdmin = false;
  bool? _phoneAllowed; // null = not yet checked
  AuthResult? _pendingAuth; // captured from signup, applied on "Enter Check-In"
  int? _invited; // number of invitees added on the host invite step (null = not done)
  // Whether the server already has an admin. Seeded from the connect probe, then
  // refreshed on load so a fresh server shows host-setup framing, not invite-list copy.
  bool _serverInitialized = true;

  @override
  void initState() {
    super.initState();
    _serverInitialized = ref.read(sessionProvider).serverInitialized;
    _refreshServerState();
  }

  /// Re-checks whether the server has an admin yet. Handles the case where the session
  /// was restored from disk (where the flag isn't persisted) rather than freshly probed.
  Future<void> _refreshServerState() async {
    try {
      final info = await ref.read(apiProvider).serverInfo();
      if (mounted) setState(() => _serverInitialized = info.initialized);
    } catch (_) {
      // Leave the seeded value; the verify call will still gate signup correctly.
    }
  }

  @override
  void dispose() {
    _phone.dispose();
    _firstName.dispose();
    _lastName.dispose();
    _displayName.dispose();
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
      // Sign up first — this is unauthenticated and returns the token. We can't upload the
      // photo beforehand because media upload requires auth (chicken-and-egg).
      var res = await api.signup(
        phone: _phone.text.trim(),
        firstName: _firstName.text.trim(),
        lastName: _lastName.text.trim(),
        displayName: _displayName.text.trim(),
        birthday: DateFormat('yyyy-MM-dd').format(_birthday!),
        password: _password.text,
      );
      // Now that we have a token, upload the photo and attach it. Best-effort: the account
      // already exists, so a photo failure shouldn't block finishing signup.
      if (_photo != null) {
        try {
          final baseUrl = ref.read(sessionProvider).baseUrl ?? '';
          final authed = ApiClient(baseUrl: baseUrl, token: res.token);
          final mediaId = await authed.uploadImage(_photo!.path);
          final updatedUser = await authed.setProfilePhoto(mediaId);
          res = AuthResult(token: res.token, user: updatedUser);
        } catch (_) {
          // Keep the photo-less account; the user can add a picture later.
        }
      }
      // Hold the credentials so the Done (or host invite) screen can show before we enter.
      setState(() {
        _pendingAuth = res;
        _step = _isFirstAdmin ? _Step.invite : _Step.done;
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

  /// Host invite step: pick contacts and add them to the allowlist using the freshly
  /// issued token (we haven't entered the app yet, so build an authed client by hand).
  Future<void> _pickInvitees() async {
    final phones = await Navigator.of(context).push<List<String>>(
      MaterialPageRoute(builder: (_) => const ContactsPickerScreen()),
    );
    if (phones == null || phones.isEmpty) return;
    setState(() => _busy = true);
    try {
      final baseUrl = ref.read(sessionProvider).baseUrl ?? '';
      final api = ApiClient(baseUrl: baseUrl, token: _pendingAuth!.token);
      final result = await api.uploadContacts(phones);
      setState(() => _invited = (result['added'] as int?) ?? phones.length);
    } catch (_) {
      setState(() => _error = "Couldn't add those right now — you can invite from the Admin tab later.");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
            if (_step == _Step.phone || _step == _Step.profile) _header(),
            Expanded(
              child: switch (_step) {
                _Step.phone => _phoneStep(),
                _Step.profile => _profileStep(),
                _Step.invite => _inviteStep(),
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
    // Fresh server with no admin yet → this user is claiming the host account, so show
    // setup framing instead of the invite-list verify copy, and hide the login link
    // (there are no accounts to log into yet).
    final fresh = !_serverInitialized && !_loginMode;

    return _StepScaffold(
      footer: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _PrimaryButton(
            label: _loginMode
                ? 'Log in'
                : (_phoneAllowed == true || fresh ? 'Continue' : 'Verify'),
            enabled: canSubmit && !_busy,
            busy: _busy,
            onTap: _loginMode ? _login : _verifyPhone,
          ),
          if (!fresh) ...[
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
          child: Icon(fresh ? Icons.add_moderator : Icons.verified_user, size: 24, color: _accent),
        ),
        const SizedBox(height: 20),
        Text(
          _loginMode
              ? 'Welcome back'
              : (fresh ? 'Set up your server' : 'Verify your number'),
          style: const TextStyle(color: _fgPrimary, fontWeight: FontWeight.w700, fontSize: 22),
        ),
        const SizedBox(height: 8),
        Text(
          _loginMode
              ? 'Enter your number and password to sign back in.'
              : (fresh
                  ? "You're the first here, so this account becomes the host. Enter your phone "
                      'number to claim it.'
                  : "Your phone number must be on the host's invite list to join this server."),
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
        if (!_loginMode && !fresh) ...[
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
        if (fresh) ...[
          const SizedBox(height: 16),
          const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline, size: 17, color: _fgMuted),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  "Next you'll set up your profile, then you can invite your circle.",
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
    final canFinish = _firstName.text.trim().isNotEmpty &&
        _lastName.text.trim().isNotEmpty &&
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
        const _FieldLabel('Full name'),
        Row(
          children: [
            Expanded(
              child: _DarkInput(
                controller: _firstName,
                hint: 'First',
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _DarkInput(
                controller: _lastName,
                hint: 'Last',
                onChanged: (_) => setState(() {}),
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        const _FieldLabel('Display name'),
        _DarkInput(
          controller: _displayName,
          hint: 'Optional — defaults to your full name',
        ),
        const SizedBox(height: 6),
        const Text("This is what your circle sees. Leave blank to use your full name.",
            style: TextStyle(color: _fgMuted, fontSize: 12, height: 1.4)),
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
        const SizedBox(height: 8),
        const Row(
          children: [
            Icon(Icons.cake_outlined, size: 16, color: _fgMuted),
            SizedBox(width: 8),
            Expanded(
              child: Text('Your circle gets a gentle reminder on your day.',
                  style: TextStyle(color: _fgMuted, fontSize: 12)),
            ),
          ],
        ),
        const SizedBox(height: 18),
        const _FieldLabel('Password'),
        _DarkInput(
          controller: _password,
          hint: 'At least 6 characters',
          obscure: true,
          onChanged: (_) => setState(() {}),
        ),
        if (_error != null) _errorRow(_error!),
      ],
    );
  }

  // ---- Step: host invite ----

  Widget _inviteStep() {
    final done = _invited != null;
    return _StepScaffold(
      footer: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _PrimaryButton(
            label: done ? 'Continue' : 'Pick from contacts',
            enabled: !_busy,
            busy: _busy,
            onTap: done ? () => setState(() => _step = _Step.done) : _pickInvitees,
          ),
          if (!done) ...[
            const SizedBox(height: 12),
            GestureDetector(
              onTap: () => setState(() => _step = _Step.done),
              behavior: HitTestBehavior.opaque,
              child: const Text('Skip for now',
                  style: TextStyle(color: _fgMuted, fontWeight: FontWeight.w600, fontSize: 13)),
            ),
          ],
        ],
      ),
      children: [
        const SizedBox(height: 8),
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(color: _accentLight, borderRadius: BorderRadius.circular(16)),
          child: const Icon(Icons.group_add, size: 28, color: _accent),
        ),
        const SizedBox(height: 20),
        const Text('Invite your circle',
            style: TextStyle(color: _fgPrimary, fontWeight: FontWeight.w700, fontSize: 22)),
        const SizedBox(height: 8),
        const Text(
          'Check-In is invite-only, and you’re the host. Add the people who can join — their '
          'phone number becomes their invite. You can always do this later from the Admin tab.',
          style: TextStyle(color: _fgSecondary, fontSize: 14, height: 1.5),
        ),
        if (done) ...[
          const SizedBox(height: 20),
          Row(
            children: [
              const Icon(Icons.check_circle, size: 18, color: _online),
              const SizedBox(width: 7),
              Text(
                _invited == 0
                    ? 'Those numbers were already on the list.'
                    : '$_invited ${_invited == 1 ? 'person' : 'people'} invited.',
                style: const TextStyle(color: _online, fontWeight: FontWeight.w500, fontSize: 13),
              ),
            ],
          ),
        ],
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
