// Saves the stream as a CSV file, one line per sample, and lists, shares and
// deletes saved recordings. CSV opens in Excel, Python (pandas), R, MATLAB.
//
//   # Traumschreiber recording
//   # device: Traumschreiber
//   # started: 2026-11-01T22:14:03.000
//   # sample_rate_hz: 250
//   # unit: microvolt
//   sample_number,time_s,ch0,ch1,ch2,ch3,ch4,ch5,ch6,ch7
//   1734501,0.000,-12.41,3.08,…
//
// time_s comes from the device's sample counter, so it stays exact even
// if Bluetooth delivers packets late. A jump in sample_number = lost samples.
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../traumschreiber/traumschreiber.dart';

class Recording {
  final File file;
  final DateTime modified;
  final int bytes;
  const Recording(this.file, this.modified, this.bytes);

  String get name => file.uri.pathSegments.last;

  /// About 80 bytes per sample line.
  Duration get approxDuration =>
      Duration(milliseconds: bytes ~/ 80 * 1000 ~/ kSampleRateHz);
}

class Recorder {
  IOSink? _sink;
  File? file;
  DateTime? startedAt;
  int? _firstSample;
  int samplesWritten = 0;

  bool get isRecording => _sink != null;
  Duration get elapsed =>
      Duration(milliseconds: samplesWritten * 1000 ~/ kSampleRateHz);

  static Future<Directory> _folder() async {
    final dir = Directory(
        '${(await getApplicationDocumentsDirectory()).path}/recordings');
    return dir.create(recursive: true);
  }

  Future<void> start(String deviceName) async {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp = '${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
    file = File('${(await _folder()).path}/TS_$stamp.csv');
    _sink = file!.openWrite()
      ..writeln('# Traumschreiber recording')
      ..writeln('# device: $deviceName')
      ..writeln('# started: ${now.toIso8601String()}')
      ..writeln('# sample_rate_hz: $kSampleRateHz')
      ..writeln('# unit: microvolt')
      ..writeln('sample_number,time_s,'
          '${List.generate(kChannels, (c) => 'ch$c').join(',')}');
    startedAt = now;
    _firstSample = null;
    samplesWritten = 0;
  }

  void write(SampleBlock block) {
    final sink = _sink;
    if (sink == null) return;
    final buf = StringBuffer();
    for (var i = 0; i < block.length; i++) {
      final n = block.sampleNumbers[i];
      _firstSample ??= n;
      buf
        ..write(n)
        ..write(',')
        ..write(((n - _firstSample!) / kSampleRateHz).toStringAsFixed(3));
      for (final v in block.microvolts[i]) {
        buf
          ..write(',')
          ..write(v.toStringAsFixed(2));
      }
      buf.writeln();
    }
    sink.write(buf);
    samplesWritten += block.length;
  }

  Future<File?> stop() async {
    final sink = _sink;
    _sink = null;
    await sink?.flush();
    await sink?.close();
    return file;
  }

  static Future<List<Recording>> list() async {
    final files = (await _folder()).listSync().whereType<File>().toList();
    final list = [
      for (final f in files) Recording(f, f.lastModifiedSync(), f.lengthSync())
    ]..sort((a, b) => b.modified.compareTo(a.modified));
    return list;
  }

  static Future<void> share(List<File> files) =>
      SharePlus.instance.share(ShareParams(
          files: [for (final f in files) XFile(f.path, mimeType: 'text/csv')],
          subject: 'Traumschreiber recording'));
}
