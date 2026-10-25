import 'dart:async';
import 'dart:typed_data';

import 'radio.dart';

/// Radios that reach each other in memory, for tests without Bluetooth.
///
/// Every pair of radios is in range unless [setInRange] says otherwise, so a
/// test can build a partial mesh (A-B-C where A and C cannot hear each
/// other).
class FakeBleNetwork {
  /// Largest GATT value of every link (iOS gives 512 with a large MTU).
  final int maxValueLength;

  /// Delay of each value on a link.
  final Duration latency;

  final _radios = <FakeBleRadio>[];
  final _outOfRange = <(FakeBleRadio, FakeBleRadio)>{};

  FakeBleNetwork({this.maxValueLength = 512, this.latency = Duration.zero});

  /// A new radio on this network.
  FakeBleRadio newRadio() {
    final r = FakeBleRadio._(this, 'fake-${_radios.length}');
    _radios.add(r);
    return r;
  }

  /// Puts [a] and [b] in or out of range of each other. Out of range, they
  /// do not see each other and cannot connect; open links between them stay.
  void setInRange(FakeBleRadio a, FakeBleRadio b, bool inRange) {
    if (inRange) {
      _outOfRange
        ..remove((a, b))
        ..remove((b, a));
    } else {
      _outOfRange.add((a, b));
    }
    for (final r in [a, b]) {
      r._announceAll();
    }
  }

  bool inRange(FakeBleRadio a, FakeBleRadio b) =>
      a != b && !_outOfRange.contains((a, b)) && !_outOfRange.contains((b, a));

  FakeBleRadio? _advertiser(FakeBleRadio from, String token) {
    for (final r in _radios) {
      if (r._token == token && r._advertising && inRange(from, r)) return r;
    }
    return null;
  }

  void _announce(FakeBleRadio advertiser) {
    for (final r in _radios) {
      if (r._scanning && inRange(r, advertiser)) {
        r._sightings.add(BleSighting(advertiser._token!, rssi: -50));
      }
    }
  }
}

/// A [BleRadio] on a [FakeBleNetwork].
class FakeBleRadio implements BleRadio {
  final FakeBleNetwork _network;
  final String _id;
  String? _token;
  Uint8List? _identity;
  bool _advertising = false;
  bool _scanning = false;
  final _incoming = StreamController<BleLink>.broadcast();
  final _sightings = StreamController<BleSighting>.broadcast();
  final _links = <_FakeLink>{};

  FakeBleRadio._(this._network, this._id);

  /// Number of links that this radio has open, in both roles.
  int get openLinks => _links.length;

  void _announceAll() {
    if (_advertising) _network._announce(this);
    if (_scanning) {
      for (final r in _network._radios) {
        if (r._advertising && _network.inRange(this, r)) _sightings.add(BleSighting(r._token!, rssi: -50));
      }
    }
  }

  @override
  Future<void> startAdvertising(String token, Uint8List identity) async {
    _token = token;
    _identity = identity;
    _advertising = true;
    scheduleMicrotask(() => _network._announce(this));
  }

  @override
  Future<void> stopAdvertising() async => _advertising = false;

  @override
  Stream<BleLink> get incoming => _incoming.stream;

  @override
  Future<void> startScan() async {
    _scanning = true;
    scheduleMicrotask(_announceAll);
  }

  @override
  Future<void> stopScan() async => _scanning = false;

  @override
  Stream<BleSighting> get sightings => _sightings.stream;

  FakeBleRadio _find(String token) =>
      _network._advertiser(this, token) ?? (throw StateError('no device advertising $token in range'));

  @override
  Future<Uint8List> readIdentity(String token, {Duration? timeout}) async {
    await Future<void>.delayed(_network.latency);
    return Uint8List.fromList(_find(token)._identity!);
  }

  @override
  Future<BleLink> connect(String token, {Duration? timeout}) async {
    final remote = _find(token);
    await Future<void>.delayed(_network.latency);
    final central = _FakeLink(this, isCentral: true, remoteId: remote._id);
    final peripheral = _FakeLink(remote, isCentral: false, remoteId: _id);
    central._peer = peripheral;
    peripheral._peer = central;
    _links.add(central);
    remote._links.add(peripheral);
    remote._incoming.add(peripheral);
    return central;
  }

  @override
  Future<void> dispose() async {
    _advertising = false;
    _scanning = false;
    for (final l in _links.toList()) {
      await l.close();
    }
    await _incoming.close();
    await _sightings.close();
  }

  @override
  String toString() => 'FakeBleRadio($_id, token: $_token)';
}

class _FakeLink implements BleLink {
  final FakeBleRadio _radio;
  @override
  final bool isCentral;
  @override
  final String remoteId;
  late _FakeLink _peer;
  final _values = StreamController<Uint8List>();
  final _done = Completer<void>();
  Future<void> _deliveries = Future.value();

  _FakeLink(this._radio, {required this.isCentral, required this.remoteId});

  @override
  int get maxValueLength => _radio._network.maxValueLength;

  @override
  Stream<Uint8List> get values => _values.stream;

  @override
  Future<void> send(Uint8List value) async {
    if (_done.isCompleted) throw StateError('BLE link closed');
    if (value.length > maxValueLength) {
      throw ArgumentError('value of ${value.length} bytes exceeds $maxValueLength');
    }
    final copy = Uint8List.fromList(value);
    final latency = _radio._network.latency;
    // In order, each after the latency.
    _deliveries = _deliveries.then((_) async {
      if (latency > Duration.zero) await Future<void>.delayed(latency);
      if (!_peer._values.isClosed) _peer._values.add(copy);
    });
  }

  @override
  Future<void> close() async {
    _end();
    _peer._end();
  }

  void _end() {
    if (_done.isCompleted) return;
    _done.complete();
    _radio._links.remove(this);
    // Values the other side sent before the end arrive first.
    _peer._deliveries.whenComplete(_values.close);
  }

  @override
  Future<void> get done => _done.future;
}
