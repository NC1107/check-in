import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_state.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_widgets.dart';

/// Redeem a host-issued recovery code to set a new password. On success pops with the
/// AuthResult so the caller can sign in. Assumes the server is already connected.
class ResetPasswordScreen extends ConsumerStatefulWidget {
  const ResetPasswordScreen({super.key, this.initialPhone = ''});

  final String initialPhone;

  @override
  ConsumerState<ResetPasswordScreen> createState() => _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends ConsumerState<ResetPasswordScreen> {
  late final _phone = TextEditingController(text: widget.initialPhone);
  final _code = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _phone.dispose();
    _code.dispose();
    _password.dispose();
    super.dispose();
  }

  bool get _canSubmit =>
      _phone.text.trim().length >= 7 && _code.text.trim().isNotEmpty && _password.text.length >= 8;

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await ref.read(apiProvider).resetPassword(
            phone: _phone.text.trim(),
            code: _code.text.trim(),
            newPassword: _password.text,
          );
      if (mounted) Navigator.of(context).pop(res);
    } on DioException catch (e) {
      final data = e.response?.data;
      final msg = (data is Map && data['error'] is String)
          ? data['error'] as String
          : 'Could not reset. Check the code and try again.';
      if (mounted) setState(() => _error = msg);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not reset. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBgMain,
      appBar: AppBar(
        backgroundColor: kBgMain,
        elevation: 0,
        title: const Text('Reset password',
            style: TextStyle(color: kFgPrimary, fontWeight: FontWeight.w700, fontSize: 18)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        children: [
          const Text(
            'Ask the host for a reset code, then set a new password here.',
            style: TextStyle(color: kFgSecondary, fontSize: 14, height: 1.4),
          ),
          const SizedBox(height: 22),
          const FieldLabel('Phone number'),
          AppTextField(
            controller: _phone,
            hint: 'Your number',
            keyboardType: TextInputType.phone,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          const FieldLabel('Reset code'),
          AppTextField(
            controller: _code,
            hint: 'Code from the host',
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          const FieldLabel('New password'),
          AppTextField(
            controller: _password,
            hint: 'At least 8 characters',
            obscure: true,
            onChanged: (_) => setState(() {}),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: kLike, fontSize: 13)),
          ],
          const SizedBox(height: 24),
          PrimaryButton(
            label: 'Set new password',
            enabled: _canSubmit && !_busy,
            busy: _busy,
            onTap: _submit,
          ),
        ],
      ),
    );
  }
}
