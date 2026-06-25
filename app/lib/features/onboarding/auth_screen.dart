import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../../api/api_client.dart';
import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_widgets.dart';
import '../admin/contacts_picker_screen.dart';

// Theme tokens (centralized in theme/tokens.dart).
const _bgMain = kBgMain;
const _bgSurface = kBgSurface;
const _border = kBorder;
const _fgPrimary = kFgPrimary;
const _fgSecondary = kFgSecondary;
const _fgMuted = kFgMuted;
const _accent = kAccent;
const _accentLight = kAccentLight;
const _online = kSuccess;
const _danger = kLike;

enum _Step { entry, profile, invite, done }

/// AuthScreen is the single entry point once the app launches (until logged in). The
/// first step takes the server address *and* phone number together, then branches to
/// login (returning members) or signup (new invitees / the first host).
class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key});

  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  _Step _step = _Step.entry;
  bool _loginMode = false; // entered when the number already has an account

  final _server = TextEditingController();
  final _phone = TextEditingController();
  final _firstName = TextEditingController();
  final _lastName = TextEditingController();
  final _displayName = TextEditingController();
  final _password = TextEditingController();
  DateTime? _birthday;
  XFile? _photo;

  bool _busy = false;
  String? _error; // general / login error, shown at the bottom
  String? _serverError; // shown inline under the server-address field
  String? _phoneError; // shown inline under the phone field (bad number / not invited)
  bool _isFirstAdmin = false;
  AuthResult? _pendingAuth; // captured from signup, applied on "Enter Check-In"
  int? _invited; // number of invitees added on the host invite step (null = not done)
  // The server URL we've successfully reached and bound the session to. Null until the
  // first successful probe; used to avoid re-probing an unchanged address.
  String? _connectedUrl;

  @override
  void initState() {
    super.initState();
    // Pre-fill the last server we used so logging back in doesn't mean retyping it.
    final saved = ref.read(sessionProvider).baseUrl;
    if (saved != null && saved.isNotEmpty) _server.text = saved;
  }

  @override
  void dispose() {
    _server.dispose();
    _phone.dispose();
    _firstName.dispose();
    _lastName.dispose();
    _displayName.dispose();
    _password.dispose();
    super.dispose();
  }

  // --- actions ---

  /// Normalizes a typed server address into a base URL (https:// by default, no trailing
  /// slash). Returns null when blank.
  String? _normalizeServer(String raw) {
    var url = raw.trim();
    if (url.isEmpty) return null;
    if (url.endsWith('/')) url = url.substring(0, url.length - 1);
    if (!url.startsWith('http')) url = 'https://$url';
    return url;
  }

  /// Probes the server address and binds the session to it. Returns true on success;
  /// sets [_error] and returns false if blank or unreachable. No-ops if the address is
  /// unchanged since the last successful probe.
  Future<bool> _ensureServer() async {
    final url = _normalizeServer(_server.text);
    if (url == null) {
      setState(() => _serverError = 'Enter your server address.');
      return false;
    }
    if (url == _connectedUrl) return true;
    try {
      final info = await ApiClient(baseUrl: url).serverInfo();
      await ref.read(sessionProvider.notifier).setServer(url, serverInitialized: info.initialized);
      _connectedUrl = url;
      return true;
    } on DioException catch (_) {
      setState(() =>
          _serverError = "Couldn't reach that server. Check the address and your connection.");
      return false;
    }
  }

  /// Single entry action: connect to the server, then check the number and branch to
  /// login (existing account), profile setup (invited / first host), or rejection.
  Future<void> _continue() async {
    setState(() {
      _busy = true;
      _error = null;
      _serverError = null;
      _phoneError = null;
    });
    try {
      if (!await _ensureServer()) return;
      final res = await ref.read(apiProvider).checkPhone(_phone.text.trim());
      if (res.registered) {
        setState(() => _loginMode = true); // existing account → reveal the password field
      } else if (res.allowed) {
        setState(() {
          _isFirstAdmin = res.isFirstAdmin;
          _step = _Step.profile;
        });
      } else {
        setState(() => _phoneError =
            "This number isn't on the invite list. Ask the host to add it, then try again.");
      }
    } on DioException catch (e) {
      setState(() => _phoneError = _msg(e, "Couldn't check that number. Try again."));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _login() async {
    setState(() {
      _busy = true;
      _error = null;
      _serverError = null;
      _phoneError = null;
    });
    try {
      if (!await _ensureServer()) return;
      final res =
          await ref.read(apiProvider).login(phone: _phone.text.trim(), password: _password.text);
      await ref.read(sessionProvider.notifier).signIn(res.token, res.user);
    } on DioException catch (e) {
      setState(() => _error = _msg(e, 'Incorrect phone or password.'));
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
      setState(
          () => _error = "Couldn't add those right now — you can invite from the Admin tab later.");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _back() {
    setState(() {
      _error = null;
      _phoneError = null;
      if (_step == _Step.profile) {
        _step = _Step.entry;
      } else if (_loginMode) {
        // From login, step back to the neutral state so the number/server can be fixed.
        _loginMode = false;
      }
    });
  }

  Future<void> _pickPhoto() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (x != null && mounted) setState(() => _photo = x);
  }

  Future<void> _pickBirthday() async {
    final now = DateTime.now();
    var temp = _birthday ?? DateTime(now.year - 25, 1, 1);
    final picked = await showModalBottomSheet<DateTime>(
      context: context,
      backgroundColor: _bgSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel', style: TextStyle(color: _fgSecondary)),
                ),
                const Text('Birthday',
                    style: TextStyle(color: _fgPrimary, fontWeight: FontWeight.w700, fontSize: 16)),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, temp),
                  child: const Text('Done',
                      style: TextStyle(color: _accent, fontWeight: FontWeight.w700)),
                ),
              ],
            ),
            SizedBox(
              height: 216,
              child: CupertinoTheme(
                data: const CupertinoThemeData(brightness: Brightness.dark),
                child: CupertinoDatePicker(
                  mode: CupertinoDatePickerMode.date,
                  initialDateTime: temp,
                  minimumYear: 1900,
                  maximumDate: now,
                  onDateTimeChanged: (d) => temp = d,
                ),
              ),
            ),
          ],
        ),
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
            if (_step == _Step.entry || _step == _Step.profile) _header(),
            Expanded(
              child: switch (_step) {
                _Step.entry => _entryStep(),
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
    // The back arrow only appears where there's somewhere to go back to: the profile
    // step (→ entry) or the login sub-state (→ neutral entry).
    final canGoBack = _step == _Step.profile || (_step == _Step.entry && _loginMode);
    final pIndex = _step == _Step.profile ? 2 : 1;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 20, 4),
      child: Row(
        children: [
          if (canGoBack) ...[
            GestureDetector(
              onTap: _back,
              behavior: HitTestBehavior.opaque,
              child: const Icon(Icons.arrow_back, size: 24, color: _fgSecondary),
            ),
            const SizedBox(width: 12),
          ],
          _ProgressDot(active: pIndex >= 1),
          const SizedBox(width: 7),
          _ProgressDot(active: pIndex >= 2),
        ],
      ),
    );
  }

  // ---- Step: entry (server + phone → login / signup) ----

  Widget _entryStep() {
    final digits = _phone.text.replaceAll(RegExp(r'\D'), '');
    final hasServer = _server.text.trim().isNotEmpty;
    final canSubmit = _loginMode
        ? (hasServer && digits.length >= 7 && _password.text.isNotEmpty)
        : (hasServer && digits.length >= 7);

    return _StepScaffold(
      footer: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          PrimaryButton(
            label: _loginMode ? 'Log in' : 'Continue',
            enabled: canSubmit && !_busy,
            busy: _busy,
            onTap: _loginMode ? _login : _continue,
          ),
          const SizedBox(height: 14),
          // Explicit path between login and join so returning members aren't stuck.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() {
              _loginMode = !_loginMode;
              _error = null;
              _phoneError = null;
            }),
            child: Text.rich(
              TextSpan(
                style: const TextStyle(color: _fgMuted, fontSize: 13),
                children: [
                  TextSpan(text: _loginMode ? 'New here?  ' : 'Already have an account?  '),
                  TextSpan(
                    text: _loginMode ? 'Join' : 'Log in',
                    style: const TextStyle(color: _accent, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      children: [
        Image.asset('assets/logo/echo-rings.png', width: 52, height: 52),
        const SizedBox(height: 20),
        Text(
          _loginMode ? 'Welcome back' : 'Connect to Check-In',
          style: const TextStyle(color: _fgPrimary, fontWeight: FontWeight.w700, fontSize: 22),
        ),
        const SizedBox(height: 8),
        Text(
          _loginMode
              ? 'Enter your server, number, and password to sign back in.'
              : 'Enter your server address and phone number to log in or join.',
          style: const TextStyle(color: _fgSecondary, fontSize: 14, height: 1.5),
        ),
        const SizedBox(height: 22),
        const FieldLabel('Server address'),
        AppTextField(
          controller: _server,
          hint: 'checkin.myhome.net',
          keyboardType: TextInputType.url,
          errorText: _serverError,
          onChanged: (_) => setState(() {
            // A changed address invalidates any prior probe.
            _connectedUrl = null;
            _serverError = null;
          }),
        ),
        const SizedBox(height: 16),
        const FieldLabel('Phone number'),
        AppTextField(
          controller: _phone,
          hint: '(415) 555-0148',
          keyboardType: TextInputType.phone,
          inputFormatters: [_PhoneFormatter()],
          errorText: _phoneError,
          onChanged: (_) => setState(() => _phoneError = null),
        ),
        if (_loginMode) ...[
          const SizedBox(height: 16),
          const FieldLabel('Password'),
          AppTextField(
            controller: _password,
            hint: 'Your password',
            obscure: true,
            onChanged: (_) => setState(() {}),
          ),
        ],
        if (!_loginMode && _phoneError == null) ...[
          const SizedBox(height: 16),
          const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline, size: 17, color: _fgMuted),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  "New invitees set up a profile; returning members tap “Log in”. Not on the "
                  "list? Ask whoever set up the server to add your number.",
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

  // ---- Step: profile ----

  Widget _profileStep() {
    final canFinish = _firstName.text.trim().isNotEmpty &&
        _lastName.text.trim().isNotEmpty &&
        _birthday != null &&
        _password.text.length >= 8 &&
        !_busy;
    return _StepScaffold(
      footer: PrimaryButton(
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
                        border:
                            Border.all(color: const Color(0xFF3A3A3F), style: BorderStyle.solid),
                      ),
                      child: const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.add_a_photo, size: 26, color: _fgMuted),
                          SizedBox(height: 5),
                          Text('Add photo',
                              style: TextStyle(
                                  color: _fgMuted, fontSize: 11, fontWeight: FontWeight.w500)),
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
                      child: const Icon(Icons.photo_camera, size: 16, color: kOnAccent),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 24),
        const FieldLabel('Full name'),
        Row(
          children: [
            Expanded(
              child: AppTextField(
                controller: _firstName,
                hint: 'First',
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: AppTextField(
                controller: _lastName,
                hint: 'Last',
                onChanged: (_) => setState(() {}),
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        const FieldLabel('Display name'),
        AppTextField(
          controller: _displayName,
          hint: 'Optional — defaults to your full name',
        ),
        const SizedBox(height: 6),
        const Text("This is what your circle sees. Leave blank to use your full name.",
            style: TextStyle(color: _fgMuted, fontSize: 12, height: 1.4)),
        const SizedBox(height: 18),
        const FieldLabel('Birthday'),
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
        const FieldLabel('Password'),
        AppTextField(
          controller: _password,
          hint: 'At least 8 characters',
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
          PrimaryButton(
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
            child: const Icon(Icons.check, size: 44, color: kOnAccent),
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
          PrimaryButton(label: 'Enter Check-In', enabled: !_busy, busy: _busy, onTap: _enterApp),
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

/// _msg extracts the server's error message from a Dio error when available.
String _msg(DioException e, String fallback) {
  final data = e.response?.data;
  if (data is Map && data['error'] is String) return data['error'] as String;
  return fallback;
}

/// Formats a US-style number as "(123) 456-7890" while typing. Numbers longer than 10
/// digits (i.e. an explicit country code) are shown as "+digits" so international users
/// aren't blocked. The server strips formatting on its end.
class _PhoneFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final digits = newValue.text.replaceAll(RegExp(r'\D'), '');
    String text;
    if (digits.length <= 10) {
      final b = StringBuffer();
      for (var i = 0; i < digits.length; i++) {
        if (i == 0) b.write('(');
        if (i == 3) b.write(') ');
        if (i == 6) b.write('-');
        b.write(digits[i]);
      }
      text = b.toString();
    } else {
      text = '+$digits';
    }
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}
