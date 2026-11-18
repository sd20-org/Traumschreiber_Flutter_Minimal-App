// Live sleep staging with AnySleep (https://github.com/dslaborg/AnySleep,
// MIT licence), exported to ONNX.
//
// How it works: collect one EEG channel, cut it into 30-second epochs, and
// after every new epoch run the model over the last 20.5 minutes (41 epochs).
// The model looks at neighbouring epochs, like a human scorer does, so each
// run gives two results:
//   - the newest epoch, scored from the past only. It is shown at once as the
//     current stage.
//   - the epoch ten minutes back, which now has ten minutes of context on
//     both sides. Its score replaces the quick one in the hypnogram.
// When a recording stops, the last ten minutes are scored once more with the
// context there is, so the saved hypnogram has no quick scores left.
//
// The model file (~13 MB) is taken from, in this order:
//   1. a copy saved by an earlier start of the app,
//   2. the asset assets/models/anysleep.onnx, if you bundled it
//      (tool/fetch_model.sh), which works offline,
//   3. a download from [kModelUrl].
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:onnxruntime_v2/onnxruntime_v2.dart';
import 'package:path_provider/path_provider.dart';

import 'dsp_filters.dart';

const String kModelUrl =
    'https://github.com/sd20-org/Traumschreiber_Flutter_Minimal-App/releases/download/anysleep-onnx-v1/anysleep.onnx';
const String _kModelAsset = 'assets/models/anysleep.onnx';

enum SleepStage { wake, n1, n2, n3, rem } // order of the model's output

class Epoch {
  final DateTime start; // wall-clock start of these 30 s
  final SleepStage stage;
  final List<double> probabilities; // Wake, N1, N2, N3, REM; sum = 1
  const Epoch(this.start, this.stage, this.probabilities);

  double get confidence => probabilities[stage.index];
}

enum ModelState { notLoaded, loading, ready, failed }

class SleepStager extends ChangeNotifier {
  static const int epochSamples = 30 * 250;

  /// Epochs of context on each side of a rescored epoch (ten minutes).
  static const int lag = 20;

  /// Epochs the model sees per run: [lag] before, the epoch itself, [lag] after.
  static const int windowEpochs = 2 * lag + 1;

  final List<Epoch> hypnogram = [];
  ModelState modelState = ModelState.notLoaded;
  String? error;

  final List<double> _partial = [];
  final List<Float64List> _context = [];
  int _epochCount = 0;
  DateTime? _start;
  bool _busy = false;
  String? _modelPath;

  /// Seconds of data collected towards the next epoch.
  double get secondsIntoEpoch => _partial.length / 250;

  void reset() {
    hypnogram.clear();
    _partial.clear();
    _context.clear();
    _epochCount = 0;
    _start = null;
    notifyListeners();
  }

  /// Feed new samples (µV, 250 Hz) of the channel to be scored.
  void add(Iterable<double> microvolts) {
    _start ??= DateTime.now();
    _partial.addAll(microvolts);
    while (_partial.length >= epochSamples) {
      _context.add(Float64List.fromList(_partial.sublist(0, epochSamples)));
      _partial.removeRange(0, epochSamples);
      if (_context.length > windowEpochs) _context.removeAt(0);
      _epochCount++;
      _scoreNewest();
    }
  }

  /// Rescores the last [lag] epochs with the context that exists now. Called
  /// before a recording is saved, so the saved hypnogram holds no quick
  /// (past-only) scores. Waits for a run that is still busy.
  Future<void> finishTail() async {
    for (var i = 0; _busy && i < 100; i++) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    final path = _modelPath;
    if (path == null || _busy || _context.length < 2) return;
    _busy = true;
    try {
      final rows = await _run(path);
      final n = _context.length;
      for (var j = math.max(0, n - lag); j < n; j++) {
        _replace(_epochStart(n - 1 - j), rows[j]);
      }
    } catch (e) {
      error = 'Scoring failed: $e';
    }
    _busy = false;
    notifyListeners();
  }

  /// Start of the epoch [back] epochs before the newest one.
  DateTime _epochStart(int back) =>
      _start!.add(Duration(seconds: 30 * (_epochCount - 1 - back)));

