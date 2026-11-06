// Everything needed to talk to a Traumschreiber over Bluetooth Low Energy:
// find it, connect, start the EEG stream, decode the packets, disconnect.
//
// The protocol in short (firmware 0.0.90 and later):
//
//   ADS service      0483ddda-…  the EEG stream
//     Data    notify 0483dddb-…  packets of samples, see [decodePacket]
//     Control write  0483dddc-…  0x01 = start streaming, 0x02 = stop
//     Status  read   0483dddd-…  channel list, gain, sample counter
//     Backfill notify 0483ddde-… samples fetched back from the SD card,
//                                see [BackfillEvent]
//   Battery service  0x180F      level 0x2A19, one byte in percent
//   LED/button (LBS) 00001523-…  button …1524: notify, 1 = pressed, 0 = released
//                                RGB LED …1526: write [R, G, B], 0–255
//                                play file …1529: write a path under SOUNDS/
//                                playback state …152B: notify, 0 stopped,
//                                1 playing, 3 error (e.g. file not found)
//
// A sample is 8 channels at 250 Hz, 24 bit each. To convert a raw count to
// microvolts: µV = count × 1.2 V / gain / 2^23 (the ADS131M08's ±1.2 V
// reference). The gain is read from the status characteristic.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';

const int kSampleRateHz = 250;
const int kChannels = 8;

final _adsService = Uuid.parse('0483ddda-6c9d-6ca9-5d41-03ad4fff4abb');
final _adsData = Uuid.parse('0483dddb-6c9d-6ca9-5d41-03ad4fff4abb');
final _adsControl = Uuid.parse('0483dddc-6c9d-6ca9-5d41-03ad4fff4abb');
final _adsStatus = Uuid.parse('0483dddd-6c9d-6ca9-5d41-03ad4fff4abb');
final _adsBackfill = Uuid.parse('0483ddde-6c9d-6ca9-5d41-03ad4fff4abb');
final _batteryService = Uuid.parse('180f');
final _batteryLevel = Uuid.parse('2a19');
final _lbsService = Uuid.parse('00001523-1212-efde-1523-785feabcd123');
final _lbsButton = Uuid.parse('00001524-1212-efde-1523-785feabcd123');
final _lbsRgbLed = Uuid.parse('00001526-1212-efde-1523-785feabcd123');
final _lbsPlayFile = Uuid.parse('00001529-1212-efde-1523-785feabcd123');
final _lbsPlaybackState = Uuid.parse('0000152b-1212-efde-1523-785feabcd123');

/// The sound a Traumschreiber TS2607 plays when switched on (production SD
/// cards hold only this file). Early development cards use BELL2.WAV.
const String kStartSound = 'SOUNDS/TSBOOT.WAV';
const String _kOldStartSound = 'SOUNDS/BELL2.WAV';

const int _cmdStart = 0x01;
const int _cmdStop = 0x02;
const int _cmdBackfill = 0x20;

/// A batch of consecutive samples as they arrive from one or more packets.
class SampleBlock {
  /// Running sample counter of the device (one per sample, never resets
  /// while the device is on). A jump means samples were lost on the way.
  final List<int> sampleNumbers;

  /// `microvolts[i][ch]`: sample i, channel ch (0–7).
  final List<List<double>> microvolts;

  const SampleBlock(this.sampleNumbers, this.microvolts);
  int get length => sampleNumbers.length;
}

/// What the status characteristic tells us after connecting.
class DeviceStatus {
  final List<int> channels; // which of the 8 inputs are streamed, in order
  final List<int> gains; // amplifier gain per input (1…128)
  final int sampleCounter; // device sample counter at the time of reading

  const DeviceStatus(this.channels, this.gains, this.sampleCounter);

  static const fallback =
      DeviceStatus([0, 1, 2, 3, 4, 5, 6, 7], [4, 4, 4, 4, 4, 4, 4, 4], 0);

