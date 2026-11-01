// AnySleep preprocessing, identical to the Python reference script
// `plot_sleep_scoring.py` in Traumschreiber_Python_Offline-Data-Analysis.
// Keep both in sync: the model only gives sensible results on exactly this
// input.
import 'dart:math' as math;
import 'dart:typed_data';

/// Lightweight DSP toolkit for the AnySleep preprocessing pipeline.
///
/// Mirrors the Python `preprocess()` function in `plot_sleep_scoring.py`:
///   1. 50 Hz IIR notch                         (powerline rejection)
///   2. 4th-order Butterworth bandpass 0.3–35 Hz (clinical filter)
///   3. Polyphase resample 250 Hz → 128 Hz       (model expects 128 Hz)
///   4. IQR clip ± 20 × IQR                      (outlier rejection)
///   5. Robust scaling: (x - median) / IQR       (RobustScaler-equivalent)
///
/// Coefficients were generated once via scipy.signal at fs=250 Hz and hard-
/// coded below. The polyphase resampler builds its 1251 Kaiser-windowed sinc
/// taps on first use and caches them. All operations work on `Float64List`
/// internally; convert to `Float32List` at the model-input boundary.
class DspFilters {
  // ── SOS coefficient banks (precomputed via scipy.signal, fs = 250 Hz) ─────

  /// 50 Hz notch, Q = 30. From `scipy.signal.iirnotch(50.0, 30.0, fs=250.0)`.
  /// One biquad per row: [b0, b1, b2, a0, a1, a2] (a0 always 1.0).
  static const List<List<double>> _notchSos = [
    [
      0.9794827609814495,
      -0.6053536376811252,
      0.9794827609814492,
      1.0,
      -0.6053536376811253,
      0.958965521962899,
    ],
  ];

  /// Butterworth bandpass 0.3 – 35 Hz, order 4.
  /// From `scipy.signal.butter(4, [0.3, 35.0], 'bandpass', fs=250, output='sos')`.
  static const List<List<double>> _bpSos = [
    [
      0.014414952294860658,
      0.028829904589721317,
      0.014414952294860658,
      1.0,
      -0.7577420703873005,
      0.17380286236271575,
    ],
    [
      1.0,
      2.0,
      1.0,
      1.0,
      -0.9900461525327643,
      0.5499005033272991,
    ],
    [
      1.0,
      -2.0,
      1.0,
      1.0,
      -1.9859498453869797,
      0.9860078759668492,
    ],
    [
      1.0,
      -2.0,
      1.0,
      1.0,
      -1.99425449255598,
      0.9943114395209083,
    ],
  ];

  // ── Biquad cascade (Direct-Form-II Transposed, with per-stage state) ──────

  /// Forward filter through a cascade of biquads, in-place.
  /// `state` must be at least `sos.length × 2` long (two w-states per biquad)
  /// and is updated; pass a fresh zero-initialized buffer per call.
  static void _sosFiltInPlace(
      Float64List x, List<List<double>> sos, Float64List state) {
    final n = x.length;
    final nSec = sos.length;
    for (int i = 0; i < n; i++) {
      double v = x[i];
      for (int s = 0; s < nSec; s++) {
        final coef = sos[s];
        final b0 = coef[0], b1 = coef[1], b2 = coef[2];
        final a1 = coef[4], a2 = coef[5];
        final s0 = state[s * 2], s1 = state[s * 2 + 1];
        final y = b0 * v + s0;
        state[s * 2]     = b1 * v - a1 * y + s1;
        state[s * 2 + 1] = b2 * v - a2 * y;
        v = y;
      }
      x[i] = v;
    }
  }

  /// Forward-then-reverse zero-phase filter equivalent to
  /// `scipy.signal.sosfiltfilt`. Returns a new array; input is not modified.
  ///
  /// No padding/extension is applied (scipy's default `padtype='odd'` with
  /// `padlen=6*nstages` reduces edge artifacts). For sleep-staging windows of
  /// ≥60 s, the edge effects are < 1 s and have negligible impact on the
  /// model output.
  static Float64List sosFiltFilt(Float64List x, List<List<double>> sos) {
    final fwd = Float64List.fromList(x);
    final state = Float64List(sos.length * 2);
    _sosFiltInPlace(fwd, sos, state);

    // Reverse, filter again with fresh state, reverse back.
    final rev = Float64List(fwd.length);
    final n = fwd.length;
    for (int i = 0; i < n; i++) {
      rev[i] = fwd[n - 1 - i];
    }
    final state2 = Float64List(sos.length * 2);
    _sosFiltInPlace(rev, sos, state2);
    final out = Float64List(n);
    for (int i = 0; i < n; i++) {
      out[i] = rev[n - 1 - i];
    }
    return out;
  }

  /// Convenience wrapper: 50 Hz notch (zero-phase).
  static Float64List notch50(Float64List x) => sosFiltFilt(x, _notchSos);

