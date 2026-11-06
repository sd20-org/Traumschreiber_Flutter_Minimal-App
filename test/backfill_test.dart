import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:traumschreiber_minimal/recording/recorder.dart';
import 'package:traumschreiber_minimal/traumschreiber/backfill.dart';
import 'package:traumschreiber_minimal/traumschreiber/traumschreiber.dart';

SampleBlock samples(Iterable<int> numbers) => SampleBlock(
    numbers.toList(), [for (final n in numbers) List<double>.filled(kChannels, n.toDouble())]);

void main() {
  final t0 = DateTime(2026, 11, 6, 23);
  DateTime at(int seconds) => t0.add(Duration(seconds: seconds));
  const head = 1000000; // live stream far ahead: every gap is old enough

  late List<(int, int)> requests;
  late List<SampleBlock> recovered;
  late Backfill b;

  setUp(() {
    requests = [];
    recovered = [];
    b = Backfill(
        request: (first, last) async => requests.add((first, last)),
        onRecovered: recovered.add);
  });

  test('waits 20 s after connecting, then asks in chunks of 1000', () {
    b.addGap(5000, 7499);
    b.tick(at(10), linkReadySince: t0, head: head);
    expect(requests, isEmpty);
    b.tick(at(21), linkReadySince: t0, head: head);
    expect(requests, [(5000, 5999)]);
    expect(b.pending, 2500);
  });

  test('does not ask for samples younger than a minute', () {
    b.addGap(5000, 5100);
    b.tick(at(30), linkReadySince: t0, head: 5100 + 30 * kSampleRateHz);
    expect(requests, isEmpty);
    b.tick(at(31), linkReadySince: t0, head: 5100 + 61 * kSampleRateHz);
    expect(requests, [(5000, 5100)]);
  });

  test('a complete chunk is handed on sorted and the next one follows', () {
    b.addGap(5000, 6499);
    b.tick(at(21), linkReadySince: t0, head: head);
    b.onEvent(BackfillData(samples([for (var n = 5999; n >= 5000; n--) n])), at(22));
    b.onEvent(BackfillDone(1000), at(22));
    expect(recovered.single.sampleNumbers.first, 5000);
    expect(recovered.single.sampleNumbers.last, 5999);
    expect(b.recovered, 1000);
    b.tick(at(23), linkReadySince: t0, head: head);
    expect(requests.last, (6000, 6499));
  });

  test('asks again only for what is still missing', () {
    b.addGap(5000, 5999);
    b.tick(at(21), linkReadySince: t0, head: head);
    b.onEvent(BackfillData(samples([for (var n = 5000; n < 5600; n++) n])), at(22));
    b.onEvent(BackfillDone(1000), at(22));
    expect(recovered, isEmpty); // not finished yet
    b.tick(at(23), linkReadySince: t0, head: head);
    expect(requests.last, (5600, 5999));
  });

  test('samples not on the SD card count as missing, without retries', () {
    b.addGap(5000, 5999);
    b.tick(at(21), linkReadySince: t0, head: head);
    b.onEvent(BackfillDone(0), at(22));
    expect(b.missing, 1000);
    expect(b.idle, isTrue);
  });

  test('gives up after five unanswered requests', () {
    b.addGap(5000, 5099);
    var t = 21;
    for (var i = 0; i < 5; i++) {
      b.tick(at(t), linkReadySince: t0, head: head); // request
      t += 16;
      b.tick(at(t), linkReadySince: t0, head: head); // 15 s silence
      t += 3;
    }
    expect(requests.length, 5);
    expect(b.missing, 100);
    expect(b.idle, isTrue);
  });

  test('a dropped link does not use up a try', () {
    b.addGap(5000, 5099);
    b.tick(at(21), linkReadySince: t0, head: head);
    b.onLinkLost();
    final t1 = at(100);
    b.tick(t1.add(const Duration(seconds: 21)), linkReadySince: t1, head: head);
    expect(requests.length, 2);
    expect(b.missing, 0);
  });

  test('merges recovered samples into the recording by sample number', () async {
    final dir = await Directory.systemTemp.createTemp('ts_merge');
    final main = File('${dir.path}/r.csv')
      ..writeAsStringSync('# header\nsample_number,time_s\n1,a\n2,a\n5,a\n6,a\n');
    final extra = File('${dir.path}/r.csv.backfill')
      ..writeAsStringSync('3,b\n4,b\n5,b\n7,b\n');
    await mergeCsv(main.path, extra.path);
    expect(main.readAsStringSync(),
        '# header\nsample_number,time_s\n1,a\n2,a\n3,b\n4,b\n5,a\n6,a\n7,b\n');
    await dir.delete(recursive: true);
  });
}
