// Power spectrum of an EEG segment (Welch's method: average the FFT of
// overlapping, Hann-windowed pieces). Short enough to read in one go.
import 'dart:math' as math;
import 'dart:typed_data';

class Spectrum {
  final double binHz; // frequency step between two values
  final Float64List power; // µV²/Hz, index i = i·binHz

  const Spectrum(this.binHz, this.power);

  /// Mean power between [fromHz] and [toHz] (inclusive), µV²/Hz.
  double band(double fromHz, double toHz) {
    var sum = 0.0;
    var n = 0;
    for (var i = (fromHz / binHz).ceil(); i * binHz <= toHz && i < power.length; i++) {
      sum += power[i];
      n++;
    }
    return n == 0 ? 0 : sum / n;
  }
}

/// [segment] samples per piece (power of two), half overlapping.
Spectrum welch(List<double> x, double fs, {int segment = 512}) {
  final half = segment ~/ 2 + 1;
  final power = Float64List(half);
  final window = Float64List.fromList(List.generate(
      segment, (i) => 0.5 - 0.5 * math.cos(2 * math.pi * i / (segment - 1))));
  final windowEnergy = window.fold(0.0, (a, w) => a + w * w);
  var pieces = 0;
  for (var start = 0; start + segment <= x.length; start += segment ~/ 2) {
    var mean = 0.0;
    for (var i = 0; i < segment; i++) {
      mean += x[start + i];
    }
    mean /= segment;
    final re = Float64List(segment), im = Float64List(segment);
    for (var i = 0; i < segment; i++) {
      re[i] = (x[start + i] - mean) * window[i];
    }
    fft(re, im);
    for (var k = 0; k < half; k++) {
      final p = (re[k] * re[k] + im[k] * im[k]) / (fs * windowEnergy);
      power[k] += (k == 0 || k == half - 1) ? p : 2 * p; // one-sided
    }
    pieces++;
  }
  if (pieces > 0) {
    for (var k = 0; k < half; k++) {
      power[k] /= pieces;
    }
  }
  return Spectrum(fs / segment, power);
}

/// In-place radix-2 FFT. Length must be a power of two.
void fft(Float64List re, Float64List im) {
  final n = re.length;
  for (var i = 1, j = 0; i < n; i++) {
    var bit = n >> 1;
    for (; j & bit != 0; bit >>= 1) {
      j ^= bit;
    }
    j ^= bit;
    if (i < j) {
      var t = re[i];
      re[i] = re[j];
      re[j] = t;
      t = im[i];
      im[i] = im[j];
      im[j] = t;
    }
  }
  for (var len = 2; len <= n; len <<= 1) {
    final angle = -2 * math.pi / len;
    for (var i = 0; i < n; i += len) {
      for (var k = 0; k < len ~/ 2; k++) {
        final wr = math.cos(angle * k), wi = math.sin(angle * k);
        final a = i + k, b = a + len ~/ 2;
        final xr = re[b] * wr - im[b] * wi, xi = re[b] * wi + im[b] * wr;
        re[b] = re[a] - xr;
        im[b] = im[a] - xi;
        re[a] += xr;
        im[a] += xi;
      }
    }
  }
}
