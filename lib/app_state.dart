// The app's single piece of state. It listens to the device and hands every
// block of samples to the four consumers: live plot, spectrum, sleep staging
// and recorder. The pages only read from here and call its methods.
//
// For a whole night it also keeps the recording going when the link drops:
// the device reconnects by itself (traumschreiber.dart), the gaps are
// fetched back from the SD card (backfill.dart), and a foreground service
// keeps the app running with the screen off (background.dart).
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'analysis/sleep_staging.dart';
import 'background.dart';
import 'recording/recorder.dart';
import 'traumschreiber/backfill.dart';
import 'traumschreiber/traumschreiber.dart';

class AppState extends ChangeNotifier {
  static const int bufferSeconds = 60;

  final device = Traumschreiber();
  final recorder = Recorder();
  final stager = SleepStager();
  late final backfill =
      Backfill(request: device.requestBackfill, onRecovered: recorder.writeRecovered);

  /// Last 60 s per channel: raw (for the spectrogram) and filtered
  /// 0.5–35 Hz + 50 Hz notch (for the live plot).
  final raw = List.generate(kChannels, (_) => RingBuffer(bufferSeconds * kSampleRateHz));
  final filtered = List.generate(kChannels, (_) => RingBuffer(bufferSeconds * kSampleRateHz));
  final _filters = List.generate(kChannels, (_) => DisplayFilter());

  int channel = 0; // shown in the live plot and the spectrum
  int sleepChannel = 0; // scored by the sleep model
  int samplesReceived = 0;

  /// Samples that did not arrive over Bluetooth (gaps in the live stream).
  /// While recording, [backfill] fetches them back from the SD card.
  int samplesLost = 0;
  int? _lastSampleNumber;

  /// Stop was tapped, but gaps are still being fetched back. Live samples
  /// are no longer written; the file is saved when the gaps are done.
  bool finishing = false;
  bool _saving = false;

  final _subs = <StreamSubscription>[];
  Timer? _timer;
  ConnectionPhase _phase = ConnectionPhase.disconnected;

  AppState() {
    Background.init();
    device.addListener(_onDeviceChanged);
    stager.addListener(notifyListeners);
    _subs.add(device.samples.listen(_onSamples));
    _subs.add(device.backfill.listen((e) => backfill.onEvent(e, DateTime.now())));
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _everySecond());
  }

  void _onDeviceChanged() {
    if (device.isConnected && samplesReceived == 0) {
      stager.loadModel(); // fetch the model while the first epoch fills
    }
    if (device.phase != _phase) {
      _phase = device.phase;
      if (_phase == ConnectionPhase.reconnecting) backfill.onLinkLost();
      // Disconnected on purpose: nothing more can be fetched, save now.
      if (!device.isActive && _phase != ConnectionPhase.connecting &&
          _phase != ConnectionPhase.scanning) {
        if (recorder.isRecording) _save();
        Background.stop();
      } else {
        Background.update(_statusText());
      }
    }
    notifyListeners();
  }

  void _everySecond() {
    backfill.tick(DateTime.now(),
        linkReadySince: device.isConnected ? device.connectedSince : null,
        head: _lastSampleNumber);
    if (finishing && backfill.idle) _save();
    if (recorder.isRecording) {
      if (DateTime.now().second == 0) Background.update(_statusText());
      notifyListeners(); // recording time, backfill progress
    }
  }

  String _statusText() {
    if (device.phase == ConnectionPhase.reconnecting) {
      return 'Connection lost, reconnecting…';
    }
    if (!recorder.isRecording) return 'Connected';
    final e = recorder.elapsed;
    return 'Recording for ${e.inHours} h ${e.inMinutes % 60} min';
  }

  void _onSamples(SampleBlock block) {
    final numbers = <int>[];
    final values = <List<double>>[];
    for (var i = 0; i < block.length; i++) {
      final n = block.sampleNumbers[i];
      final last = _lastSampleNumber;
      if (last != null && n + 10 * kSampleRateHz < last) {
        _deviceRestarted();
      } else if (last != null && n <= last) {
        continue; // arrived twice, or an old packet after a reconnect
      } else if (last != null && n > last + 1) {
        samplesLost += n - last - 1;
        if (recorder.isRecording && !finishing) backfill.addGap(last + 1, n - 1);
      }
      _lastSampleNumber = n;
      numbers.add(n);
      values.add(block.microvolts[i]);
      final uv = block.microvolts[i];
      for (var ch = 0; ch < kChannels; ch++) {
        raw[ch].add(uv[ch]);
        filtered[ch].add(_filters[ch].apply(uv[ch]));
      }
    }
    if (numbers.isEmpty) return;
    samplesReceived += numbers.length;
    stager.add(values.map((s) => s[sleepChannel]));
    if (!finishing) recorder.write(SampleBlock(numbers, values));
    notifyListeners();
  }

  /// The sample counter started again from zero: the device was switched
  /// off and on. Samples from before cannot be asked for by number any
  /// more, so the recording is saved and a new one begins.
  void _deviceRestarted() {
    _lastSampleNumber = null;
    for (final f in _filters) {
      f.reset();
    }
    if (recorder.isRecording) {
      backfill.missing += backfill.pending;
      backfill.clear();
      final wasFinishing = finishing;
      _save().then((_) {
        if (!wasFinishing && device.isActive) startRecording();
      });
    }
  }

  Future<void> connect() async {
    samplesReceived = 0;
    samplesLost = 0;
    _lastSampleNumber = null;
    for (final b in [...raw, ...filtered]) {
      b.clear();
    }
    for (final f in _filters) {
      f.reset();
    }
    stager.reset();
    await Background.start('Connecting…');
    await device.connect();
  }

  Future<void> disconnect() => device.disconnect();

  void setChannel(int ch) {
    channel = ch;
    notifyListeners();
  }

  /// Scoring starts over: the model must not mix two channels.
  void setSleepChannel(int ch) {
    sleepChannel = ch;
    stager.reset();
    notifyListeners();
  }

  Future<void> startRecording() async {
    await Background.askToIgnoreBatteryOptimization();
    backfill.clear();
    backfill.recovered = backfill.missing = 0;
    await recorder.start(device.deviceName ?? 'Traumschreiber');
    Background.update(_statusText());
    notifyListeners();
  }

  /// Stops the recording. If gaps are still waiting to be fetched from the
  /// SD card, it first waits for them ([finishing]); [saveNow] skips that.
  Future<void> stopRecording() async {
    if (!backfill.idle && device.isActive) {
      finishing = true;
      notifyListeners();
      return;
    }
    await _save();
  }

  Future<void> saveNow() => _save();

  /// Saves the file, and next to it what happened meanwhile: sleep stages
  /// (…_stages.csv) and button presses (…_button.csv).
  Future<void> _save() async {
    if (_saving || !recorder.isRecording) return;
    _saving = true;
    finishing = false;
    backfill.missing += backfill.pending;
    backfill.clear();
    notifyListeners();
    final started = recorder.startedAt;
    final file = await recorder.stop();
    if (file != null && started != null) {
      final epochs = stager.hypnogram.where(
          (e) => e.start.add(const Duration(seconds: 30)).isAfter(started));
      if (epochs.isNotEmpty) {
        await File(file.path.replaceFirst('.csv', '_stages.csv')).writeAsString(
            'epoch_start,stage,confidence,p_wake,p_n1,p_n2,p_n3,p_rem\n'
            '${epochs.map((e) => '${e.start.toIso8601String()},${e.stage.name},${e.confidence.toStringAsFixed(3)},${e.probabilities.map((p) => p.toStringAsFixed(3)).join(',')}').join('\n')}\n');
      }
      final presses = device.buttonPresses.where((t) => t.isAfter(started));
      if (presses.isNotEmpty) {
        await File(file.path.replaceFirst('.csv', '_button.csv')).writeAsString(
            'button_pressed_at\n${presses.map((t) => t.toIso8601String()).join('\n')}\n');
      }
    }
    _saving = false;
    Background.update(_statusText());
    notifyListeners();
  }

  bool get saving => _saving;

  @override
  void dispose() {
    _timer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    Background.stop();
    device.dispose();
    stager.dispose();
    super.dispose();
  }
}

