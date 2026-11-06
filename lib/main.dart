// Traumschreiber Minimal: a small Flutter example that connects to the
// Traumschreiber EEG headband, shows the signal live, computes a spectrum,
// scores sleep stages with AnySleep, and records to CSV.
//
//   lib/traumschreiber/   Bluetooth: connect, stream, decode   (start here)
//   lib/app_state.dart    distributes the samples to everything else
//   lib/analysis/         spectrum and sleep staging
//   lib/recording/        CSV files: write, list, share
//   lib/ui/               one file per page
import 'package:flutter/material.dart';

import 'app_state.dart';
import 'traumschreiber/traumschreiber.dart';
import 'ui/device_page.dart';
import 'ui/recordings_page.dart';
import 'ui/signal_page.dart';
import 'ui/sleep_page.dart';
import 'ui/spectrum_page.dart';
import 'ui/style.dart';

void main() => runApp(const TraumschreiberApp());

class TraumschreiberApp extends StatelessWidget {
  const TraumschreiberApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Traumschreiber Minimal',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        home: const HomeScreen(),
      );
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final app = AppState();
  int _page = 0;

  static const _pages = [
    (Icons.bluetooth_rounded, 'Device'),
    (Icons.show_chart_rounded, 'Signal'),
    (Icons.equalizer_rounded, 'Spectrum'),
    (Icons.bedtime_rounded, 'Sleep'),
    (Icons.folder_rounded, 'Recordings'),
  ];

  @override
  void dispose() {
    app.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: app,
        builder: (context, _) => Scaffold(
          appBar: AppBar(
            backgroundColor: kBackground,
            title: Text(_pages[_page].$2, style: const TextStyle(fontWeight: FontWeight.w600)),
            actions: [_StatusPill(app: app), const SizedBox(width: 12)],
          ),
          body: SafeArea(
            child: switch (_page) {
              0 => DevicePage(app: app),
              1 => SignalPage(app: app),
              2 => SpectrumPage(app: app),
              3 => SleepPage(app: app),
              _ => RecordingsPage(app: app),
            },
          ),
          floatingActionButton: _page == 0 && (app.device.isActive || app.recorder.isRecording)
              ? _RecordButton(app: app)
              : null,
          bottomNavigationBar: NavigationBar(
            selectedIndex: _page,
            onDestinationSelected: (i) => setState(() => _page = i),
            destinations: [
              for (final p in _pages) NavigationDestination(icon: Icon(p.$1), label: p.$2),
            ],
          ),
        ),
      );
}

/// Starts and stops saving to CSV. Recording is separate from connecting:
/// the stream runs as soon as the device is connected. After Stop, gaps may
/// still be fetched from the SD card; tapping again saves without them.
class _RecordButton extends StatelessWidget {
  final AppState app;
  const _RecordButton({required this.app});

  @override
  Widget build(BuildContext context) {
    final r = app.recorder;
    if (app.saving) {
      return const FloatingActionButton.extended(
        onPressed: null,
        backgroundColor: kSurface,
        icon: SizedBox.square(
            dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
        label: Text('Saving…'),
      );
    }
    if (app.finishing) {
      final s = app.backfill.pending ~/ kSampleRateHz;
      return FloatingActionButton.extended(
        onPressed: app.saveNow,
        backgroundColor: kSurface,
        foregroundColor: kAccent,
        icon: const Icon(Icons.downloading_rounded),
        label: Text('Fetching ${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')} · save now'),
      );
    }
    if (!r.isRecording) {
      return FloatingActionButton.extended(
        onPressed: app.startRecording,
        backgroundColor: kRecord,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.fiber_manual_record_rounded),
        label: const Text('Record'),
      );
    }
    final e = r.elapsed;
    String two(int v) => v.toString().padLeft(2, '0');
    return FloatingActionButton.extended(
      onPressed: app.stopRecording,
      backgroundColor: kSurface,
      foregroundColor: kRecord,
      icon: const Icon(Icons.stop_rounded),
      label: Text('${two(e.inHours)}:${two(e.inMinutes % 60)}:${two(e.inSeconds % 60)}'),
    );
  }
}

/// Connection state and battery in the app bar.
class _StatusPill extends StatelessWidget {
  final AppState app;
  const _StatusPill({required this.app});

  @override
  Widget build(BuildContext context) {
    final d = app.device;
    final on = d.isConnected;
    if (d.phase == ConnectionPhase.reconnecting) {
      return const Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.sync_rounded, size: 14, color: kAccent),
        SizedBox(width: 4),
        Text('reconnecting', style: TextStyle(fontSize: 12, color: kAccent)),
      ]);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: (on ? kSignal : Colors.white24).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.circle, size: 8, color: on ? kSignal : Colors.white38),
        const SizedBox(width: 6),
        Text(on ? (d.batteryPercent != null ? '${d.batteryPercent} %' : 'on') : 'off',
            style: TextStyle(fontSize: 12, color: on ? kSignal : Colors.white54)),
        if (on) ...[
          const SizedBox(width: 2),
          Icon(Icons.battery_std_rounded, size: 14, color: kSignal),
        ],
      ]),
    );
  }
}
