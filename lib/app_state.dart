// The app's single piece of state. It listens to the device and hands every
// block of samples to the four consumers: live plot, spectrum, sleep staging
// and recorder. The pages only read from here and call its methods.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'analysis/sleep_staging.dart';
import 'recording/recorder.dart';
import 'traumschreiber/traumschreiber.dart';

class AppState extends ChangeNotifier {
  static const int bufferSeconds = 60;

  final device = Traumschreiber();
  final recorder = Recorder();
  final stager = SleepStager();

  /// Last 60 s per channel: raw (for the spectrogram) and filtered
  /// 0.5–35 Hz + 50 Hz notch (for the live plot).
  final raw = List.generate(kChannels, (_) => RingBuffer(bufferSeconds * kSampleRateHz));
  final filtered = List.generate(kChannels, (_) => RingBuffer(bufferSeconds * kSampleRateHz));
  final _filters = List.generate(kChannels, (_) => DisplayFilter());

  int channel = 0; // shown in the live plot and the spectrum
  int sleepChannel = 0; // scored by the sleep model
  int samplesReceived = 0;
  int samplesLost = 0;
  int? _lastSampleNumber;
  StreamSubscription<SampleBlock>? _sub;

  AppState() {
    device.addListener(_onDeviceChanged);
    stager.addListener(notifyListeners);
    _sub = device.samples.listen(_onSamples);
  }

  void _onDeviceChanged() {
    if (device.isConnected && samplesReceived == 0) {
      stager.loadModel(); // fetch the model while the first epoch fills
    }
    if (!device.isConnected && recorder.isRecording) stopRecording();
    notifyListeners();
  }

  void _onSamples(SampleBlock block) {
    for (var i = 0; i < block.length; i++) {
      final n = block.sampleNumbers[i];
      final last = _lastSampleNumber;
      if (last != null && n > last + 1) samplesLost += n - last - 1;
      _lastSampleNumber = n;
      final uv = block.microvolts[i];
      for (var ch = 0; ch < kChannels; ch++) {
        raw[ch].add(uv[ch]);
        filtered[ch].add(_filters[ch].apply(uv[ch]));
      }
    }
    samplesReceived += block.length;
    stager.add(block.microvolts.map((s) => s[sleepChannel]));
    recorder.write(block);
    notifyListeners();
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
    await recorder.start(device.deviceName ?? 'Traumschreiber');
    notifyListeners();
  }

  /// Stops the recording and stores what happened meanwhile next to it:
  /// sleep stages (…_stages.csv) and button presses (…_button.csv).
  Future<void> stopRecording() async {
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
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
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
