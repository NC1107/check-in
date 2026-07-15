import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../theme/accent.dart';
import '../theme/tokens.dart';

/// Result of [showDateRangeSheet]: either a chosen span or an explicit clear. A null
/// return from the sheet means dismissed with no change.
sealed class DateRangeChoice {
  const DateRangeChoice();
}

class PickRange extends DateRangeChoice {
  const PickRange(this.range);
  final DateTimeRange range;
}

class ClearRange extends DateRangeChoice {
  const ClearRange();
}

/// A dark, in-theme replacement for Material's [showDateRangePicker]: a bottom sheet with
/// a scrollable column of months. Tap a start day, then an end day; tap again to start
/// over. [firstDate]/[lastDate] bound the selectable span (days outside are dimmed and
/// inert). [initial] preselects a range and scrolls to it.
Future<DateRangeChoice?> showDateRangeSheet(
  BuildContext context, {
  required DateTime firstDate,
  required DateTime lastDate,
  DateTimeRange? initial,
}) {
  return showModalBottomSheet<DateRangeChoice>(
    context: context,
    backgroundColor: kBgSurface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (_) => _DateRangeSheet(firstDate: firstDate, lastDate: lastDate, initial: initial),
  );
}

class _DateRangeSheet extends StatefulWidget {
  const _DateRangeSheet({required this.firstDate, required this.lastDate, this.initial});

  final DateTime firstDate;
  final DateTime lastDate;
  final DateTimeRange? initial;

  @override
  State<_DateRangeSheet> createState() => _DateRangeSheetState();
}

class _DateRangeSheetState extends State<_DateRangeSheet> {
  // Every month renders a fixed six-week grid so all rows share one height; that makes the
  // lazy list's extent exact, so it can scroll straight to the current (or selected) month.
  static const double _monthExtent = 316;

  final _scroll = ScrollController();
  late final DateTime _firstMonth = DateTime(widget.firstDate.year, widget.firstDate.month);
  late final int _monthCount =
      (widget.lastDate.year - _firstMonth.year) * 12 + (widget.lastDate.month - _firstMonth.month) + 1;

  DateTime? _start;
  DateTime? _end;

  @override
  void initState() {
    super.initState();
    if (widget.initial != null) {
      _start = _dayOnly(widget.initial!.start);
      _end = _dayOnly(widget.initial!.end);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToInitial());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToInitial() {
    if (!_scroll.hasClients) return;
    final target = _start ?? widget.lastDate;
    final index = (target.year - _firstMonth.year) * 12 + (target.month - _firstMonth.month);
    final offset = (index * _monthExtent).clamp(0.0, _scroll.position.maxScrollExtent);
    _scroll.jumpTo(offset);
  }

  static DateTime _dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);
  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  void _tapDay(DateTime day) {
    HapticFeedback.selectionClick();
    setState(() {
      // No range yet, or completing a fresh one after a full range was already chosen.
      if (_start == null || _end != null) {
        _start = day;
        _end = null;
      } else if (day.isBefore(_start!)) {
        // Second tap before the start reanchors rather than making an empty range.
        _start = day;
      } else {
        _end = day;
      }
    });
  }

  bool _selectable(DateTime day) => !day.isBefore(_dayOnly(widget.firstDate)) && !day.isAfter(widget.lastDate);

