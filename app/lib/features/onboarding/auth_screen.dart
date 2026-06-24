import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../../state/app_state.dart';

/// AuthScreen handles both logging in and signing up against the connected server.
class AuthScreen extends ConsumerWidget {
  const AuthScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Welcome'),
          bottom: const TabBar(tabs: [Tab(text: 'Log in'), Tab(text: 'Sign up')]),
          actions: [
            IconButton(
              tooltip: 'Change server',
              icon: const Icon(Icons.dns_outlined),
              onPressed: () => ref.read(sessionProvider.notifier).setServer(''),
            ),
          ],
        ),
        body: const TabBarView(children: [_LoginForm(), _SignupForm()]),
      ),
    );
  }
}

class _LoginForm extends ConsumerStatefulWidget {
  const _LoginForm();
  @override
  ConsumerState<_LoginForm> createState() => _LoginFormState();
}

class _LoginFormState extends ConsumerState<_LoginForm> {
  final _phone = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final api = ref.read(apiProvider);
      final res = await api.login(phone: _phone.text.trim(), password: _password.text);
      await ref.read(sessionProvider.notifier).signIn(res.token, res.user);
    } on DioException catch (e) {
      setState(() => _error = _msg(e, 'Login failed'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        TextField(
          controller: _phone,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(labelText: 'Phone number', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _password,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'Password', border: OutlineInputBorder()),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: const TextStyle(color: Colors.red)),
        ],
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy ? const _Spinner() : const Text('Log in'),
        ),
      ],
    );
  }
}

class _SignupForm extends ConsumerStatefulWidget {
  const _SignupForm();
  @override
  ConsumerState<_SignupForm> createState() => _SignupFormState();
}

class _SignupFormState extends ConsumerState<_SignupForm> {
  final _phone = TextEditingController();
  final _name = TextEditingController();
  final _password = TextEditingController();
  DateTime? _birthday;
  XFile? _photo;
  bool _checked = false;
  bool _isFirstAdmin = false;
  bool _busy = false;
  String? _error;

  Future<void> _checkPhone() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await ref.read(apiProvider).checkPhone(_phone.text.trim());
      if (!res.allowed) {
        setState(() => _error =
            'That number isn\'t on the invite list, or it\'s already registered. Try logging in.');
        return;
      }
      setState(() {
        _checked = true;
        _isFirstAdmin = res.isFirstAdmin;
      });
    } on DioException catch (e) {
      setState(() => _error = _msg(e, 'Could not check that number'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit() async {
    if (_birthday == null) {
      setState(() => _error = 'Please pick your birthday');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final api = ref.read(apiProvider);
      int? mediaId;
      if (_photo != null) {
        mediaId = await api.uploadImage(_photo!.path);
      }
      final res = await api.signup(
        phone: _phone.text.trim(),
        name: _name.text.trim(),
        birthday: DateFormat('yyyy-MM-dd').format(_birthday!),
        password: _password.text,
        mediaId: mediaId,
      );
      await ref.read(sessionProvider.notifier).signIn(res.token, res.user);
    } on DioException catch (e) {
      setState(() => _error = _msg(e, 'Sign up failed'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        TextField(
          controller: _phone,
          enabled: !_checked,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(labelText: 'Phone number', border: OutlineInputBorder()),
        ),
        if (!_checked) ...[
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _checkPhone,
            child: _busy ? const _Spinner() : const Text('Continue'),
          ),
        ],
        if (_checked) ...[
          if (_isFirstAdmin) ...[
            const SizedBox(height: 16),
            const Card(
              color: Color(0xFFE7F5FF),
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  "You're the first user, so you'll be the admin. After signing up you'll be "
                  'asked to share your contacts to set who else can join.',
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Name', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            icon: const Icon(Icons.cake_outlined),
            label: Text(_birthday == null
                ? 'Pick your birthday'
                : DateFormat.yMMMMd().format(_birthday!)),
            onPressed: () async {
              final now = DateTime.now();
              final picked = await showDatePicker(
                context: context,
                initialDate: DateTime(now.year - 25),
                firstDate: DateTime(1900),
                lastDate: now,
              );
              if (picked != null) setState(() => _birthday = picked);
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            obscureText: true,
            decoration: const InputDecoration(
                labelText: 'Password (6+ characters)', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            icon: const Icon(Icons.photo_camera_outlined),
            label: Text(_photo == null ? 'Add profile picture (optional)' : 'Photo selected'),
            onPressed: () async {
              final x = await ImagePicker().pickImage(source: ImageSource.gallery);
              if (x != null) setState(() => _photo = x);
            },
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: _busy ? const _Spinner() : const Text('Create account'),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: const TextStyle(color: Colors.red)),
        ],
      ],
    );
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner();
  @override
  Widget build(BuildContext context) =>
      const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2));
}

/// _msg extracts the server's error message from a Dio error when available.
String _msg(DioException e, String fallback) {
  final data = e.response?.data;
  if (data is Map && data['error'] is String) return data['error'] as String;
  return fallback;
}
