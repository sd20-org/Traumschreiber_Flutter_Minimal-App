// Current sleep stage and the hypnogram of this session.
import 'package:flutter/material.dart';

import '../analysis/sleep_staging.dart';
import '../app_state.dart';
import 'style.dart';

class SleepPage extends StatelessWidget {
  final AppState app;
  const SleepPage({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    if (!app.device.isActive) return NotConnected(onConnect: app.connect);
    final st = app.stager;
    final text = Theme.of(context).textTheme;
    final current = st.hypnogram.isEmpty ? null : st.hypnogram.last;

    return ListView(padding: const EdgeInsets.all(16), children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(children: [
            Text('Current stage', style: text.labelLarge?.copyWith(color: Colors.white54)),
            const SizedBox(height: 8),
            Text(current == null ? '–' : stageLabel(current.stage),
                style: text.displayMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: current == null ? Colors.white24 : stageColor(current.stage))),
            const SizedBox(height: 8),
            Text(_statusLine(st), textAlign: TextAlign.center,
                style: text.bodyMedium?.copyWith(color: Colors.white60)),
            if (st.modelState == ModelState.loading) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
            ],
            if (st.modelState == ModelState.failed)
              TextButton(onPressed: st.loadModel, child: const Text('Try again')),
            if (current == null && st.modelState == ModelState.ready) ...[
              const SizedBox(height: 14),
              LinearProgressIndicator(
                value: (st.hypnogram.isEmpty ? 0 : 1) + st.secondsIntoEpoch / 30 / 2,
                borderRadius: BorderRadius.circular(4),
              ),
            ],
          ]),
        ),
      ),
      const SizedBox(height: 12),
      Section(
        title: 'Hypnogram',
        child: SizedBox(
          height: 170,
          child: CustomPaint(painter: HypnogramPainter(st.hypnogram), size: Size.infinite),
        ),
      ),
      const SizedBox(height: 12),
      Section(
        title: 'Hypnodensity',
        child: SizedBox(
          height: 150,
          child: CustomPaint(painter: HypnodensityPainter(st.hypnogram), size: Size.infinite),
        ),
      ),
      const SizedBox(height: 12),
      Section(
        title: 'Scored channel',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ChannelPicker(value: app.sleepChannel, onChanged: app.setSleepChannel),
          const SizedBox(height: 8),
          const Text(
            'Use a forehead channel against the mastoid if you have one. '
            'Changing the channel starts the hypnogram over.',
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ]),
      ),
      const SizedBox(height: 12),
      const Text(
        'AnySleep (github.com/dslaborg/AnySleep) was trained on clinical sleep '
        'recordings. This is not a medical device and not a diagnosis.',
        style: TextStyle(color: Colors.white38, fontSize: 11),
      ),
    ]);
  }

  String _statusLine(SleepStager st) => switch (st.modelState) {
        ModelState.notLoaded || ModelState.loading => 'Loading the AnySleep model…',
        ModelState.failed => st.error ?? 'Model not available',
        ModelState.ready => st.error ??
            (st.hypnogram.isEmpty
                ? 'First result after one minute (two 30-second epochs).'
                : '${(st.hypnogram.last.confidence * 100).round()} % confidence · '
                    '${st.hypnogram.length} epoch${st.hypnogram.length == 1 ? '' : 's'} scored'),
      };
}

/// Classic step plot: Wake on top, then REM, N1, N2, N3.
class HypnogramPainter extends CustomPainter {
  final List<Epoch> epochs;
  HypnogramPainter(this.epochs);

  static const _order = [SleepStage.wake, SleepStage.rem, SleepStage.n1, SleepStage.n2, SleepStage.n3];

  @override
  void paint(Canvas canvas, Size size) {
    const left = 44.0;
    final w = size.width - left, rowH = size.height / _order.length;
    for (var r = 0; r < _order.length; r++) {
      final y = rowH * (r + 0.5);
      canvas.drawLine(Offset(left, y), Offset(size.width, y), Paint()..color = Colors.white10);
      (TextPainter(
              text: TextSpan(
                  text: stageLabel(_order[r]),
                  style: TextStyle(color: stageColor(_order[r]), fontSize: 11)),
              textDirection: TextDirection.ltr)
            ..layout())
          .paint(canvas, Offset(0, y - 7));
    }
    if (epochs.isEmpty) return;
    final n = epochs.length < 20 ? 20 : epochs.length; // fill from the left
    final bw = w / n;
    for (var i = 0; i < epochs.length; i++) {
      final r = _order.indexOf(epochs[i].stage);
      canvas.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromLTWH(left + i * bw, rowH * r + rowH * 0.2, bw + 0.5, rowH * 0.6),
              const Radius.circular(3)),
          Paint()..color = stageColor(epochs[i].stage));
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

/// For every epoch, how likely the model finds each stage: a stacked bar,
/// Wake on top and N3 at the bottom. Mixed colours mean the model is unsure.
class HypnodensityPainter extends CustomPainter {
  final List<Epoch> epochs;
  HypnodensityPainter(this.epochs);

  @override
  void paint(Canvas canvas, Size size) {
    const left = 44.0;
    final w = size.width - left, h = size.height;
    for (final f in [0.0, 0.5, 1.0]) {
      final y = h * f;
      canvas.drawLine(Offset(left, y), Offset(size.width, y), Paint()..color = Colors.white10);
      (TextPainter(
              text: TextSpan(
                  text: '${(100 * (1 - f)).round()} %',
                  style: const TextStyle(color: Colors.white38, fontSize: 10)),
              textDirection: TextDirection.ltr)
            ..layout())
          .paint(canvas, Offset(0, (y - 6).clamp(0, h - 12)));
    }
    if (epochs.isEmpty) return;
    final n = epochs.length < 20 ? 20 : epochs.length;
    final bw = w / n;
    for (var i = 0; i < epochs.length; i++) {
      var y = 0.0;
      for (final s in HypnogramPainter._order) {
        final hh = epochs[i].probabilities[s.index] * h;
        canvas.drawRect(Rect.fromLTWH(left + i * bw, y, bw + 0.5, hh),
            Paint()..color = stageColor(s));
        y += hh;
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