  /// Convenience wrapper: 0.3–35 Hz bandpass (zero-phase).
  static Float64List bandpass03_35(Float64List x) => sosFiltFilt(x, _bpSos);

  // ── Polyphase resampler 250 → 128 Hz (L=64, M=125) ────────────────────────

  static const int _resampleUp   = 64;
  static const int _resampleDown = 125;
  static const int _resampleTapsN = 1251; // 10 * max(L, M) + 1
  static Float64List? _resampleTapsCache;

  /// 0th-order modified Bessel function, Numerical Recipes approximation
  /// (~1e-7 absolute accuracy). Needed for the Kaiser window.
  static double _besselI0(double x) {
    final ax = x.abs();
    if (ax < 3.75) {
      final t  = x / 3.75;
      final t2 = t * t;
      return 1.0 +
          t2 *
              (3.5156229 +
                  t2 *
                      (3.0899424 +
                          t2 *
                              (1.2067492 +
                                  t2 *
                                      (0.2659732 +
                                          t2 *
                                              (0.0360768 +
                                                  t2 * 0.0045813)))));
    } else {
      final t = 3.75 / ax;
      return math.exp(ax) /
          math.sqrt(ax) *
          (0.39894228 +
              t *
                  (0.01328592 +
                      t *
                          (0.00225319 +
                              t *
                                  (-0.00157565 +
                                      t *
                                          (0.00916281 +
                                              t *
                                                  (-0.02057706 +
                                                      t *
                                                          (0.02635537 +
                                                              t *
                                                                  (-0.01647633 +
                                                                      t *
                                                                          0.00392377))))))));
    }
  }

  /// Build the polyphase filter taps once (Kaiser-windowed sinc, β=5).
  /// Matches `scipy.signal.resample_poly(up=64, down=125)` default behavior:
  ///   - n_taps = 10 * max(up, down) + 1 = 1251
  ///   - cutoff = 1 / max(up, down) = 1/125 (normalized to upsampled Nyquist)
  ///   - window = ('kaiser', beta=5)
  ///   - taps are multiplied by `up` (scipy's upsampling compensation).
  static Float64List _buildResampleTaps() {
    const beta = 5.0;
    const cutoff = 1.0 / 125.0;          // normalized to upsampled Nyquist
    const n = _resampleTapsN;
    final taps = Float64List(n);
    final i0Beta = _besselI0(beta);
    final mid = (n - 1) / 2.0;

    for (int k = 0; k < n; k++) {
      // Kaiser window
      final r = (2.0 * k / (n - 1)) - 1.0;        // ∈ [-1, +1]
      final winArg = beta * math.sqrt(math.max(0.0, 1.0 - r * r));
      final win = _besselI0(winArg) / i0Beta;

      // Sinc lowpass (firwin scales cutoff to 2*fc for Nyquist = 1)
      final x = k - mid;
      double sinc;
      if (x == 0.0) {
        sinc = 2.0 * cutoff;
      } else {
        final piX = math.pi * x;
        sinc = math.sin(2.0 * math.pi * cutoff * x) / piX;
      }

      taps[k] = win * sinc;
    }

    // Normalize so DC gain = 1 (firwin default), then multiply by `up` to
    // compensate for inserted zeros in the upsampled signal (scipy convention).
    double sum = 0;
    for (int k = 0; k < n; k++) {
      sum += taps[k];
    }
    final scale = _resampleUp / sum;
    for (int k = 0; k < n; k++) {
      taps[k] *= scale;
    }
    return taps;
  }

  static Float64List _getResampleTaps() {
    return _resampleTapsCache ??= _buildResampleTaps();
  }

  /// Resample `x` (sampled at 250 Hz) to 128 Hz.
  ///
  /// Mirrors `scipy.signal.resample_poly(x, up=64, down=125)`. Output length =
  /// `ceil(len(x) * up / down)` (rounded to match scipy).
  static Float64List resample250to128(Float64List x) {
    final taps = _getResampleTaps();
    const up = _resampleUp;
    const down = _resampleDown;
    final nIn = x.length;
    final nTaps = taps.length;

    // Output length (scipy's ceil convention)
    final nOut = ((nIn * up) + down - 1) ~/ down;

    // Half-length of the FIR (centering offset).
    final halfFilt = (nTaps - 1) ~/ 2;  // 625

    final out = Float64List(nOut);

    for (int m = 0; m < nOut; m++) {
      // Output sample m corresponds to fractional input index m*down/up.
      // In the upsampled domain we are at sample index m*down.
      final upsampledIdx = m * down;
      final phase = upsampledIdx % up;        // which polyphase branch
      // The first input sample touched by this output:
      //   inputIdxStart = (upsampledIdx + halfFilt) / up   — centered
      // For each tap k that has phase `phase`, the upsampled-domain index is
      //   upsampledIdx + halfFilt - tapPos,
      //   where tapPos = phase + j*up for j = 0..(taps_per_phase - 1).
      // Corresponding input sample: (upsampledIdx + halfFilt - tapPos) / up.
      double acc = 0;
      int tapPos = phase;                     // first tap in this phase
      int inputIdx = (upsampledIdx + halfFilt - phase) ~/ up;
      while (tapPos < nTaps) {
        if (inputIdx >= 0 && inputIdx < nIn) {
          acc += taps[tapPos] * x[inputIdx];
        }
        tapPos += up;
        inputIdx -= 1;
      }
      out[m] = acc;
    }

    return out;
  }

