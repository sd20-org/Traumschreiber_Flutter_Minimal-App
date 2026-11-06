// Fetches samples that never arrived over Bluetooth back from the device's
// microSD card, so a recording has no holes even if the link drops for
// minutes or hours.
//
// The device writes every sample to its SD card, numbered with the same
// counter as the live stream. When the live stream jumps from sample n to
// sample m, samples n+1 … m-1 are a gap. This class keeps the list of gaps
// and asks the device for them, one chunk at a time, while the live stream
// keeps running:
//
//   request [first, last]  →  0xBF data packets …  →  0xBE done
//
// The rules below come from the sd20 app, which learned them the hard way:
//   * at most 1000 samples (4 s) per request: bigger bursts crowd out the
//     live stream on the shared link and create new gaps;
//   * a short pause after each chunk, longer after bigger ones;
//   * nothing in the first 20 s after (re)connecting: some firmware
//     versions fall silent when asked right away;
//   * only gaps at least 60 s old: the device writes to the card in blocks,
//     so the newest samples are not on the card yet;
//   * a chunk that does not come back completely is asked for again, up to
//     5 times; samples the device reports as not on its card (no card, or
//     dropped before they were written) are counted as missing for good.
//
// Gaps are fetched oldest first and each chunk is handed on only when
// it is finished, in order, so the recovered samples come out sorted.
import 'dart:collection';

import 'traumschreiber.dart';

class Backfill {
  static const int chunkSize = 1000;
  static const Duration afterConnect = Duration(seconds: 20);
  static const int minAgeSamples = 60 * kSampleRateHz;
  static const Duration silenceTimeout = Duration(seconds: 15);
  static const int maxTries = 5;

  /// Sends a request for samples first…last (inclusive) to the device.
  final Future<void> Function(int first, int last) request;

  /// Receives each finished chunk, sorted, oldest chunk first.
  final void Function(SampleBlock block) onRecovered;

  Backfill({required this.request, required this.onRecovered});

  final _gaps = <List<int>>[]; // [first, last], oldest first

  // The chunk being fetched: requested range, samples received so far.
  List<int>? _chunk;
  final _received = SplayTreeMap<int, List<double>>();
  int _tries = 0;
  bool _waitingForAnswer = false;
  DateTime _lastActivity = DateTime(0);
  DateTime _nextRequest = DateTime(0);

  /// Samples fetched back from the SD card.
  int recovered = 0;

  /// Samples given up on: not on the card, or no answer after [maxTries].
  int missing = 0;

  /// Samples still to fetch.
  int get pending =>
      _gaps.fold(0, (sum, g) => sum + g[1] - g[0] + 1) - _received.length;

  bool get idle => _gaps.isEmpty;

  void addGap(int first, int last) {
    if (last < first) return;
    if (_gaps.isNotEmpty && _gaps.last[1] + 1 >= first) {
      _gaps.last[1] = last; // touches the previous gap: extend it
    } else {
      _gaps.add([first, last]);
    }
  }

  /// Forget all gaps, e.g. when the device restarted and its sample
  /// counter began again at zero.
  void clear() {
    _gaps.clear();
    _received.clear();
    _chunk = null;
    _waitingForAnswer = false;
  }

  /// The link dropped: the answer to the current request will not come.
  /// It is asked for again after reconnecting, without counting a try.
  void onLinkLost() => _waitingForAnswer = false;

  /// Call about once per second. [linkReadySince]: when the current
  /// connection was set up, null while disconnected. [head]: newest sample
  /// number of the live stream.
  void tick(DateTime now, {DateTime? linkReadySince, int? head}) {
    if (_waitingForAnswer) {
      if (now.difference(_lastActivity) > silenceTimeout) _chunkFailed(now);
      return;
    }
    if (_gaps.isEmpty || linkReadySince == null || head == null) return;
    if (now.difference(linkReadySince) < afterConnect) return;
    if (now.isBefore(_nextRequest)) return;

    final gap = _gaps.first;
    final chunk = _chunk ??= [gap[0], _min(gap[1], gap[0] + chunkSize - 1)];
    if (chunk[1] > head - minAgeSamples) return; // not on the card yet

    // Ask only for what is still missing in this chunk.
    var first = chunk[0], last = chunk[1];
    while (first <= last && _received.containsKey(first)) {
      first++;
    }
    while (last >= first && _received.containsKey(last)) {
      last--;
    }
    _waitingForAnswer = true;
    _lastActivity = now;
    request(first, last).catchError((_) => _chunkFailed(DateTime.now()));
  }

  void onEvent(BackfillEvent event, DateTime now) {
    final chunk = _chunk;
    if (chunk == null || !_waitingForAnswer) return;
    _lastActivity = now;
    switch (event) {
      case BackfillData(:final block):
        for (var i = 0; i < block.length; i++) {
          final n = block.sampleNumbers[i];
          if (n >= chunk[0] && n <= chunk[1]) _received[n] = block.microvolts[i];
        }
      case BackfillDone(:final delivered):
        _waitingForAnswer = false;
        final size = chunk[1] - chunk[0] + 1;
        if (_received.length == size) {
          _finishChunk(now);
        } else if (delivered == 0 && _received.isEmpty) {
          _finishChunk(now); // not on the card: retrying cannot help
        } else if (++_tries >= maxTries) {
          _finishChunk(now);
        } else {
          _nextRequest = now.add(const Duration(milliseconds: 300));
        }
      case BackfillFailed():
        _chunkFailed(now);
    }
  }

  void _chunkFailed(DateTime now) {
    _waitingForAnswer = false;
    if (_chunk == null) return;
    if (++_tries >= maxTries) {
      _finishChunk(now);
    } else {
      _nextRequest = now.add(const Duration(seconds: 2));
    }
  }

  /// Hands on what arrived, counts the rest as missing, moves to the next.
  void _finishChunk(DateTime now) {
    final chunk = _chunk!;
    final size = chunk[1] - chunk[0] + 1;
    if (_received.isNotEmpty) {
      onRecovered(SampleBlock(_received.keys.toList(), _received.values.toList()));
    }
    recovered += _received.length;
    missing += size - _received.length;

    final gap = _gaps.first;
    gap[0] = chunk[1] + 1;
    if (gap[0] > gap[1]) _gaps.removeAt(0);
    _chunk = null;
    _received.clear();
    _tries = 0;
    // Let the live stream catch up: about 0.1 s plus 1 ms per 8 samples.
    _nextRequest = now.add(Duration(milliseconds: 120 + size ~/ 8));
  }

  static int _min(int a, int b) => a < b ? a : b;
}
