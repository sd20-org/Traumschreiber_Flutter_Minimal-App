// Live EEG of one channel, filtered 0.5–35 Hz with a 50 Hz notch.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../traumschreiber/traumschreiber.dart';
import 'style.dart';

class SignalPage extends StatefulWidget {
  final AppState app;
  const SignalPage({super.key, required this.app});

  @override
  State<SignalPage> createState() => _SignalPageState();
}

class _SignalPageState extends State<SignalPage> {
  int _seconds = 10;
  double _range = 100; // ± µV; 0 = automatic
  bool _filtered = true;

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    if (!app.device.isActive) return NotConnected(onConnect: app.connect);
    final buffer = (_filtered ? app.filtered : app.raw)[app.channel];
    var y = buffer.last(_seconds * kSampleRateHz);
    if (!_filtered && y.isNotEmpty) {
      // Raw values carry the electrode's DC offset; centre them.
      final mean = y.reduce((a, b) => a + b) / y.length;
      y = Float64List.fromList([for (final v in y) v - mean]);
    }
    final range = _range > 0
        ? _range
        : math.max(10.0, y.fold(0.0, (m, v) => math.max(m, v.abs())) * 1.1);

    return ListView(padding: const EdgeInsets.all(16), children: [
      ChannelPicker(value: app.channel, onChanged: app.setChannel),
      const SizedBox(height: 12),
      Card(
        child: SizedBox(
          height: 320,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 16, 16, 8),
            child: CustomPaint(
              painter: TracePainter(y, range: range, seconds: _seconds),
              size: Size.infinite,
            ),
          ),
        ),
      ),
      const SizedBox(height: 12),
      Section(
        title: 'Display',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SegmentedButton<int>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 5, label: Text('5 s')),
              ButtonSegment(value: 10, label: Text('10 s')),
              ButtonSegment(value: 30, label: Text('30 s')),
            ],
            selected: {_seconds},
            onSelectionChanged: (s) => setState(() => _seconds = s.first),
          ),
          const SizedBox(height: 10),
          SegmentedButton<double>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 50, label: Text('±50')),
              ButtonSegment(value: 100, label: Text('±100')),
              ButtonSegment(value: 500, label: Text('±500')),
              ButtonSegment(value: 0, label: Text('auto')),
            ],
            selected: {_range},
            onSelectionChanged: (s) => setState(() => _range = s.first),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Filter 0.5–35 Hz, 50 Hz notch'),
            subtitle: const Text('Only for the display. Recordings stay raw.'),
            value: _filtered,
            onChanged: (v) => setState(() => _filtered = v),
          ),
        ]),
      ),
    ]);
  }
}

/// Draws a time series with a light grid. y in µV, newest value on the right.
class TracePainter extends CustomPainter {
  final List<double> y;
  final double range;
  final int seconds;
  TracePainter(this.y, {required this.range, required this.seconds});

  @override
  void paint(Canvas canvas, Size size) {
    const left = 44.0;
    final w = size.width - left, h = size.height - 18;
    final grid = Paint()..color = Colors.white10;
    final label = TextStyle(color: Colors.white38, fontSize: 10);
    for (final f in [-1.0, -0.5, 0.0, 0.5, 1.0]) {
      final py = h / 2 - f * h / 2;
      canvas.drawLine(Offset(left, py), Offset(size.width, py), grid);
      _text(canvas, '${(f * range).round()}', Offset(0, py - 6), label);
    }
    for (var s = 0; s <= seconds; s += seconds <= 10 ? 1 : 5) {
      final px = left + w * s / seconds;
      canvas.drawLine(Offset(px, 0), Offset(px, h), grid);
      _text(canvas, '-${seconds - s}s', Offset(px - 10, h + 4), label);
    }
    if (y.length < 2) return;
    final n = seconds * kSampleRateHz;
    final start = n - y.length; // fill from the right while the buffer grows
    final path = Path();
    for (var i = 0; i < y.length; i++) {
      final px = left + w * (start + i) / (n - 1);
      final py = (h / 2 - y[i] / range * h / 2).clamp(0.0, h);
      i == 0 ? path.moveTo(px, py) : path.lineTo(px, py);
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = kSignal
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.3);
  }

  void _text(Canvas c, String s, Offset at, TextStyle style) {
    final tp = TextPainter(text: TextSpan(text: s, style: style), textDirection: TextDirection.ltr)
      ..layout();
    tp.paint(c, at);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