  /// Layout (little endian): [0] streaming, [1..12] counters, [13] mask,
  /// [14] n = channel count, [15..15+n) channel indices, compress bits (1),
  /// delta max (4), sample counter (4), SD state (4), gain (1),
  /// bytes per value (1), gain per channel (8, firmware 0.0.91+).
  static DeviceStatus parse(List<int> raw) {
    if (raw.length < 16) return fallback;
    final bd = ByteData.sublistView(Uint8List.fromList(raw));
    final n = raw[14].clamp(1, kChannels);
    final channels = raw.sublist(15, 15 + n);
    var p = 15 + n + 1 + 4; // skip compress bits and delta max
    final counter = p + 4 <= raw.length ? bd.getUint32(p, Endian.little) : 0;
    p += 4 + 4; // sample counter, SD state
    const valid = {1, 2, 4, 8, 16, 32, 64, 128};
    var gains = List<int>.filled(kChannels, 4);
    if (p < raw.length && valid.contains(raw[p])) {
      gains = List<int>.filled(kChannels, raw[p]);
    }
    final perChannel = p + 2;
    if (perChannel + kChannels <= raw.length) {
      final g = raw.sublist(perChannel, perChannel + kChannels);
      if (g.every(valid.contains)) gains = g;
    }
    return DeviceStatus(channels, gains, counter);
  }
}

/// Decodes one notification of the Data characteristic (header 0xC0) or one
/// data notification of the Backfill characteristic (header 0xBF).
///
/// Layout: header byte, then any number of samples of
/// `4 + 8 + 3·n + 4` bytes each (n = streamed channels):
///   sample number   uint32
///   device time     uint64, microseconds
///   n × value       int24, two's complement
///   status word     uint32
/// A lone 0xC0 byte is a keep-alive and carries no samples.
SampleBlock decodePacket(List<int> packet, DeviceStatus status,
    {int header = 0xC0}) {
  final bytes = Uint8List.fromList(packet);
  if (bytes.isEmpty || bytes[0] != header) return const SampleBlock([], []);
  final n = status.channels.length;
  final size = 4 + 8 + 3 * n + 4;
  final bd = ByteData.sublistView(bytes);
  final numbers = <int>[];
  final values = <List<double>>[];
  for (var off = 1; off + size <= bytes.length; off += size) {
    numbers.add(bd.getUint32(off, Endian.little));
    final uv = List<double>.filled(kChannels, 0);
    for (var i = 0; i < n; i++) {
      final o = off + 12 + 3 * i;
      var v = bytes[o] | bytes[o + 1] << 8 | bytes[o + 2] << 16;
      if (v & 0x800000 != 0) v -= 0x1000000; // sign of a 24-bit value
      final ch = status.channels[i];
      uv[ch] = v * 1.2e6 / status.gains[ch] / 8388608;
    }
    values.add(uv);
  }
  return SampleBlock(numbers, values);
}

/// What the Backfill characteristic reports after a request with
/// [Traumschreiber.requestBackfill]:
///   0xBF  samples, same layout as a live packet  → [BackfillData]
///   0xBE  done; bytes 9–12: how many samples the
///         device found on its SD card           → [BackfillDone]
///   0xBD  cancelled or SD error                  → [BackfillFailed]
sealed class BackfillEvent {}

class BackfillData extends BackfillEvent {
  final SampleBlock block;
  BackfillData(this.block);
}

class BackfillDone extends BackfillEvent {
  /// -1 on firmware older than 0.0.68, which does not report it.
  final int delivered;
  BackfillDone(this.delivered);
}

class BackfillFailed extends BackfillEvent {}

BackfillEvent? decodeBackfill(List<int> packet, DeviceStatus status) {
  if (packet.isEmpty) return null;
  switch (packet[0]) {
    case 0xBF:
      return BackfillData(decodePacket(packet, status, header: 0xBF));
    case 0xBE:
      final delivered = packet.length >= 13
          ? ByteData.sublistView(Uint8List.fromList(packet))
              .getUint32(9, Endian.little)
          : -1;
      return BackfillDone(delivered);
    case 0xBD:
      return BackfillFailed();
  }
  return null; // other headers on this characteristic are for other features
}

/// [reconnecting]: the link dropped without the user asking for it; the app
/// keeps trying until the device is back or the user taps Disconnect.
enum ConnectionPhase { disconnected, scanning, connecting, connected, reconnecting }

