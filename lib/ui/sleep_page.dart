// Current sleep stage, stage probabilities and the hypnogram of this session.
import 'package:flutter/material.dart';

import '../analysis/sleep_staging.dart';
import '../app_state.dart';
import 'sleep_plots.dart';
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
        title: 'Probabilities',
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            height: 160,
            child: CustomPaint(painter: ProbabilityPainter(st.hypnogram), size: Size.infinite),
          ),
        ),
      ),
      const SizedBox(height: 12),
      Section(
        title: 'Hypnogram',
        trailing: const StageLegend(),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            height: 110,
            child: CustomPaint(painter: HypnogramPainter(st.hypnogram), size: Size.infinite),
          ),
        ),
      ),
      const SizedBox(height: 12),
      Section(
        title: 'Scored channel',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ChannelPicker(value: app.sleepChannel, onChanged: app.setSleepChannel,
          available: app.device.status.channels),
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
