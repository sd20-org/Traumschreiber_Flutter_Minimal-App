// Probability stack and hypnogram, drawn the same way as in the sd20 app:
// same stage colours, Wake at the top and N3 at the bottom, a dark plot
// background and an hh:mm time axis along the bottom edge.
//
// Epochs are placed by their wall-clock start, so a gap in the recording stays
// visible as empty background instead of being squeezed out.
import 'package:flutter/material.dart';

import '../analysis/sleep_staging.dart';
import 'style.dart';

const kPlotBackground = Color(0xFF0D1C2B);
const kPlotAxis = Color(0xFFAABBCC);
const _bottomReserve = 16.0; // room for the time labels
const _epoch = Duration(seconds: 30);

/// Row of each stage in the hypnogram, counted from the bottom.
int _hypnoRow(SleepStage s) => switch (s) {
      SleepStage.n3 => 0,
      SleepStage.n2 => 1,
      SleepStage.n1 => 2,
      SleepStage.rem => 3,
      SleepStage.wake => 4,
    };

/// Time range shared by both plots, so they line up pixel for pixel.
({DateTime start, DateTime end})? plotRange(List<Epoch> epochs) {
  if (epochs.isEmpty) return null;
  final start = epochs.first.start;
  var end = epochs.last.start.add(_epoch);
  // A short session still gets at least ten minutes of width.
  final min = start.add(const Duration(minutes: 10));
  if (end.isBefore(min)) end = min;
  return (start: start, end: end);
}

/// x position of [t] inside [range] on a canvas of width [w].
double _x(DateTime t, ({DateTime start, DateTime end}) range, double w) {
  final total = range.end.difference(range.start).inMilliseconds;
  final d = t.difference(range.start).inMilliseconds;
  return (d / total).clamp(0.0, 1.0) * w;
}

/// Right edge of epoch [i]: up to the next epoch if it follows within 30 s
/// (no hairline slits), otherwise the nominal 30 s (a real gap stays empty).
double _xRight(List<Epoch> e, int i, ({DateTime start, DateTime end}) range, double w) {
  final nominal = e[i].start.add(_epoch);
  var end = nominal;
  if (i + 1 < e.length) {
    final next = e[i + 1].start;
    if (next.isBefore(nominal) || next.difference(nominal) < _epoch) end = next;
  }
  return _x(end, range, w);
}

/// Stacked probabilities per epoch (Wake, N1, N2, N3, REM from the bottom).
/// Mixed colours mean the model is unsure.
class ProbabilityPainter extends CustomPainter {
  final List<Epoch> epochs;
  ProbabilityPainter(this.epochs);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = kPlotBackground);
    final range = plotRange(epochs);
    if (range == null) return;
    final w = size.width, h = size.height - _bottomReserve;
    final paints = [
      for (final s in SleepStage.values) Paint()..color = stageColor(s).withValues(alpha: 0.88)
    ];

    // Several epochs can share one pixel column on a long night: average them
    // and draw one column, which keeps the number of rectangles small.
    int? px;
    double xl = 0, xr = 0;
    var count = 0;
    final sum = List<double>.filled(5, 0);
    void flush() {
      if (px == null || count == 0) return;
      var bottom = 0.0;
      for (var s = 0; s < 5; s++) {
        final top = bottom + sum[s] / count;
        if (top > bottom) {
          canvas.drawRect(Rect.fromLTRB(xl, h - top * h, xr + 0.5, h - bottom * h), paints[s]);
        }
        bottom = top;
      }
      px = null;
      count = 0;
      sum.fillRange(0, 5, 0);
    }

    for (var i = 0; i < epochs.length; i++) {
      final l = _x(epochs[i].start, range, w), r = _xRight(epochs, i, range, w);
      if (px != null && l.floor() != px) flush();
      if (px == null) {
        px = l.floor();
        xl = l;
        xr = r;
      } else if (r > xr) {
        xr = r;
      }
      for (var s = 0; s < 5; s++) {
        sum[s] += epochs[i].probabilities[s];
      }
      count++;
    }
    flush();
    drawTimeAxis(canvas, size, range);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

