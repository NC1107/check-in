import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../api/api_client.dart';
import '../../main.dart' show kLastCrashKey;
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

/// ConnectScreen is the first thing a new user sees: they enter the server address the
/// admin gave them. We verify it responds before saving.
class ConnectScreen extends ConsumerStatefulWidget {
  const ConnectScreen({super.key});

  @override
  ConsumerState<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends ConsumerState<ConnectScreen> {
  final _controller = TextEditingController();
  bool _busy = false;
  String? _error;
  String? _lastCrash;

  @override
  void initState() {
    super.initState();
    _loadCrashLog();
  }

  Future<void> _loadCrashLog() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final crash = prefs.getString(kLastCrashKey);
      if (crash != null && mounted) setState(() => _lastCrash = crash);
    } catch (_) {}
  }

  Future<void> _clearCrashLog() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(kLastCrashKey);
      if (mounted) setState(() => _lastCrash = null);
    } catch (_) {}
  }

  void _showCrashDialog() {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: _bgSurface,
        title: const Text('Last Crash Log', style: TextStyle(color: _fgPrimary)),
        content: SingleChildScrollView(
          child: SelectableText(
            _lastCrash ?? '',
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: _fgSecondary),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _lastCrash ?? ''));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Copied to clipboard')),
              );
            },
            child: const Text('Copy'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _clearCrashLog();
            },
            child: const Text('Clear'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _connect() async {
    var url = _controller.text.trim();
    if (url.endsWith('/')) url = url.substring(0, url.length - 1);
    if (!url.startsWith('http')) url = 'https://$url';

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // Probe the server before committing the URL.
      final info = await ApiClient(baseUrl: url).serverInfo();
      await ref.read(sessionProvider.notifier).setServer(url);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Connected to ${info.name}')));
    } on DioException catch (_) {
      setState(() => _error = 'Could not reach that server. Check the address.');
    } catch (_) {
      setState(() => _error = 'Could not reach that server. Check the address.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canConnect = _controller.text.trim().isNotEmpty && !_busy;
    return Scaffold(
      backgroundColor: _bgMain,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(26, 30, 26, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Logo mark
                    Center(
                      child: Column(
                        children: [
                          Container(
                            width: 46,
                            height: 46,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: _accent, width: 2),
                            ),
                            alignment: Alignment.center,
                            child: Container(
                              width: 18,
                              height: 18,
                              decoration: const BoxDecoration(
                                color: _accent,
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(color: _accentLight, blurRadius: 0, spreadRadius: 4),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 14),
                          const Text('Check-In',
                              style: TextStyle(
                                  color: _fgPrimary,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 20,
                                  letterSpacing: -0.3)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 34),
                    const Text('Connect to your server',
                        style: TextStyle(color: _fgPrimary, fontWeight: FontWeight.w700, fontSize: 22)),
                    const SizedBox(height: 8),
                    const Text('Enter the Check-In server address your admin shared with you.',
                        style: TextStyle(color: _fgSecondary, fontSize: 14, height: 1.5)),
                    const SizedBox(height: 22),
                    const Text('Server address',
                        style: TextStyle(color: _fgMuted, fontWeight: FontWeight.w600, fontSize: 12)),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _controller,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      onChanged: (_) => setState(() {}),
                      style: const TextStyle(color: _fgPrimary, fontSize: 15),
                      cursorColor: _accent,
                      decoration: InputDecoration(
                        hintText: 'checkin.myhome.net',
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
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!, style: const TextStyle(color: Color(0xFFEF4444), fontSize: 13)),
                    ],
                    if (_lastCrash != null) ...[
                      const SizedBox(height: 24),
                      OutlinedButton.icon(
                        onPressed: _showCrashDialog,
                        icon: const Icon(Icons.bug_report, color: Colors.orange, size: 18),
                        label: const Text('View last crash log',
                            style: TextStyle(color: Colors.orange)),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Colors.orange),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: canConnect ? _connect : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: _accent,
                    disabledBackgroundColor: _bgSurfaceHover,
                    foregroundColor: Colors.white,
                    disabledForegroundColor: _fgMuted,
                    padding: const EdgeInsets.symmetric(vertical: 15),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: _busy
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('Connect',
                          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
