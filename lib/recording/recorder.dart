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
  final Duration duration;
  const Recording(this.file, this.modified, this.bytes, this.duration);

  String get name => file.uri.pathSegments.last;

  /// time_s of the last complete line: seconds since the first sample.
  static Duration readDuration(File f) {
    try {
      final raf = f.openSync();
      final len = raf.lengthSync();
      raf.setPositionSync(len > 400 ? len - 400 : 0);
      final tail = String.fromCharCodes(raf.readSync(400));
      raf.closeSync();
      final lines = tail.split('\n').where((l) => l.split(',').length > 2).toList();
      final seconds = double.tryParse(lines.isEmpty ? '' : lines.last.split(',')[1]);
      return Duration(milliseconds: ((seconds ?? 0) * 1000).round());
    } catch (_) {
      return Duration.zero;
    }
  }
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

  /// A recording that ended without [stop] (the app was ended mid-way)
  /// leaves its …csv.backfill next to it. Sort those samples in now.
  static Future<void> mergeLeftovers() async {
    final folder = await _folder();
    for (final extra in folder.listSync().whereType<File>()) {
      if (!extra.path.endsWith('.csv.backfill')) continue;
      final main = File(extra.path.substring(0, extra.path.length - 9));
      try {
        if (await main.exists() && await extra.length() > 0) {
          final paths = (main.path, extra.path);
          await Isolate.run(() => mergeCsv(paths.$1, paths.$2));
        }
        await extra.delete();
      } catch (_) {} // could not read it: leave both files as they are
    }
  }

  static Future<List<Recording>> list() async {
    final files = (await _folder())
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.csv'))
        .toList();
    final list = [
      for (final f in files) Recording(f, f.lastModifiedSync(), f.lengthSync(), Recording.readDuration(f))
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
  // A recording cut off mid-write can end in half a line: skip such lines.
  int? number(String line) {
    final comma = line.indexOf(',');
    return comma < 0 ? null : int.tryParse(line.substring(0, comma));
  }

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
    if (hasA && number(a.current) == null) {
      hasA = await a.moveNext();
    } else if (hasB && number(b.current) == null) {
      hasB = await b.moveNext();
    } else if (hasB && (!hasA || number(b.current)! < number(a.current)!)) {
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