/// One coloured bar per epoch in the row of its stage: Wake on top, then REM,
/// N1, N2 and N3 at the bottom.
class HypnogramPainter extends CustomPainter {
  final List<Epoch> epochs;
  HypnogramPainter(this.epochs);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = kPlotBackground);
    final range = plotRange(epochs);
    if (range == null) return;
    final w = size.width, h = size.height - _bottomReserve;

    void bar(SleepStage s, double l, double r) {
      final mid = h - (_hypnoRow(s) + 0.5) / 5 * h;
      final half = h * 0.45 / 5;
      canvas.drawRect(Rect.fromLTRB(l, mid - half, r + 0.5, mid + half),
          Paint()..color = stageColor(s).withValues(alpha: 0.65));
    }

    // Per pixel column, draw the stage that occurs most often in it.
    int? px;
    double xl = 0, xr = 0;
    final count = List<int>.filled(5, 0);
    void flush() {
      if (px == null) return;
      var best = 0;
      for (var s = 1; s < 5; s++) {
        if (count[s] > count[best]) best = s;
      }
      if (count[best] > 0) bar(SleepStage.values[best], xl, xr);
      px = null;
      count.fillRange(0, 5, 0);
    }

    for (var i = 0; i < epochs.length; i++) {
      final l = _x(epochs[i].start, range, w), r = _xRight(epochs, i, range, w);
      if (px != null && l.floor() != px) flush();
      if (px == null) {
        px = l.floor();
        xl = l;
        xr = r;
      } else if (r > xr) {
        xr = r;
      }
      count[epochs[i].stage.index]++;
    }
    flush();
    drawTimeAxis(canvas, size, range);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

/// Thin vertical lines and hh:mm labels along the bottom 16 px. The step
/// grows with the length of the session (1 min … 2 h).
void drawTimeAxis(Canvas canvas, Size size, ({DateTime start, DateTime end}) range) {
  final minutes = range.end.difference(range.start).inMinutes;
  final step = minutes < 10
      ? 1
      : minutes < 30
          ? 5
          : minutes < 60
              ? 15
              : minutes < 180
                  ? 30
                  : minutes < 720
                      ? 60
                      : 120;
  final stepMs = step * 60000;
  final startMs = range.start.millisecondsSinceEpoch;
  final endMs = range.end.millisecondsSinceEpoch;
  final line = Paint()
    ..color = kPlotAxis.withValues(alpha: step >= 60 ? 0.7 : 0.3)
    ..strokeWidth = step >= 60 ? 1.4 : 0.8;
  const style = TextStyle(color: kPlotAxis, fontSize: 9, fontWeight: FontWeight.w500);
  // Labels on round local clock times (e.g. 00:00, 01:00).
  final offsetMs = range.start.timeZoneOffset.inMilliseconds;
  var t = ((startMs + offsetMs + stepMs - 1) ~/ stepMs) * stepMs - offsetMs;
  for (; t <= endMs; t += stepMs) {
    final x = (t - startMs) / (endMs - startMs) * size.width;
    canvas.drawLine(Offset(x, 0), Offset(x, size.height - 14), line);
    final dt = DateTime.fromMillisecondsSinceEpoch(t);
    final tp = TextPainter(
        text: TextSpan(
            text: '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}',
            style: style),
        textDirection: TextDirection.ltr)
      ..layout();
    tp.paint(canvas, Offset((x - tp.width / 2).clamp(0.0, size.width - tp.width), size.height - tp.height - 1));
  }
}

/// Colour swatches with stage names, for a panel's title row.
class StageLegend extends StatelessWidget {
  const StageLegend({super.key});

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        for (final s in SleepStage.values) ...[
          Container(width: 10, height: 7, color: stageColor(s)),
          const SizedBox(width: 3),
          Text(stageLabel(s), style: const TextStyle(color: kPlotAxis, fontSize: 10)),
          if (s != SleepStage.values.last) const SizedBox(width: 8),
        ],
      ]);
}
