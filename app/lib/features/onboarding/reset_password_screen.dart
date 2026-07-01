import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_state.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_widgets.dart';
import 'phone_field.dart';

/// Redeem a host-issued recovery code to set a new password. On success pops with the
/// AuthResult so the caller can sign in. Assumes the server is already connected.
class ResetPasswordScreen extends ConsumerStatefulWidget {
  const ResetPasswordScreen({super.key, this.initialPhone = ''});

  final String initialPhone;

  @override
  ConsumerState<ResetPasswordScreen> createState() => _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends ConsumerState<ResetPasswordScreen> {
  late Country _country;
  late final TextEditingController _phone;
  final _code = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // The caller passes a stored "+[cc][national]" number; split it back so the
    // country selector and the national field prefill correctly.
    final parsed = splitE164(widget.initialPhone);
    _country = parsed.country;
    _phone = TextEditingController(text: parsed.national);
  }

  @override
  void dispose() {
    _phone.dispose();
    _code.dispose();
    _password.dispose();
    super.dispose();
  }

  String get _fullPhone => '+${_country.dialCode}${_phone.text.replaceAll(RegExp(r'\D'), '')}';

  bool get _canSubmit {
    final nat = _phone.text.replaceAll(RegExp(r'\D'), '');
    final phoneValid = nat.length >= _country.minLen && nat.length <= _country.maxLen;
    return phoneValid && _code.text.trim().isNotEmpty && _password.text.length >= 8;
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await ref.read(apiProvider).resetPassword(
            phone: _fullPhone,
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
          PhoneField(
            controller: _phone,
            country: _country,
            onCountryChanged: (c) => setState(() {
              _country = c;
              final nat = _phone.text.replaceAll(RegExp(r'\D'), '');
              _phone.text = nat.length > c.maxLen ? nat.substring(0, c.maxLen) : nat;
            }),
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
