import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../api/api_client.dart';
import '../../main.dart' show kLastCrashKey;
import '../../state/app_state.dart';

/// ConnectScreen is the first thing a new user sees: they enter the server address the
/// admin gave them. We verify it responds before saving.
class ConnectScreen extends ConsumerStatefulWidget {
  const ConnectScreen({super.key});

  @override
  ConsumerState<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends ConsumerState<ConnectScreen> {
  final _controller = TextEditingController(text: 'https://');
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
        title: const Text('Last Crash Log'),
        content: SingleChildScrollView(
          child: SelectableText(
            _lastCrash ?? '',
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
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
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.favorite, size: 64, color: Color(0xFF4C6EF5)),
                const SizedBox(height: 16),
                Text('Check-In',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 8),
                Text('Enter the server address your admin shared with you.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium),
                const SizedBox(height: 24),
                TextField(
                  controller: _controller,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'Server address',
                    hintText: 'https://check-in.example.com',
                    border: OutlineInputBorder(),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: const TextStyle(color: Colors.red)),
                ],
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _busy ? null : _connect,
                  child: _busy
                      ? const SizedBox(
                          height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Connect'),
                ),
                if (_lastCrash != null) ...[
                  const SizedBox(height: 24),
                  OutlinedButton.icon(
                    onPressed: _showCrashDialog,
                    icon: const Icon(Icons.bug_report, color: Colors.orange),
                    label: const Text('View last crash log',
                        style: TextStyle(color: Colors.orange)),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.orange),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