  Future<List<List<double>>> _run(String path) {
    final epochs = _context.length;
    final signal = Float64List(epochs * epochSamples);
    for (var e = 0; e < epochs; e++) {
      signal.setAll(e * epochSamples, _context[e]);
    }
    // Runs on a background isolate so the UI stays smooth. The closure may
    // only use local variables: everything it touches is copied over.
    return Isolate.run(() => inferAll(path, signal, epochs));
  }

  /// Puts probabilities [p] into the hypnogram entry starting at [start].
  /// If that epoch was never scored (the first one, or one skipped while the
  /// model was busy), it is inserted at its place.
  void _replace(DateTime start, List<double> p) {
    final epoch = Epoch(start, stageOf(p), p);
    for (var i = hypnogram.length - 1; i >= 0; i--) {
      final d = hypnogram[i].start.difference(start).inMilliseconds;
      if (d.abs() < 1000) {
        hypnogram[i] = epoch;
        return;
      }
      if (d < 0) {
        hypnogram.insert(i + 1, epoch);
        return;
      }
    }
    hypnogram.insert(0, epoch);
  }

  Future<void> loadModel() async {
    if (modelState == ModelState.loading || modelState == ModelState.ready) return;
    modelState = ModelState.loading;
    error = null;
    notifyListeners();
    try {
      final file =
          File('${(await getApplicationSupportDirectory()).path}/anysleep.onnx');
      if (!await file.exists()) {
        Uint8List bytes;
        try {
          bytes = (await rootBundle.load(_kModelAsset)).buffer.asUint8List();
        } catch (_) {
          final r = await http.get(Uri.parse(kModelUrl));
          if (r.statusCode != 200) throw 'Model download failed (HTTP ${r.statusCode})';
          bytes = r.bodyBytes;
        }
        if (bytes.length < 1000000) throw 'Model file is incomplete';
        await file.writeAsBytes(bytes, flush: true);
      }
      _modelPath = file.path;
      modelState = ModelState.ready;
    } catch (e) {
      modelState = ModelState.failed;
      error = '$e';
    }
    notifyListeners();
  }

  Future<void> _scoreNewest() async {
    // The model needs at least two epochs; skip if the previous run is
    // still busy (it takes about a second, an epoch is 30 s).
    final path = _modelPath;
    if (path == null || _busy || _context.length < 2) return;
    _busy = true;
    final start = _epochStart(0);
    try {
      final rows = await _run(path);
      hypnogram.add(Epoch(start, stageOf(rows.last), rows.last));
      // The epoch [lag] back now has [lag] epochs of context on each side.
      if (rows.length == windowEpochs) _replace(_epochStart(lag), rows[lag]);
      error = null;
    } catch (e) {
      error = 'Scoring failed: $e';
    }
    _busy = false;
    notifyListeners();
  }
}

/// The most likely stage.
SleepStage stageOf(List<double> p) {
  var best = 0;
  for (var k = 1; k < 5; k++) {
    if (p[k] > p[best]) best = k;
  }
  return SleepStage.values[best];
}

/// Preprocess exactly like the Python reference, run the model and return
/// the stage probabilities of every epoch in [signal].
List<List<double>> inferAll(String modelPath, Float64List signal, int epochs) {
  final x = DspFilters.clipAndRobustScale(DspFilters.resample250to128(
      DspFilters.bandpass03_35(DspFilters.notch50(signal))));
  final len = epochs * 3840; // 30 s at 128 Hz
  final input = Float32List(len);
  for (var i = 0; i < len && i < x.length; i++) {
    input[i] = x[i];
  }

  OrtEnv.instance.init();
  final session = OrtSession.fromFile(File(modelPath), OrtSessionOptions());
  final tensor = OrtValueTensor.createTensorWithDataList(input, [1, len, 1]);
  final options = OrtRunOptions();
  final outputs = session.run(options, {'signal': tensor});
  final rows = (outputs[0]!.value as List)[0] as List; // [epochs][5] logits
  final result = [
    for (final row in rows.take(epochs)) _softmax([for (final v in row as List) (v as num).toDouble()])
  ];
  tensor.release();
  options.release();
  for (final o in outputs) {
    o?.release();
  }
  session.release();
  return result;
}

List<double> _softmax(List<double> logits) {
  final m = logits.reduce(math.max);
  final e = [for (final l in logits) math.exp(l - m)];
  final sum = e.reduce((a, b) => a + b);
  return [for (final v in e) v / sum];
}
