// Connect / disconnect, device details, link quality.
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../traumschreiber/traumschreiber.dart';
import 'style.dart';

class DevicePage extends StatelessWidget {
  final AppState app;
  const DevicePage({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    final d = app.device;
    final busy = d.phase == ConnectionPhase.scanning || d.phase == ConnectionPhase.connecting;
    final text = Theme.of(context).textTheme;
    final (label, color) = switch (d.phase) {
      ConnectionPhase.disconnected => ('Not connected', Colors.white38),
      ConnectionPhase.scanning => ('Searching…', kAccent),
      ConnectionPhase.connecting => ('Connecting…', kAccent),
      ConnectionPhase.connected => ('Streaming', kSignal),
    };
    final lostPct = app.samplesReceived == 0
        ? 0.0
        : 100 * app.samplesLost / (app.samplesReceived + app.samplesLost);

    return ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 96), children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color.withValues(alpha: 0.12),
                border: Border.all(color: color, width: 2),
              ),
              child: busy
                  ? Padding(
                      padding: const EdgeInsets.all(28),
                      child: CircularProgressIndicator(strokeWidth: 3, color: color))
                  : Icon(d.isConnected ? Icons.sensors_rounded : Icons.bluetooth_rounded,
                      size: 44, color: color),
            ),
            const SizedBox(height: 16),
            Text(d.isConnected ? (d.deviceName ?? 'Traumschreiber') : 'Traumschreiber',
                style: text.headlineSmall),
            const SizedBox(height: 4),
            Text(label, style: text.bodyMedium?.copyWith(color: color)),
            if (d.error != null) ...[
              const SizedBox(height: 12),
              Text(d.error!,
                  textAlign: TextAlign.center,
                  style: text.bodySmall?.copyWith(color: kRecord)),
            ],
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: d.isConnected
                  ? OutlinedButton.icon(
                      onPressed: app.disconnect,
                      icon: const Icon(Icons.link_off_rounded),
                      label: const Text('Disconnect'))
                  : FilledButton.icon(
                      onPressed: busy ? null : app.connect,
                      icon: const Icon(Icons.bluetooth_searching_rounded),
                      label: const Text('Connect')),
            ),
          ]),
        ),
      ),
      const SizedBox(height: 12),
      if (d.isConnected)
        Section(
          title: 'Device',
          child: Column(children: [
            _row('Battery', d.batteryPercent == null ? '–' : '${d.batteryPercent} %'),
            _row('Channels streamed', d.status.channels.join(', ')),
            _row('Amplifier gain', '×${d.status.gains.toSet().join(' / ×')}'),
            _row('Samples received', '${app.samplesReceived}'),
            _row('Samples lost', '${app.samplesLost} (${lostPct.toStringAsFixed(2)} %)'),
          ]),
        ),
      if (d.isConnected) ...[
        const SizedBox(height: 12),
        _LedAndSound(device: d),
        const SizedBox(height: 12),
        _ButtonPresses(presses: d.buttonPresses),
      ] else
        const Section(
          title: 'How to start',
          child: Text(
            '1. Switch the Traumschreiber on.\n'
            '2. Tap Connect. The EEG stream starts right away.\n'
            '3. Watch the signal, spectrum and sleep stages.\n'
            '4. Tap Record to save the data as CSV.',
            style: TextStyle(height: 1.6, color: Colors.white70),
          ),
        ),
    ]);
  }

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          Text(k, style: const TextStyle(color: Colors.white60)),
          const Spacer(),
          Text(v, style: const TextStyle(fontWeight: FontWeight.w600)),
        ]),
      );
}

/// RGB LED colour with brightness, and the start sound.
class _LedAndSound extends StatefulWidget {
  final Traumschreiber device;
  const _LedAndSound({required this.device});

  @override
  State<_LedAndSound> createState() => _LedAndSoundState();
}

class _LedAndSoundState extends State<_LedAndSound> {
  static const _colors = [
    Color(0xFFFF0000), Color(0xFF00FF00), Color(0xFF0000FF),
    Color(0xFFFFFFFF), Color(0xFFFF00FF), Color(0xFFFFA000),
  ];
  Color? _color; // null = off
  double _brightness = 0.3;

  void _apply() {
    final c = _color;
    int v(double x) => (x * 255 * _brightness).round();
    if (c == null) {
      widget.device.setLed(0, 0, 0);
    } else {
      widget.device.setLed(v(c.r), v(c.g), v(c.b));
    }
  }

  @override
  Widget build(BuildContext context) => Section(
        title: 'LED and sound',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(spacing: 10, runSpacing: 10, children: [
            _dot(null),
            for (final c in _colors) _dot(c),
          ]),
          Row(children: [
            const Icon(Icons.brightness_low_rounded, size: 18, color: Colors.white54),
            Expanded(
              child: Slider(
                value: _brightness,
                onChanged: _color == null ? null : (v) => setState(() => _brightness = v),
                onChangeEnd: (_) => _apply(),
              ),
            ),
            const Icon(Icons.brightness_high_rounded, size: 18, color: Colors.white54),
          ]),
          const SizedBox(height: 4),
          Row(children: [
            OutlinedButton.icon(
              onPressed: () => widget.device.playSound(),
              icon: const Icon(Icons.music_note_rounded),
              label: const Text('Play start sound'),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                switch (widget.device.playbackState) {
                  1 => 'Playing…',
                  0 => 'Done',
                  3 => 'The device could not play the start sound. Is SOUNDS/TSBOOT.WAV on the SD card?',
                  _ => '',
                },
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ),
          ]),
        ]),
      );

  Widget _dot(Color? c) {
    final selected = _color == c;
    return GestureDetector(
      onTap: () {
        setState(() => _color = c);
        _apply();
      },
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: c ?? kSurface,
          border: Border.all(color: selected ? Colors.white : Colors.white24, width: selected ? 3 : 1),
        ),
        child: c == null ? const Icon(Icons.power_settings_new_rounded, size: 18, color: Colors.white54) : null,
      ),
    );
  }
}

/// Every press of the device's button with date and time (phone clock).
class _ButtonPresses extends StatelessWidget {
  final List<DateTime> presses;
  const _ButtonPresses({required this.presses});

  static String _two(int v) => v.toString().padLeft(2, '0');
  static String format(DateTime t) => '${_two(t.day)}.${_two(t.month)}.${t.year}  '
      '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';

  @override
  Widget build(BuildContext context) => Section(
        title: 'Button presses',
        trailing: Text('${presses.length}', style: const TextStyle(color: Colors.white54)),
        child: presses.isEmpty
            ? const Text('Press the button on the Traumschreiber; each press is listed here.',
                style: TextStyle(color: Colors.white54))
            : Column(children: [
                for (final t in presses.reversed.take(50))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(children: [
                      const Icon(Icons.radio_button_checked_rounded, size: 16, color: kAccent),
                      const SizedBox(width: 10),
                      Text(format(t), style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
                    ]),
                  ),
                if (presses.length > 50)
                  Text('… and ${presses.length - 50} earlier', style: const TextStyle(color: Colors.white38)),
              ]),
      );
}