  // ── IQR clip + robust scale (mirrors Python preprocess Step 4-5) ──────────

  /// Returns the 25th and 75th percentile (linear interpolation, like numpy).
  /// `x` is unsorted; this method sorts a copy internally.
  static (double, double) _q25q75(Float64List x) {
    final n = x.length;
    if (n == 0) return (0.0, 0.0);
    final sorted = Float64List.fromList(x);
    final s = sorted.buffer.asFloat64List();
    _sortInPlace(s);

    double pct(double p) {
      final pos = p * (n - 1);
      final lo = pos.floor();
      final hi = pos.ceil();
      if (lo == hi) return s[lo];
      final f = pos - lo;
      return s[lo] * (1.0 - f) + s[hi] * f;
    }

    return (pct(0.25), pct(0.75));
  }

  static double _median(Float64List x) {
    final n = x.length;
    if (n == 0) return 0;
    final sorted = Float64List.fromList(x);
    _sortInPlace(sorted);
    if (n.isOdd) return sorted[n ~/ 2];
    return 0.5 * (sorted[n ~/ 2 - 1] + sorted[n ~/ 2]);
  }

  /// Quicksort on a Float64List in place. Dart's `List.sort` on `Float64List`
  /// works but boxes doubles via the Comparable contract; this version stays
  /// in primitive land and is ~2× faster on 100 k+ elements.
  static void _sortInPlace(Float64List a) {
    // Quicksort with Dual-Pivot is overkill; introsort would be ideal but
    // standard quicksort is enough for our window sizes.
    _quickSort(a, 0, a.length - 1);
  }

  static void _quickSort(Float64List a, int lo, int hi) {
    while (lo < hi) {
      if (hi - lo < 16) {
        // Insertion sort for small partitions
        for (int i = lo + 1; i <= hi; i++) {
          final v = a[i];
          int j = i - 1;
          while (j >= lo && a[j] > v) {
            a[j + 1] = a[j];
            j--;
          }
          a[j + 1] = v;
        }
        return;
      }
      // Median-of-three pivot
      final mid = (lo + hi) >> 1;
      if (a[lo] > a[mid]) {
        final t = a[lo]; a[lo] = a[mid]; a[mid] = t;
      }
      if (a[lo] > a[hi]) {
        final t = a[lo]; a[lo] = a[hi]; a[hi] = t;
      }
      if (a[mid] > a[hi]) {
        final t = a[mid]; a[mid] = a[hi]; a[hi] = t;
      }
      final pivot = a[mid];
      int i = lo, j = hi;
      while (i <= j) {
        while (a[i] < pivot) {
          i++;
        }
        while (a[j] > pivot) {
          j--;
        }
        if (i <= j) {
          final t = a[i]; a[i] = a[j]; a[j] = t;
          i++; j--;
        }
      }
      // Recurse on smaller partition, iterate on larger (tail-call elim)
      if (j - lo < hi - i) {
        _quickSort(a, lo, j);
        lo = i;
      } else {
        _quickSort(a, i, hi);
        hi = j;
      }
    }
  }

  /// Apply IQR clip ±20·IQR, then robust-scale: (x - median) / IQR.
  /// Returns a new Float64List; `x` is not modified.
  /// Mirrors `plot_sleep_scoring.py:preprocess` steps 4-5.
  static Float64List clipAndRobustScale(Float64List x) {
    final (q25, q75) = _q25q75(x);
    var iqr = q75 - q25;
    final result = Float64List(x.length);

    if (iqr > 0) {
      final lo = -20.0 * iqr;
      final hi =  20.0 * iqr;
      for (int i = 0; i < x.length; i++) {
        final v = x[i];
        result[i] = v < lo ? lo : (v > hi ? hi : v);
      }
    } else {
      result.setAll(0, x);
    }

    // Recompute median + IQR on clipped signal (matches Python)
    final med = _median(result);
    final (q25b, q75b) = _q25q75(result);
    final iqr2 = q75b - q25b;
    final denom = iqr2 > 1e-8 ? iqr2 : 1e-8;
    for (int i = 0; i < result.length; i++) {
      result[i] = (result[i] - med) / denom;
    }
    return result;
  }
}
