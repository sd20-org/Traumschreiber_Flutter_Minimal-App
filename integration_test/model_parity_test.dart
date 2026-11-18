// Runs the sleep model on a phone and compares it with the Python reference.
//
// Use it after changing the ONNX runtime or the preprocessing. The input is
// a few windows of 20 epochs from a real night, the expected probabilities
// come from the Python script (PythonScriptsOriginal/plot_sleep_scoring.py
// with onnxruntime). tool/make_parity_fixture.py writes both files into
// assets/models/ (ignored by git); remove them after the test:
//
//   python tool/make_parity_fixture.py REC.csv .../PythonScriptsOriginal
//   flutter test integration_test/model_parity_test.dart -d <device>
//
// The probabilities per epoch are printed as one line starting with
// PARITY_ROWS.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:traumschreiber_minimal/analysis/sleep_staging.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('sleep model matches the Python reference', (tester) async {
    final expected = jsonDecode(await rootBundle.loadString('assets/models/parity_expected.json'));
    final epochs = expected['epochs'] as int;
    final raw = await rootBundle.load('assets/models/parity_fixture.bin');
    final all = Float64List.fromList(raw.buffer.asFloat64List(raw.offsetInBytes, raw.lengthInBytes ~/ 8));

    final model = File('${(await getTemporaryDirectory()).path}/anysleep.onnx');
    final bytes = await rootBundle.load('assets/models/anysleep.onnx');
    model.writeAsBytesSync(bytes.buffer.asUint8List());

    final windows = (expected['python'] as List).length;
    final result = <List<List<double>>>[];
    var maxDiff = 0.0, sameStage = 0, total = 0;
    for (var w = 0; w < windows; w++) {
      final n = epochs * 7500;
      final signal = Float64List.fromList(all.sublist(w * n, (w + 1) * n));
      final rows = inferAll(model.path, signal, epochs);
      result.add(rows);
      final py = expected['python'][w] as List;
      for (var e = 0; e < epochs; e++) {
        final ref = [for (final v in py[e] as List) (v as num).toDouble()];
        for (var k = 0; k < 5; k++) {
          maxDiff = math.max(maxDiff, (rows[e][k] - ref[k]).abs());
        }
        if (stageOf(rows[e]) == stageOf(ref)) sameStage++;
        total++;
      }
    }
    // ignore: avoid_print
    print('PARITY_ROWS ${jsonEncode(result)}');
    // ignore: avoid_print
    print('PARITY max_diff=$maxDiff same_stage=$sameStage/$total');
    // Measured 18.11.2026 (ONNX Runtime 1.15 and 1.32 alike): 57 of 60 epochs,
    // max difference 0.079. The rest comes from small differences between the
    // Dart and the Python filters, not from the runtime.
    expect(sameStage, greaterThanOrEqualTo(total * 9 ~/ 10));
    expect(maxDiff, lessThan(0.1));
  });
}
