import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:traumschreiber_minimal/analysis/spectrum.dart';
import 'package:traumschreiber_minimal/app_state.dart';
import 'package:traumschreiber_minimal/traumschreiber/traumschreiber.dart';

/// Builds a Data notification the way the firmware does.
List<int> packet(List<int> sampleNumbers, List<List<int>> counts) {
  final b = BytesBuilder()..addByte(0xC0);
  for (var s = 0; s < sampleNumbers.length; s++) {
    final bd = ByteData(4 + 8 + 3 * 8 + 4)
      ..setUint32(0, sampleNumbers[s], Endian.little)
      ..setUint64(4, 123456, Endian.little);
    for (var ch = 0; ch < 8; ch++) {
      final v = counts[s][ch] & 0xFFFFFF;
      bd
        ..setUint8(12 + 3 * ch, v & 0xFF)
        ..setUint8(13 + 3 * ch, (v >> 8) & 0xFF)
        ..setUint8(14 + 3 * ch, (v >> 16) & 0xFF);
    }
    b.add(bd.buffer.asUint8List());
  }
  return b.toBytes();
}

void main() {
  test('decodes 24-bit values to microvolts, including negative ones', () {
    final status = DeviceStatus.fallback; // gain ×4 on all channels
    final p = packet([100, 101], [
      [1000, -1000, 0, 8388607, -8388608, 1, -1, 2],
      [0, 0, 0, 0, 0, 0, 0, 0],
    ]);
    final block = decodePacket(p, status);
    expect(block.sampleNumbers, [100, 101]);
    const uvPerCount = 1.2e6 / 4 / 8388608;
    expect(block.microvolts[0][0], closeTo(1000 * uvPerCount, 1e-9));
    expect(block.microvolts[0][1], closeTo(-1000 * uvPerCount, 1e-9));
    expect(block.microvolts[0][3], closeTo(300000, 0.1)); // full scale ±300 mV
    expect(block.microvolts[0][4], closeTo(-300000, 0.1));
  });

  test('a lone 0xC0 keep-alive byte carries no samples', () {
    expect(decodePacket([0xC0], DeviceStatus.fallback).length, 0);
  });

  test('reads channel list, sample counter and per-channel gain from status', () {
    final raw = <int>[1, ...List.filled(12, 0), 0xFF, 8, 0, 1, 2, 3, 4, 5, 6, 7];
    raw.add(0); // compress bits
    raw.addAll([0, 0, 0, 0]); // delta max
    raw.addAll([0x10, 0x27, 0, 0]); // sample counter 10000
    raw.addAll([0, 0, 0, 0]); // SD state
    raw.addAll([4, 3]); // gain, bytes per value
    raw.addAll([4, 4, 8, 4, 4, 4, 4, 4]); // gain per channel
    final s = DeviceStatus.parse(raw);
    expect(s.channels, [0, 1, 2, 3, 4, 5, 6, 7]);
    expect(s.sampleCounter, 10000);
    expect(s.gains[2], 8);
  });

  test('spectrum peaks at the frequency of a sine', () {
    final x = [for (var i = 0; i < 2000; i++) 20 * math.sin(2 * math.pi * 10 * i / 250)];
    final s = welch(x, 250);
    var peak = 0;
    for (var i = 1; i < s.power.length; i++) {
      if (s.power[i] > s.power[peak]) peak = i;
    }
    expect(peak * s.binHz, closeTo(10, s.binHz));
    expect(s.band(8, 12), greaterThan(100 * s.band(20, 30)));
  });

  test('display filter removes DC offset and 50 Hz mains', () {
    final f = DisplayFilter();
    final out = [
      for (var i = 0; i < 2500; i++)
        f.apply(-70000 + 50 * math.sin(2 * math.pi * 50 * i / 250) + 10 * math.sin(2 * math.pi * 10 * i / 250))
    ];
    final tail = out.sublist(1500);
    final maxAbs = tail.map((v) => v.abs()).reduce(math.max);
    expect(maxAbs, lessThan(15)); // 10 µV alpha stays, offset and 50 Hz go
    expect(maxAbs, greaterThan(7));
  });

  test('ring buffer keeps the newest values in order', () {
    final r = RingBuffer(5);
    for (var i = 1; i <= 7; i++) {
      r.add(i.toDouble());
    }
    expect(r.last(5), [3, 4, 5, 6, 7]);
    expect(r.last(2), [6, 7]);
  });
}