class Traumschreiber extends ChangeNotifier {
  final _ble = FlutterReactiveBle();
  final _samples = StreamController<SampleBlock>.broadcast();
  final _backfill = StreamController<BackfillEvent>.broadcast();
  final _subs = <StreamSubscription>[];
  StreamSubscription? _connection;

  ConnectionPhase phase = ConnectionPhase.disconnected;
  String? deviceName;
  String? error;
  int? batteryPercent;
  DeviceStatus status = DeviceStatus.fallback;
  String? _deviceId;

  /// When the current connection was set up; null while not connected.
  DateTime? connectedSince;
  int reconnects = 0;

  /// When the button on the device was pressed, by the phone's clock,
  /// newest last.
  final List<DateTime> buttonPresses = [];

  /// Last playback state the device reported: 0 stopped, 1 playing,
  /// 3 error. null = nothing played yet.
  int? playbackState;
  String? _lastSound;

  /// Decoded samples while connected (the stream starts right after
  /// connecting).
  Stream<SampleBlock> get samples => _samples.stream;

  /// Answers to [requestBackfill].
  Stream<BackfillEvent> get backfill => _backfill.stream;
  bool get isConnected => phase == ConnectionPhase.connected;

  /// Connected or trying to get back: the user has not disconnected.
  bool get isActive =>
      phase == ConnectionPhase.connected || phase == ConnectionPhase.reconnecting;

  void _set(ConnectionPhase p, {String? err}) {
    phase = p;
    error = err;
    notifyListeners();
  }

  Future<void> connect() async {
    if (phase != ConnectionPhase.disconnected) return;
    try {
      await _requestPermissions();
      _set(ConnectionPhase.scanning);
      final device = await _scan();
      deviceName = device.name;
      _deviceId = device.id;
      _set(ConnectionPhase.connecting);
      await _connect(device.id);
      await _setUp(device.id);
      reconnects = 0;
      connectedSince = DateTime.now();
      _set(ConnectionPhase.connected);
    } catch (e) {
      await _tearDown();
      _deviceId = null;
      _set(ConnectionPhase.disconnected, err: '$e');
    }
  }

  Future<void> disconnect() async {
    final id = _deviceId;
    final wasConnected = isConnected;
    _set(ConnectionPhase.disconnected); // also ends a running reconnect loop
    if (id != null && wasConnected) {
      try {
        await _ble.writeCharacteristicWithResponse(_control(id),
            value: [_cmdStop]);
      } catch (_) {} // the device stops on its own when the link drops
    }
    await _tearDown();
    _deviceId = null;
  }

  /// The link dropped: out of range, the phone's Bluetooth was switched off
  /// and on, the device was switched off. Wait until the device shows up in
  /// a scan, then connect; repeat until it works or the user taps
  /// Disconnect. Lessons from the sd20 app:
  ///   * Connecting blindly by address fails after Android's Bluetooth
  ///     restarted: it forgets the device's address type. A scan sighting
  ///     tells it again.
  ///   * With the screen off, Android only runs scans with a filter. The
  ///     device advertises the LED/button service UUID, so filter on that.
  ///   * Keep one scan open for the whole outage: every new scan leaves a
  ///     thread behind in the Bluetooth plugin.
  ///   * Give a connection attempt more than Android's own 30 s.
  Future<void> _reconnect() async {
    final id = _deviceId;
    if (id == null) return;
    await _tearDown();
    connectedSince = null;
    _set(ConnectionPhase.reconnecting, err: 'Connection lost, reconnecting…');

    var seen = false;
    StreamSubscription? scan;
    void startScan() {
      scan = _ble
          .scanForDevices(withServices: [_lbsService], scanMode: ScanMode.lowLatency)
          .listen((d) => seen |= d.id == id, onError: (_) => scan = null);
    }

    startScan();
    var lastAttempt = DateTime(0);
    while (phase == ConnectionPhase.reconnecting) {
      await Future.delayed(const Duration(seconds: 1));
      if (scan == null && DateTime.now().difference(lastAttempt).inSeconds > 30) {
        startScan(); // the scan failed (e.g. Bluetooth was off): open it again
        lastAttempt = DateTime.now();
      }
      if (!seen) continue;
      seen = false;
      try {
        await _connect(id, timeout: const Duration(seconds: 35));
        await _setUp(id);
        if (phase != ConnectionPhase.reconnecting) {
          await _tearDown(); // the user tapped Disconnect meanwhile
          break;
        }
        reconnects++;
        connectedSince = DateTime.now();
        _set(ConnectionPhase.connected);
        break;
      } catch (_) {
        await _tearDown();
      }
    }
    await scan?.cancel();
  }

