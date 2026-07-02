import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_state.dart';
import '../../theme/accent.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_widgets.dart';

/// Shown once before the auth screen. The user must accept the terms before they
/// can sign up or log in (Apple Guideline 1.2 — EULA required for UGC apps).
class TermsScreen extends ConsumerWidget {
  const TermsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: kBgMain,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 40, 24, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Before you continue',
                style: TextStyle(
                  color: kFgPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 26,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'check-in is a private, invite-only network. '
                'By continuing you agree to use it responsibly.',
                style: TextStyle(color: kFgSecondary, fontSize: 15, height: 1.5),
              ),
              const SizedBox(height: 32),
              const _Section(
                icon: Icons.block_outlined,
                title: 'No objectionable content',
                body: 'Do not post content that is abusive, harassing, hateful, '
                    'sexually explicit, or otherwise harmful. '
                    'Violations result in immediate removal from the network.',
              ),
              const SizedBox(height: 20),
              const _Section(
                icon: Icons.flag_outlined,
                title: 'Report what should not be here',
                body: 'Use the report button on any post to flag content that '
                    'violates these rules. The server admin reviews all reports '
                    'and acts within 24 hours.',
              ),
              const SizedBox(height: 20),
              const _Section(
                icon: Icons.person_off_outlined,
                title: 'Block abusive members',
                body: 'You can block any member from their profile. '
                    'Blocked members’ posts stop appearing in your feed. '
                    'The server admin is notified and will review the situation.',
              ),
              const SizedBox(height: 20),
              const _Section(
                icon: Icons.admin_panel_settings_outlined,
                title: 'Zero tolerance',
                body: 'This network has zero tolerance for abuse. '
                    'The server admin can remove any post or member at any time. '
                    'Anyone found to have posted objectionable content will be removed.',
              ),
              const Spacer(),
              PrimaryButton(
                label: 'I agree - continue',
                enabled: true,
                onTap: () => ref.read(termsProvider.notifier).accept(),
              ),
              const SizedBox(height: 12),
              const Center(
                child: Text(
                  'By continuing you accept these community rules.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: kFgMuted, fontSize: 12, height: 1.4),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: kBgSurface,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Icon(icon, size: 20, color: context.accent),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(
                      color: kFgPrimary, fontWeight: FontWeight.w600, fontSize: 14)),
              const SizedBox(height: 3),
              Text(body, style: const TextStyle(color: kFgSecondary, fontSize: 13, height: 1.45)),
            ],
          ),
        ),
      ],
    );
  }
}
