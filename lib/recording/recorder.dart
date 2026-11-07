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
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

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
/// sample number, the first column. Lines are compared and copied as bytes,
/// in large blocks: a night has millions of lines, and decoding each one to
/// a string took a quarter of an hour on a slow phone.
Future<void> mergeCsv(String mainPath, String extraPath) async {
  final a = _LineReader(mainPath), b = _LineReader(extraPath);
  final tmp = File('$mainPath.merging');
  final out = _BlockWriter(tmp.openSync(mode: FileMode.write));
  var lineA = a.next(), lineB = b.next();
  // Copy the header: comment lines and the column names.
  while (lineA != null && _number(lineA) == null && !_isDigit(lineA)) {
    out.add(lineA);
    lineA = a.next();
  }
  while (lineA != null || lineB != null) {
    final na = lineA == null ? null : _number(lineA);
    final nb = lineB == null ? null : _number(lineB);
    if (lineA != null && na == null) {
      lineA = a.next(); // half a line from a recording that was cut off
    } else if (lineB != null && nb == null) {
      lineB = b.next();
    } else if (nb != null && (na == null || nb < na)) {
      out.add(lineB!);
      lineB = b.next();
    } else if (nb != null && nb == na) {
      lineB = b.next(); // arrived both ways: keep the live one
    } else {
      out.add(lineA!);
      lineA = a.next();
    }
  }
  out.close();
  a.close();
  b.close();
  tmp.renameSync(mainPath);
}

bool _isDigit(List<int> line) => line.isNotEmpty && line[0] >= 48 && line[0] <= 57;

/// Sample number at the start of a data line, null if the line has none.
int? _number(Uint8List line) {
  var n = 0, i = 0;
  while (i < line.length && line[i] >= 48 && line[i] <= 57) {
    n = n * 10 + line[i] - 48;
    i++;
  }
  return i > 0 && i < line.length && line[i] == 44 ? n : null; // 44 = ','
}

/// Reads a file line by line (without the newline), one large block at a
/// time.
class _LineReader {
  final RandomAccessFile _file;
  Uint8List _buf = Uint8List(0);
  int _pos = 0;
  bool _eof = false;
  _LineReader(String path) : _file = File(path).openSync();

  Uint8List? next() {
    while (true) {
      final nl = _buf.indexOf(10, _pos);
      if (nl >= 0) {
        final line = Uint8List.sublistView(_buf, _pos, nl);
        _pos = nl + 1;
        return line;
      }
      if (_eof) {
        if (_pos >= _buf.length) return null;
        final line = Uint8List.sublistView(_buf, _pos);
        _pos = _buf.length;
        return line;
      }
      final block = _file.readSync(1 << 20);
      if (block.isEmpty) _eof = true;
      final rest = _buf.length - _pos;
      _buf = Uint8List(rest + block.length)
        ..setRange(0, rest, _buf, _pos)
        ..setRange(rest, rest + block.length, block);
      _pos = 0;
    }
  }

  void close() => _file.closeSync();
}

class _BlockWriter {
  final RandomAccessFile _file;
  final _buf = BytesBuilder(copy: true);
  _BlockWriter(this._file);

  void add(Uint8List line) {
    _buf
      ..add(line)
      ..addByte(10);
    if (_buf.length >= 1 << 20) _file.writeFromSync(_buf.takeBytes());
  }

  void close() {
    _file.writeFromSync(_buf.takeBytes());
    _file.closeSync();
  }
}
