import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/accent.dart';
import '../theme/tokens.dart';

/// A muted label shown above an input.
class FieldLabel extends StatelessWidget {
  const FieldLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text,
            style: const TextStyle(color: kFgMuted, fontWeight: FontWeight.w600, fontSize: 12)),
      );
}

/// The app's standard dark text field.
class AppTextField extends StatelessWidget {
  const AppTextField({
    super.key,
    required this.controller,
    required this.hint,
    this.keyboardType,
    this.obscure = false,
    this.onChanged,
    this.minLines,
    this.maxLines = 1,
    this.errorText,
    this.inputFormatters,
  });

  final TextEditingController controller;
  final String hint;
  final TextInputType? keyboardType;
  final bool obscure;
  final ValueChanged<String>? onChanged;
  final int? minLines;
  final int maxLines;

  /// When set, the field shows a red border and this message beneath it.
  final String? errorText;

  final List<TextInputFormatter>? inputFormatters;

  @override
  Widget build(BuildContext context) {
    final hasError = errorText != null;
    final field = TextField(
      controller: controller,
      keyboardType: keyboardType,
      obscureText: obscure,
      inputFormatters: inputFormatters,
      onChanged: onChanged,
      minLines: obscure ? 1 : minLines,
      maxLines: obscure ? 1 : maxLines,
      style: const TextStyle(color: kFgPrimary, fontSize: 15),
      cursorColor: context.accent,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: kFgMuted),
        filled: true,
        fillColor: kBgSurface,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: hasError ? kLike : kBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: hasError ? kLike : context.accent),
        ),
      ),
    );
    // Keep the bare field when there's no error so existing layouts are unchanged.
    if (!hasError) return field;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        field,
        Padding(
          padding: const EdgeInsets.only(top: 6, left: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.error_outline, size: 14, color: kLike),
              const SizedBox(width: 5),
              Expanded(
                child: Text(errorText!,
                    style: const TextStyle(color: kLike, fontSize: 12, height: 1.3)),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The app's full-width primary (filled, accent) button with a busy state.
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
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
          backgroundColor: context.accent,
          disabledBackgroundColor: kBgSurfaceHover,
          foregroundColor: context.onAccent,
          disabledForegroundColor: kFgMuted,
          padding: const EdgeInsets.symmetric(vertical: 15),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        child: busy
            ? SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: context.onAccent))
            : Text(label, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
      ),
    );
  }
}