  String get _summary {
    final f = DateFormat.MMMd();
    if (_start == null) return 'Select a start date';
    if (_end == null) return '${f.format(_start!)}  -  end date';
    if (_sameDay(_start!, _end!)) return f.format(_start!);
    return '${f.format(_start!)}  -  ${f.format(_end!)}';
  }

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.of(context).size.height * 0.82;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _grabber(),
            _header(context),
            _weekdayLabels(),
            const Divider(height: 1, color: kBorder),
            Flexible(
              child: ListView.builder(
                controller: _scroll,
                itemExtent: _monthExtent,
                itemCount: _monthCount,
                padding: EdgeInsets.zero,
                itemBuilder: (_, i) => _month(DateTime(_firstMonth.year, _firstMonth.month + i)),
              ),
            ),
            _footer(context),
          ],
        ),
      ),
    );
  }

  Widget _grabber() => Container(
        width: 38,
        height: 4,
        margin: const EdgeInsets.only(top: 10, bottom: 8),
        decoration: BoxDecoration(color: kBorder, borderRadius: BorderRadius.circular(9999)),
      );

  Widget _header(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
        child: Row(
          children: [
            const Text('Select dates',
                style: TextStyle(color: kFgPrimary, fontWeight: FontWeight.w700, fontSize: 17)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(_summary,
                  textAlign: TextAlign.right,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: _start == null ? kFgMuted : context.accent,
                      fontWeight: FontWeight.w600,
                      fontSize: 13.5)),
            ),
          ],
        ),
      );

  Widget _weekdayLabels() => Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        child: Row(
          children: [
            for (final d in const ['S', 'M', 'T', 'W', 'T', 'F', 'S'])
              Expanded(
                child: Center(
                  child: Text(d,
                      style: const TextStyle(
                          color: kFgMuted, fontSize: 12, fontWeight: FontWeight.w600)),
                ),
              ),
          ],
        ),
      );

  Widget _month(DateTime month) {
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    // Sunday-indexed offset for the 1st (DateTime.weekday has Sun=7).
    final lead = DateTime(month.year, month.month, 1).weekday % 7;
    final cells = <DateTime?>[
      ...List.filled(lead, null),
      for (var d = 1; d <= daysInMonth; d++) DateTime(month.year, month.month, d),
    ];
    while (cells.length < 42) {
      cells.add(null); // pad to six weeks so every month is the same height
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(DateFormat.yMMMM().format(month),
                style: const TextStyle(
                    color: kFgPrimary, fontWeight: FontWeight.w600, fontSize: 14.5)),
          ),
        ),
        for (var w = 0; w < 6; w++)
          Row(children: [for (var d = 0; d < 7; d++) _dayCell(cells[w * 7 + d])]),
      ],
    );
  }

  Widget _dayCell(DateTime? day) {
    if (day == null) return const Expanded(child: SizedBox(height: 40));
    final selectable = _selectable(day);
    final isStart = _start != null && _sameDay(day, _start!);
    final isEnd = _end != null && _sameDay(day, _end!);
    final endpoint = isStart || isEnd;
    final single = _start != null && _end != null && _sameDay(_start!, _end!);
    final inRange = _start != null &&
        _end != null &&
        !day.isBefore(_start!) &&
        !day.isAfter(_end!);

    BorderRadius? bandRadius;
    if (inRange) {
      final leftEnd = isStart || single;
      final rightEnd = isEnd || single;
      bandRadius = BorderRadius.horizontal(
        left: Radius.circular(leftEnd ? 999 : 0),
        right: Radius.circular(rightEnd ? 999 : 0),
      );
    }

    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: selectable ? () => _tapDay(day) : null,
        child: SizedBox(
          height: 40,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (inRange && !single)
                Positioned.fill(
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    decoration: BoxDecoration(color: context.accentLight, borderRadius: bandRadius),
                  ),
                ),
              if (endpoint)
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(color: context.accent, shape: BoxShape.circle),
                ),
              Text(
                '${day.day}',
                style: TextStyle(
                  color: endpoint
                      ? context.onAccent
                      : selectable
                          ? kFgPrimary
                          : kFgMuted.withValues(alpha: 0.4),
                  fontSize: 14,
                  fontWeight: endpoint ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _footer(BuildContext context) {
    final complete = _start != null && _end != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      child: Row(
        children: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(const ClearRange()),
            style: TextButton.styleFrom(foregroundColor: kFgSecondary),
            child: const Text('Clear'),
          ),
          const Spacer(),
          FilledButton(
            onPressed: complete
                ? () => Navigator.of(context).pop(
                      PickRange(DateTimeRange(start: _start!, end: _end!)),
                    )
                : null,
            style: FilledButton.styleFrom(
              backgroundColor: context.accent,
              foregroundColor: context.onAccent,
              disabledBackgroundColor: kBgSurfaceHover,
              disabledForegroundColor: kFgMuted,
              padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('Apply', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}