/// Fixed-size buffer that keeps the newest values.
class RingBuffer {
  final Float64List _data;
  int _next = 0;
  int length = 0;
  RingBuffer(int capacity) : _data = Float64List(capacity);

  void add(double v) {
    _data[_next] = v;
    _next = (_next + 1) % _data.length;
    length = math.min(length + 1, _data.length);
  }

  void clear() => length = _next = 0;

  /// The newest [n] values, oldest first.
  Float64List last(int n) {
    n = math.min(n, length);
    final out = Float64List(n);
    for (var i = 0; i < n; i++) {
      out[i] = _data[(_next - n + i) % _data.length];
    }
    return out;
  }
}

/// Causal filter for the live plot: high-pass 0.5 Hz, low-pass 35 Hz and a
/// 50 Hz notch, each a second-order section (biquad, RBJ audio cookbook).
/// Use 60 instead of 50 Hz where the mains frequency is 60 Hz.
class DisplayFilter {
  final _stages = [
    Biquad.highPass(0.5, kSampleRateHz.toDouble()),
    Biquad.lowPass(35, kSampleRateHz.toDouble()),
    Biquad.notch(50, kSampleRateHz.toDouble()),
  ];

  double? _offset;

  double apply(double x) {
    // Electrodes can sit at tens of millivolts DC. Starting the high-pass
    // from that value would ring for seconds, so start it from zero.
    x -= _offset ??= x;
    for (final s in _stages) {
      x = s.apply(x);
    }
    return x;
  }

  void reset() {
    _offset = null;
    for (final s in _stages) {
      s.reset();
    }
  }
}

class Biquad {
  final double b0, b1, b2, a1, a2;
  double _x1 = 0, _x2 = 0, _y1 = 0, _y2 = 0;
  Biquad._(double b0, double b1, double b2, double a0, double a1, double a2)
      : b0 = b0 / a0, b1 = b1 / a0, b2 = b2 / a0, a1 = a1 / a0, a2 = a2 / a0;

  factory Biquad.lowPass(double f, double fs, {double q = 0.7071}) {
    final w = 2 * math.pi * f / fs, c = math.cos(w), a = math.sin(w) / (2 * q);
    return Biquad._((1 - c) / 2, 1 - c, (1 - c) / 2, 1 + a, -2 * c, 1 - a);
  }

  factory Biquad.highPass(double f, double fs, {double q = 0.7071}) {
    final w = 2 * math.pi * f / fs, c = math.cos(w), a = math.sin(w) / (2 * q);
    return Biquad._((1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + a, -2 * c, 1 - a);
  }

  factory Biquad.notch(double f, double fs, {double q = 30}) {
    final w = 2 * math.pi * f / fs, c = math.cos(w), a = math.sin(w) / (2 * q);
    return Biquad._(1, -2 * c, 1, 1 + a, -2 * c, 1 - a);
  }

  double apply(double x) {
    final y = b0 * x + b1 * _x1 + b2 * _x2 - a1 * _y1 - a2 * _y2;
    _x2 = _x1;
    _x1 = x;
    _y2 = _y1;
    _y1 = y;
    return y;
  }

  void reset() => _x1 = _x2 = _y1 = _y2 = 0;
}
