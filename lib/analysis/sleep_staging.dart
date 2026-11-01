// Live sleep staging with AnySleep (https://github.com/dslaborg/AnySleep,
// MIT licence), exported to ONNX.
//
// How it works: collect one EEG channel, cut it into 30-second epochs, and
// after every new epoch run the model over the last ten minutes. Only the
// newest epoch is kept; the older ones give the model context (it looks at
// neighbouring epochs, like a human scorer does).
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
import 'package:onnxruntime/onnxruntime.dart';
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
  static const int contextEpochs = 20; // ten minutes

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
      if (_context.length > contextEpochs) _context.removeAt(0);
      _epochCount++;
      _scoreNewest();
    }
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
    // still busy (it takes well under a second, an epoch is 30 s).
    final path = _modelPath;
    if (path == null || _busy || _context.length < 2) return;
    _busy = true;
    final start = _start!.add(Duration(seconds: 30 * (_epochCount - 1)));
    final epochs = _context.length;
    final signal = Float64List(epochs * epochSamples);
    for (var e = 0; e < epochs; e++) {
      signal.setAll(e * epochSamples, _context[e]);
    }
    try {
      // Runs on a background isolate so the UI stays smooth. The closure
      // may only use local variables: everything it touches is copied over.
      final p = await Isolate.run(() => _infer(path, signal, epochs));
      var best = 0;
      for (var k = 1; k < 5; k++) {
        if (p[k] > p[best]) best = k;
      }
      hypnogram.add(Epoch(start, SleepStage.values[best], p));
      error = null;
    } catch (e) {
      error = 'Scoring failed: $e';
    }
    _busy = false;
    notifyListeners();
  }
}

/// Preprocess exactly like the Python reference, run the model, return the
/// stage probabilities of the LAST epoch.
List<double> _infer(String modelPath, Float64List signal, int epochs) {
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
  final logits = [for (final v in rows[math.min(epochs, rows.length) - 1] as List) (v as num).toDouble()];
  tensor.release();
  options.release();
  for (final o in outputs) {
    o?.release();
  }
  session.release();

  final m = logits.reduce(math.max); // softmax
  final e = [for (final l in logits) math.exp(l - m)];
  final sum = e.reduce((a, b) => a + b);
  return [for (final v in e) v / sum];
}