  /// Android 12+ asks for "Nearby devices". Android 11 and older need the
  /// location permission to scan instead; [_scan] asks for it only if the
  /// scan fails for lack of it.
  Future<void> _requestPermissions() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    final result =
        await [Permission.bluetoothScan, Permission.bluetoothConnect].request();
    if (result[Permission.bluetoothConnect]?.isPermanentlyDenied ?? false) {
      throw 'Bluetooth permission denied. Allow it in the system settings.';
    }
  }

  /// Current firmware advertises the name "Traumschreiber", early devices
  /// "TS25…". The first one found is used; switch off the others if several
  /// are around.
  Future<DiscoveredDevice> _scan({bool retried = false}) async {
    try {
      return await _scanOnce();
    } catch (e) {
      final lacksLocation = '$e'.toLowerCase().contains('location');
      if (retried || !lacksLocation) rethrow;
      await Permission.locationWhenInUse.request();
      return _scan(retried: true);
    }
  }

  Future<DiscoveredDevice> _scanOnce() async {
    final found = Completer<DiscoveredDevice>();
    final sub = _ble.scanForDevices(withServices: []).listen((d) {
      final name = d.name.toLowerCase();
      final isTs = name.contains('traumschreiber') || name.startsWith('ts25');
      if (isTs && !found.isCompleted) found.complete(d);
    }, onError: (e) {
      if (!found.isCompleted) found.completeError(e);
    });
    try {
      return await found.future.timeout(const Duration(seconds: 15),
          onTimeout: () => throw 'No Traumschreiber found. Is it switched on?');
    } finally {
      await sub.cancel();
    }
  }

  Future<void> _connect(String id,
      {Duration timeout = const Duration(seconds: 10)}) async {
    final connected = Completer<void>();
    _connection = _ble
        .connectToDevice(id: id, connectionTimeout: timeout)
        .listen((u) {
      if (u.connectionState == DeviceConnectionState.connected &&
          !connected.isCompleted) {
        connected.complete();
      } else if (u.connectionState == DeviceConnectionState.disconnected) {
        if (!connected.isCompleted) {
          connected.completeError('Connection failed');
        } else if (phase == ConnectionPhase.connected) {
          _reconnect();
        }
      }
    }, onError: (e) {
      if (!connected.isCompleted) connected.completeError(e);
    });
    await connected.future.timeout(timeout + const Duration(seconds: 5));
  }

  Future<void> _setUp(String id) async {
    // One packet holds ten samples (401 bytes), so ask for a large MTU.
    await _ble.requestMtu(deviceId: id, mtu: 512);
    status = DeviceStatus.parse(await _ble.readCharacteristic(
        QualifiedCharacteristic(
            serviceId: _adsService, characteristicId: _adsStatus, deviceId: id)));

    final battery = QualifiedCharacteristic(
        serviceId: _batteryService, characteristicId: _batteryLevel, deviceId: id);
    void onBattery(List<int> v) {
      if (v.isNotEmpty) {
        batteryPercent = v[0];
        notifyListeners();
      }
    }
    onBattery(await _ble.readCharacteristic(battery));
    _subs.add(_ble.subscribeToCharacteristic(battery).listen(onBattery));

    _subs.add(_ble
        .subscribeToCharacteristic(QualifiedCharacteristic(
            serviceId: _lbsService, characteristicId: _lbsButton, deviceId: id))
        .listen((v) {
      if (v.isNotEmpty && v[0] == 1) {
        buttonPresses.add(DateTime.now());
        notifyListeners();
      }
    }));

    _subs.add(_ble
        .subscribeToCharacteristic(QualifiedCharacteristic(
            serviceId: _lbsService, characteristicId: _lbsPlaybackState, deviceId: id))
        .listen((v) {
      if (v.isNotEmpty) {
        playbackState = v[0];
        // Not on the card? Try the start sound of older cards once.
        if (v[0] == 3 && _lastSound == kStartSound) playSound(_kOldStartSound);
        notifyListeners();
      }
    }));

    // Samples lost on the way can be fetched back from the SD card later.
    // Firmware before 0.0.59 has no Backfill characteristic; then the
    // subscription fails and nothing is fetched back.
    _subs.add(_ble
        .subscribeToCharacteristic(QualifiedCharacteristic(
            serviceId: _adsService, characteristicId: _adsBackfill, deviceId: id))
        .listen((packet) {
      final event = decodeBackfill(packet, status);
      if (event != null) _backfill.add(event);
    }, onError: (_) {}));

    // After a dropped connection the firmware may resend an old, unsent
    // batch once. Anything older than the counter we just read is stale.
    final oldest = status.sampleCounter - 10 * kSampleRateHz;
    _subs.add(_ble
        .subscribeToCharacteristic(QualifiedCharacteristic(
            serviceId: _adsService, characteristicId: _adsData, deviceId: id))
        .listen((packet) {
      final block = decodePacket(packet, status);
      if (block.length > 0 && block.sampleNumbers.first >= oldest) {
        _samples.add(block);
      }
    }));

    await _ble.requestConnectionPriority(
        deviceId: id, priority: ConnectionPriority.highPerformance);
    // Give the subscription a moment before the device starts sending.
    await Future.delayed(const Duration(milliseconds: 500));
    await _ble.writeCharacteristicWithResponse(_control(id), value: [_cmdStart]);
  }

  /// Asks the device for samples [first]…[last] (inclusive) from its SD
  /// card. They arrive on [backfill], followed by [BackfillDone]. Only works
  /// with a microSD card in the device; ask for at most a few thousand
  /// samples at a time, the live stream shares the link.
  Future<void> requestBackfill(int first, int last) async {
    final id = _deviceId;
    if (id == null || !isConnected) throw 'not connected';
    final cmd = ByteData(9)
      ..setUint8(0, _cmdBackfill)
      ..setUint32(1, first, Endian.little)
      ..setUint32(5, last, Endian.little);
    await _ble.writeCharacteristicWithResponse(_control(id),
        value: cmd.buffer.asUint8List());
  }

  /// Sets the LED colour, each component 0–255. (0, 0, 0) switches it off.
  Future<void> setLed(int r, int g, int b) => _write(_lbsService, _lbsRgbLed,
      [r.clamp(0, 255), g.clamp(0, 255), b.clamp(0, 255)]);

  /// Plays a WAV file from the SD card's SOUNDS folder on the device speaker.
  /// Sent without waiting for an answer: the firmware opens the file while
  /// handling the write, and a write with response can stall on that.
  Future<void> playSound([String path = kStartSound]) {
    _lastSound = path;
    playbackState = null;
    notifyListeners();
    return _write(_lbsService, _lbsPlayFile, utf8.encode(path), withResponse: false);
  }

  Future<void> _write(Uuid service, Uuid characteristic, List<int> value,
      {bool withResponse = true}) async {
    final id = _deviceId;
    if (id == null || !isConnected) return;
    final c = QualifiedCharacteristic(
        serviceId: service, characteristicId: characteristic, deviceId: id);
    withResponse
        ? await _ble.writeCharacteristicWithResponse(c, value: value)
        : await _ble.writeCharacteristicWithoutResponse(c, value: value);
  }

  QualifiedCharacteristic _control(String id) => QualifiedCharacteristic(
      serviceId: _adsService, characteristicId: _adsControl, deviceId: id);

  Future<void> _tearDown() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await _connection?.cancel(); // cancelling the connection stream disconnects
    _connection = null;
    batteryPercent = null;
  }

  @override
  void dispose() {
    _tearDown();
    _samples.close();
    _backfill.close();
    super.dispose();
  }
}
