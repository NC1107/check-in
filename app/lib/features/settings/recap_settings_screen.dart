import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart';
import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../theme/accent.dart';
import '../../theme/tokens.dart';
import '../../widgets/date_range_sheet.dart';

const _weekdayNames = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday'
];

/// Host-only recap settings, reached from a group's editor (edit_group_screen.dart) once
/// the group's server has advertised [ServerInfo.recapCapable] - a server that predates the
/// feature has nowhere to send these fields, so the entry point itself is gated on it, not
/// just this screen's contents.
class RecapSettingsScreen extends ConsumerStatefulWidget {
  const RecapSettingsScreen({super.key, required this.groupId});

  final String groupId;

  @override
  ConsumerState<RecapSettingsScreen> createState() => _RecapSettingsScreenState();
}

class _RecapSettingsScreenState extends ConsumerState<RecapSettingsScreen> {
  late String _cadence;
  late int _weekday;
  late int _hour;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final account = ref.read(contentAccountProvider(widget.groupId));
    // The account's last-known settings (refreshed on every hydrate) prefill the screen
    // instantly; there's no separate GET, so this is as fresh as the last launch/refresh.
    _cadence = 'weekly';
    _weekday = 1;
    _hour = 19;
    _loadCurrent(account);
  }

  Future<void> _loadCurrent(ServerAccount? account) async {
    if (account == null) return;
    try {
      final info = await ref.read(apiForGroupProvider(account.id)).serverInfo();
      if (!mounted) return;
      setState(() {
        _cadence = info.recapCadence;
        _weekday = info.recapWeekday;
        _hour = info.recapHour;
      });
    } catch (_) {
      // Keep the defaults; the toggles below still work and will save whatever is chosen.
    }
  }

  Future<void> _save({String? cadence, int? weekday, int? hour}) async {
    final prev = (cadence: _cadence, weekday: _weekday, hour: _hour);
    setState(() {
      _cadence = cadence ?? _cadence;
      _weekday = weekday ?? _weekday;
      _hour = hour ?? _hour;
      _saving = true;
    });
    try {
      await ref.read(apiForGroupProvider(widget.groupId)).setRecapSettings(
            cadence: _cadence,
            weekday: _weekday,
            hour: _hour,
            offset: DateTime.now().timeZoneOffset.inMinutes,
          );
      if (mounted) setState(() => _saving = false);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _cadence = prev.cadence;
        _weekday = prev.weekday;
        _hour = prev.hour;
        _saving = false;
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text("Couldn't update - check your connection.")));
    }
  }

  Future<void> _editHour() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: _hour, minute: 0),
      helpText: 'Recap arrives at',
      builder: (context, child) => Theme(
        data: Theme.of(context)
            .copyWith(colorScheme: Theme.of(context).colorScheme.copyWith(primary: context.accent)),
        child: child!,
      ),
    );
    if (picked == null || !mounted) return;
    await _save(hour: picked.hour);
  }

  Future<void> _editWeekday() async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: kBgSurface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            for (var i = 0; i < _weekdayNames.length; i++)
              ListTile(
                title: Text(_weekdayNames[i], style: const TextStyle(color: kFgPrimary)),
                trailing: _weekday == i + 1 ? Icon(Icons.check, color: context.accent) : null,
                onTap: () => Navigator.pop(context, i + 1),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    await _save(weekday: picked);
  }

  Future<void> _generateNow() async {
    final result = await showModalBottomSheet<_GenerateChoice>(
      context: context,
      backgroundColor: kBgSurface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (_) => const _GenerateRecapSheet(),
    );
    if (result == null || !mounted) return;
    await _submitGenerate(result, replace: false);
  }

  Future<void> _submitGenerate(_GenerateChoice choice, {required bool replace}) async {
    final api = ref.read(apiForGroupProvider(widget.groupId));
    try {
      await api.generateRecap(
        periodStart: choice.start,
        periodEnd: choice.end,
        panels: choice.panels,
        replace: replace,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Recap posted.')));
    } on RecapAlreadyExists catch (_) {
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: kBgSurface,
          title: const Text('Replace the existing recap?',
              style: TextStyle(color: kFgPrimary, fontWeight: FontWeight.w700)),
          content: const Text(
            'You already made a recap for this period with these panels. Replacing it removes '
            'the old one and posts a fresh one in its place.',
            style: TextStyle(color: kFgSecondary, fontSize: 14, height: 1.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel', style: TextStyle(color: kFgSecondary)),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Replace'),
            ),
          ],
        ),
      );
      if (confirmed == true) await _submitGenerate(choice, replace: true);
    } on RecapEmptyPeriod catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Not enough activity in that period yet.")),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Could not generate the recap. Try again.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBgMain,
      appBar: AppBar(
        backgroundColor: kBgMain,
        elevation: 0,
        title: const Text('Recaps',
            style: TextStyle(color: kFgPrimary, fontWeight: FontWeight.w700, fontSize: 18)),
      ),
      body: ListView(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 12, 20, 12),
            child: Text(
              'A recap post rounds up the group\'s check-ins into a swipeable deck: '
              'the best-received photos, and a set of awards for the period.',
              style: TextStyle(color: kFgMuted, fontSize: 12.5, height: 1.4),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'off', label: Text('Off')),
                ButtonSegment(value: 'weekly', label: Text('Weekly')),
                ButtonSegment(value: 'monthly', label: Text('Monthly')),
              ],
              selected: {_cadence},
              onSelectionChanged: _saving ? null : (s) => _save(cadence: s.first),
              style: SegmentedButton.styleFrom(
                selectedBackgroundColor: context.accent,
                selectedForegroundColor: context.onAccent,
              ),
            ),
          ),
          if (_cadence != 'off') ...[
            const SizedBox(height: 8),
            if (_cadence == 'weekly')
              ListTile(
                title: const Text('Day',
                    style: TextStyle(color: kFgPrimary, fontWeight: FontWeight.w600, fontSize: 15)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_weekdayNames[_weekday - 1],
                        style: TextStyle(color: context.accent, fontWeight: FontWeight.w600)),
                    const SizedBox(width: 4),
                    const Icon(Icons.chevron_right, color: kFgMuted, size: 20),
                  ],
                ),
                onTap: _saving ? null : _editWeekday,
              ),
            ListTile(
              title: const Text('Time',
                  style: TextStyle(color: kFgPrimary, fontWeight: FontWeight.w600, fontSize: 15)),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(TimeOfDay(hour: _hour, minute: 0).format(context),
                      style: TextStyle(color: context.accent, fontWeight: FontWeight.w600)),
                  const SizedBox(width: 4),
                  const Icon(Icons.chevron_right, color: kFgMuted, size: 20),
                ],
              ),
              onTap: _saving ? null : _editHour,
            ),
          ],
          const Divider(color: kBorder, height: 32, indent: 16, endIndent: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: FilledButton.icon(
              onPressed: _generateNow,
              style: FilledButton.styleFrom(backgroundColor: context.accent),
              icon: const Icon(Icons.auto_awesome_outlined),
              label: const Text('Generate a recap now'),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 10, 20, 20),
            child: Text(
              'Makes a recap for a period you pick, in addition to the standing schedule '
              'above.',
              style: TextStyle(color: kFgMuted, fontSize: 12.5, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

/// What [_GenerateRecapSheet] hands back: the chosen period and which panels to include.
class _GenerateChoice {
  const _GenerateChoice({required this.start, required this.end, required this.panels});

  final DateTime start;
  final DateTime end;
  final List<String> panels;
}

/// The on-demand generate sheet: a period preset (this week / this month / a custom
/// range) and which panels to include.
class _GenerateRecapSheet extends StatefulWidget {
  const _GenerateRecapSheet();

  @override
  State<_GenerateRecapSheet> createState() => _GenerateRecapSheetState();
}

class _GenerateRecapSheetState extends State<_GenerateRecapSheet> {
  String _preset = 'week';
  DateTimeRange? _custom;
  bool _wall = true;
  bool _awards = true;

  DateTimeRange get _range {
    final now = DateTime.now();
    return switch (_preset) {
      'month' => DateTimeRange(start: DateTime(now.year, now.month, 1), end: now),
      'custom' => _custom ?? DateTimeRange(start: now.subtract(const Duration(days: 7)), end: now),
      _ => DateTimeRange(start: now.subtract(const Duration(days: 7)), end: now),
    };
  }

  Future<void> _pickCustom() async {
    final now = DateTime.now();
    final choice = await showDateRangeSheet(
      context,
      firstDate: now.subtract(const Duration(days: 365)),
      lastDate: now,
      initial: _custom,
    );
    if (choice is PickRange && mounted) {
      setState(() {
        _custom = choice.range;
        _preset = 'custom';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final panels = [if (_wall) 'collage', if (_awards) 'awards'];
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 10),
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 14),
              alignment: Alignment.center,
              decoration: BoxDecoration(color: kBorder, borderRadius: BorderRadius.circular(2)),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: Text('Generate a recap',
                  style: TextStyle(color: kFgPrimary, fontWeight: FontWeight.w700, fontSize: 17)),
            ),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Wrap(
                spacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('This week'),
                    selected: _preset == 'week',
                    onSelected: (_) => setState(() => _preset = 'week'),
                  ),
                  ChoiceChip(
                    label: const Text('This month'),
                    selected: _preset == 'month',
                    onSelected: (_) => setState(() => _preset = 'month'),
                  ),
                  ChoiceChip(
                    label: const Text('Custom range'),
                    selected: _preset == 'custom',
                    onSelected: (_) => _pickCustom(),
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 18, 20, 4),
              child: Text('PANELS',
                  style: TextStyle(
                      color: kFgMuted,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6)),
            ),
            CheckboxListTile(
              value: _wall,
              onChanged: (v) => setState(() => _wall = v ?? true),
              activeColor: context.accent,
              title: const Text('The Wall', style: TextStyle(color: kFgPrimary)),
              subtitle:
                  const Text('The ranked collage', style: TextStyle(color: kFgMuted, fontSize: 12)),
            ),
            CheckboxListTile(
              value: _awards,
              onChanged: (v) => setState(() => _awards = v ?? true),
              activeColor: context.accent,
              title: const Text('Awards Night', style: TextStyle(color: kFgPrimary)),
              subtitle: const Text('This period\'s superlatives',
                  style: TextStyle(color: kFgMuted, fontSize: 12)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: panels.isEmpty
                      ? null
                      : () => Navigator.pop(
                            context,
                            _GenerateChoice(start: _range.start, end: _range.end, panels: panels),
                          ),
                  style: FilledButton.styleFrom(backgroundColor: context.accent),
                  child: const Text('Generate'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
