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
// if Bluetooth delivers packets late. A jump in sample_number = samples
// that could not be fetched back (see backfill.dart).
//
// Samples fetched back from the SD card arrive late. They go to a second
// file next to the recording (…csv.backfill); when the recording stops,
// both files are merged by sample number. Both are already sorted, so the
// merge reads them line by line and needs almost no memory.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

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
  IOSink? _backfillSink;
  File? file;
  DateTime? startedAt;
  int? _firstSample;
  int samplesWritten = 0;

  bool get isRecording => _sink != null;

  File get _backfillFile => File('${file!.path}.backfill');
  Duration get elapsed =>
      startedAt == null ? Duration.zero : DateTime.now().difference(startedAt!);

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
    _backfillSink = _backfillFile.openWrite();
    startedAt = now;
    _firstSample = null;
    samplesWritten = 0;
  }

  /// Live samples, in order.
  void write(SampleBlock block) => _write(_sink, block);

  /// Samples fetched back from the SD card, in order among themselves.
  void writeRecovered(SampleBlock block) => _write(_backfillSink, block);

  void _write(IOSink? sink, SampleBlock block) {
    if (sink == null || block.length == 0) return;
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
    final sink = _sink, backfillSink = _backfillSink;
    _sink = _backfillSink = null;
    await sink?.close();
    await backfillSink?.close();
    final f = file;
    if (f == null) return null;
    final extra = _backfillFile;
    if (await extra.exists() && await extra.length() > 0) {
      final paths = (f.path, extra.path);
      await Isolate.run(() => mergeCsv(paths.$1, paths.$2));
    }
    if (await extra.exists()) await extra.delete();
    return f;
  }

  static Future<List<Recording>> list() async {
    final files = (await _folder())
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.csv'))
        .toList();
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

/// Merges [extraPath] (data lines only) into the recording at [mainPath]
/// (comment and header lines, then data lines). Both must be sorted by
/// sample number, the first column.
Future<void> mergeCsv(String mainPath, String extraPath) async {
  Stream<String> lines(String p) =>
      File(p).openRead().transform(utf8.decoder).transform(const LineSplitter());
  int number(String line) => int.parse(line.substring(0, line.indexOf(',')));

  final a = StreamIterator(lines(mainPath));
  final b = StreamIterator(lines(extraPath));
  final tmp = File('$mainPath.merging');
  final out = tmp.openWrite();
  var hasA = await a.moveNext(), hasB = await b.moveNext();
  // Copy the header: comment lines and the column names.
  while (hasA && !a.current.startsWith(RegExp(r'[0-9]'))) {
    out.writeln(a.current);
    hasA = await a.moveNext();
  }
  while (hasA || hasB) {
    if (hasB && (!hasA || number(b.current) < number(a.current))) {
      out.writeln(b.current);
      hasB = await b.moveNext();
    } else if (hasB && number(b.current) == number(a.current)) {
      hasB = await b.moveNext(); // arrived both ways: keep the live one
    } else {
      out.writeln(a.current);
      hasA = await a.moveNext();
    }
  }
  await out.close();
  await tmp.rename(mainPath);
}
