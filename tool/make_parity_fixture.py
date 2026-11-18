"""Input and Python reference for integration_test/model_parity_test.dart.

Takes three windows of 20 epochs (30 s each) of one channel from a recording of this app, scores
them with the Python preprocessing (PythonScriptsOriginal/plot_sleep_scoring.py from the
Traumschreiber repository) and onnxruntime, and writes

  assets/models/parity_fixture.bin    the raw signal, float64 little endian
  assets/models/parity_expected.json  the probabilities per epoch

Usage:
  python tool/make_parity_fixture.py RECORDING.csv PATH/TO/PythonScriptsOriginal [channel]

Both output files are ignored by git; delete them after the test.
"""
import itertools, json, sys
import numpy as np
import onnxruntime as ort

csv_path, scripts = sys.argv[1], sys.argv[2]
channel = int(sys.argv[3]) if len(sys.argv) > 3 else 2
sys.path.insert(0, scripts)
from plot_sleep_scoring import preprocess  # noqa: E402

STARTS, N, EPOCH = [100, 400, 800], 20, 7500
need = (max(STARTS) + N) * EPOCH
vals = []
with open(csv_path) as f:
    for line in f:
        if line[0].isdigit():
            break
    for line in itertools.chain([line], f):
        vals.append(float(line.split(',')[2 + channel]))
        if len(vals) >= need:
            break
x = np.array(vals, dtype=np.float64)
sess = ort.InferenceSession('assets/models/anysleep.onnx')
fixture, expected = [], []
for s in STARTS:
    seg = x[s * EPOCH:(s + N) * EPOCH]
    fixture.append(seg)
    sm, _ = preprocess(seg, 250)
    sm = sm[:N * 3840].astype(np.float32)
    logits = sess.run(None, {'signal': sm.reshape(1, -1, 1)})[0][0][:N]
    e = np.exp(logits - logits.max(1, keepdims=True))
    expected.append((e / e.sum(1, keepdims=True)).tolist())
np.concatenate(fixture).astype('<f8').tofile('assets/models/parity_fixture.bin')
json.dump({'starts': STARTS, 'epochs': N, 'python': expected, 'ort': ort.__version__},
          open('assets/models/parity_expected.json', 'w'))
print('wrote', len(fixture) * N, 'epochs')
