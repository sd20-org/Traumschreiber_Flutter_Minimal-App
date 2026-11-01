// Spectrogram of the last 60 seconds of one channel: one column per second,
// power per frequency as colour. Below it the share of the classic EEG
// frequency bands over the last 8 seconds.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../analysis/spectrum.dart';
import '../app_state.dart';
import '../traumschreiber/traumschreiber.dart';
import 'style.dart';

const _bands = [
  ('Delta', 0.5, 4.0, kCiLightBlue),
  ('Theta', 4.0, 8.0, kCiLightPink),
  ('Alpha', 8.0, 12.0, kCiYellow),
  ('Sigma', 12.0, 15.0, kCiPink),
  ('Beta', 15.0, 30.0, kCiOrange),
];
const _seconds = 60;
const _maxHz = 60.0;
const _medianSeconds = 5; // smooths each frequency over time

class SpectrumPage extends StatefulWidget {
  final AppState app;
  const SpectrumPage({super.key, required this.app});

  @override
  State<SpectrumPage> createState() => _SpectrumPageState();
}

class _SpectrumPageState extends State<SpectrumPage> {
  // Recomputed only when a new second of data is complete or the channel
  // changes, not on every packet.
  List<Float64List> _columns = [];
  (int, int)? _computedFor;

  /// One column per second: power spectrum (dB) of the 2 s ending there,
  /// then per frequency the median of the last five seconds, which removes
  /// single-second spikes (movement, blinks) without blurring the picture.
  void _update(AppState app) {
    final key = (app.channel, app.samplesReceived ~/ kSampleRateHz);
    if (key == _computedFor) return;
    _computedFor = key;
    const window = 2 * kSampleRateHz;
    const needed = _seconds + _medianSeconds - 1;
    final x = app.raw[app.channel].last(needed * kSampleRateHz + window);
    final columns = <Float64List>[];
    for (var end = x.length; end >= window && columns.length < needed; end -= kSampleRateHz) {
      final s = welch(x.sublist(end - window, end), kSampleRateHz.toDouble(), segment: 256);
      final rows = (_maxHz / s.binHz).floor();
      columns.add(Float64List.fromList(
          [for (var i = 0; i <= rows; i++) 10 * math.log(s.power[i] + 1e-9) / math.ln10]));
    }
    final raw = columns.reversed.toList(); // oldest first
    _columns = [
      for (var c = 0; c < raw.length; c++)
        Float64List.fromList([
          for (var r = 0; r < raw[c].length; r++)
            _median([for (var k = math.max(0, c - _medianSeconds + 1); k <= c; k++) raw[k][r]])
        ])
    ];
    if (_columns.length > _seconds) _columns = _columns.sublist(_columns.length - _seconds);
  }

  static double _median(List<double> v) {
    v.sort();
    final m = v.length ~/ 2;
    return v.length.isOdd ? v[m] : (v[m - 1] + v[m]) / 2;
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    if (!app.device.isConnected) return NotConnected(onConnect: app.connect);
    _update(app);
    final recent = welch(app.raw[app.channel].last(8 * kSampleRateHz), kSampleRateHz.toDouble());
    final bandPower = [for (final b in _bands) recent.band(b.$2, b.$3) * (b.$3 - b.$2)];
    final total = bandPower.fold(0.0, (a, b) => a + b);

    return ListView(padding: const EdgeInsets.all(16), children: [
      ChannelPicker(value: app.channel, onChanged: app.setChannel),
      const SizedBox(height: 12),
      Card(
        child: SizedBox(
          height: 320,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 16, 16, 8),
            child: _columns.isEmpty
                ? const Center(child: Text('Collecting data…', style: TextStyle(color: Colors.white54)))
                : CustomPaint(painter: SpectrogramPainter(_columns), size: Size.infinite),
          ),
        ),
      ),
      const SizedBox(height: 12),
      Section(
        title: 'Band power, last 8 s',
        child: Column(children: [
          for (var i = 0; i < _bands.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(children: [
                SizedBox(width: 56, child: Text(_bands[i].$1)),
                SizedBox(
                    width: 74,
                    child: Text('${_bands[i].$2.toStringAsFixed(1)}–${_bands[i].$3.round()} Hz',
                        style: const TextStyle(color: Colors.white38, fontSize: 12))),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: total > 0 ? bandPower[i] / total : 0,
                      minHeight: 10,
                      color: _bands[i].$4,
                      backgroundColor: Colors.white10,
                    ),
                  ),
                ),
                SizedBox(
                  width: 48,
                  child: Text(total > 0 ? '${(100 * bandPower[i] / total).round()} %' : '–',
                      textAlign: TextAlign.right),
                ),
              ]),
            ),
        ]),
      ),
    ]);
  }
}

/// Time on x (newest on the right), frequency on y (0 Hz at the bottom),
/// power in dB as viridis colour. The colour range follows the data: the
/// 2nd to 98th percentile of all values shown.
class SpectrogramPainter extends CustomPainter {
  final List<Float64List> columns;
  SpectrogramPainter(this.columns);

  @override
  void paint(Canvas canvas, Size size) {
    const left = 44.0, bottom = 18.0;
    final w = size.width - left, h = size.height - bottom;
    final all = [for (final c in columns) ...c]..sort();
    final lo = all[(all.length * 0.02).floor()], hi = all[(all.length * 0.98).floor()];
    final colW = w / _seconds, rows = columns.first.length, rowH = h / rows;
    final start = _seconds - columns.length; // fill from the right
    final paint = Paint();
    for (var c = 0; c < columns.length; c++) {
      for (var r = 0; r < rows; r++) {
        paint.color = viridis((columns[c][r] - lo) / (hi - lo));
        canvas.drawRect(
            Rect.fromLTWH(left + (start + c) * colW, h - (r + 1) * rowH, colW + 0.5, rowH + 0.5),
            paint);
      }
    }
    const label = TextStyle(color: Colors.white38, fontSize: 10);
    for (var hz = 0; hz <= _maxHz; hz += 20) {
      _text(canvas, '$hz Hz', Offset(0, h - h * hz / _maxHz - 6), label);
    }
    for (var s = 0; s <= _seconds; s += 15) {
      _text(canvas, '-${_seconds - s}s', Offset(left + w * s / _seconds - 10, h + 4), label);
    }
  }

  void _text(Canvas c, String s, Offset at, TextStyle style) {
    (TextPainter(text: TextSpan(text: s, style: style), textDirection: TextDirection.ltr)..layout())
        .paint(c, at);
  }

  @override
  bool shouldRepaint(covariant SpectrogramPainter old) => old.columns != columns;
}

/// The viridis colour map (dark blue → green → yellow), t from 0 to 1.
Color viridis(double t) {
  const stops = [
    Color(0xFF440154), Color(0xFF482878), Color(0xFF3E4A89), Color(0xFF31688E),
    Color(0xFF26828E), Color(0xFF1F9E89), Color(0xFF35B779), Color(0xFF6DCD59),
    Color(0xFFB4DE2C), Color(0xFFFDE725),
  ];
  if (t.isNaN) t = 0;
  final x = t.clamp(0.0, 1.0) * (stops.length - 1);
  final i = x.floor().clamp(0, stops.length - 2);
  return Color.lerp(stops[i], stops[i + 1], x - i)!;
}
