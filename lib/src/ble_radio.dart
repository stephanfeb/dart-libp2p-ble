import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math';
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:logging/logging.dart';

import 'protocol.dart' as p;
import 'radio.dart';

final _log = Logger('BluetoothLowEnergyRadio');

final _serviceUuid = UUID.fromString(p.serviceUuid);
final _rxUuid = UUID.fromString(p.rxCharacteristicUuid);
final _txUuid = UUID.fromString(p.txCharacteristicUuid);
final _identityUuid = UUID.fromString(p.identityCharacteristicUuid);

/// [BleRadio] on the bluetooth_low_energy plugin (iOS, macOS, Android).
///
/// What the device tests showed (dart-libp2p-zc4.1):
/// - An Android peripheral that a central connects to keeps advertising: the
///   stack re-enables the advertising set. Stopping and starting it again
///   breaks it (the plugin's start then never answers), so this radio never
///   restarts advertising because of a connection.
/// - A device can come back with a new address after a connection, so iOS
///   gives it a new peripheral ID. Devices are found by token; a stale
///   peripheral is dropped and the token is scanned for again.
class BluetoothLowEnergyRadio implements BleRadio {
  final CentralManager _central;
  final PeripheralManager _peripheral;

  /// How long a GATT connection that [readIdentity] opened stays open for a
  /// [connect] to reuse.
  final Duration sessionReuse;

  final _incoming = StreamController<BleLink>.broadcast();
  final _sightings = StreamController<BleSighting>.broadcast();
  final _subs = <StreamSubscription>[];

  // Central role.
  final _seen = <String, Peripheral>{};
  final _sessions = <String, _GattSession>{}; // by peripheral UUID
  bool _scanning = false;

  // Peripheral role.
  GATTCharacteristic? _tx;
  final _peripheralLinks = <String, _PeripheralLink>{}; // by central UUID
  bool _advertising = false;
  bool _listening = false;

  BluetoothLowEnergyRadio({
    CentralManager? central,
    PeripheralManager? peripheral,
    this.sessionReuse = const Duration(seconds: 10),
  })  : _central = central ?? CentralManager(),
        _peripheral = peripheral ?? PeripheralManager() {
    _subs
      ..add(_central.discovered.listen(_onDiscovered))
      ..add(_central.connectionStateChanged.listen((e) {
        if (e.state == ConnectionState.disconnected) _sessions[e.peripheral.uuid.toString()]?._end();
      }))
      ..add(_central.characteristicNotified.listen((e) {
        if (e.characteristic.uuid != _txUuid) return;
        _sessions[e.peripheral.uuid.toString()]?._link?._values.add(e.value);
      }));
  }

  // -- Scanning --------------------------------------------------------------

  void _onDiscovered(DiscoveredEventArgs e) {
    final token = _tokenOf(e.advertisement);
    if (token == null) return;
    _seen[token] = e.peripheral;
    _sightings.add(BleSighting(token, rssi: e.rssi));
  }

  static String? _tokenOf(Advertisement a) {
    final byName = p.tokenFromAdvertisedName(a.name);
    if (byName != null) return byName;
    for (final m in a.manufacturerSpecificData) {
      final t = p.tokenFromManufacturerData(m.id, m.data);
      if (t != null) return t;
    }
    return null;
  }

  @override
  Stream<BleSighting> get sightings => _sightings.stream;

  @override
  Future<void> startScan() async {
    await _poweredOn(_central);
    await _central.startDiscovery(serviceUUIDs: [_serviceUuid]);
    _scanning = true;
  }

  @override
  Future<void> stopScan() async {
    _scanning = false;
    await _central.stopDiscovery();
  }

  /// Scans until [token] is seen. Leaves the scan as it was.
  Future<Peripheral> _scanFor(String token, Duration timeout) async {
    final found = _central.discovered
        .where((e) => _tokenOf(e.advertisement) == token)
        .map((e) => e.peripheral)
        .first
        .timeout(timeout, onTimeout: () => throw TimeoutException('no device advertising $token'));
    final wasScanning = _scanning;
    if (!wasScanning) await _central.startDiscovery(serviceUUIDs: [_serviceUuid]);
    try {
      return await found;
    } finally {
      if (!wasScanning) await _central.stopDiscovery();
    }
  }

  // -- Central role ----------------------------------------------------------

  Future<_GattSession> _session(String token, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    Duration left() {
      final d = deadline.difference(DateTime.now());
      return d.isNegative ? Duration.zero : d;
    }

    await _poweredOn(_central);
    final cached = _seen[token];
    if (cached != null) {
      final open = _sessions[cached.uuid.toString()];
      if (open != null && !open._ended) return open;
    }
    // A peripheral seen before can be stale (the device advertises from a
    // new address): try it for a short time, then scan for a fresh one.
    if (cached != null) {
      try {
        return await _openSession(token, cached, Duration(milliseconds: min(4000, left().inMilliseconds)));
      } catch (e) {
        _log.fine('$token: cached peripheral failed ($e); scanning again');
        _seen.remove(token);
      }
    }
    final fresh = await _scanFor(token, left());
    return _openSession(token, fresh, left());
  }

  Future<_GattSession> _openSession(String token, Peripheral peripheral, Duration timeout) async {
    final watch = Stopwatch()..start();
    final key = peripheral.uuid.toString();
    final session = _GattSession(this, token, peripheral);
    _sessions[key] = session;
    try {
      await _central.connect(peripheral).timeout(timeout);
      final services = await _central.discoverGATT(peripheral).timeout(timeout);
      final service = services.firstWhere((s) => s.uuid == _serviceUuid,
          orElse: () => throw StateError('$token has no libp2p BLE service'));
      GATTCharacteristic char(UUID uuid) => service.characteristics
          .firstWhere((c) => c.uuid == uuid, orElse: () => throw StateError('$token: no characteristic $uuid'));
      session
        .._rx = char(_rxUuid)
        .._tx = char(_txUuid)
        .._identity = char(_identityUuid);
      if (Platform.isAndroid) await _central.requestMTU(peripheral, mtu: 517);
      session._maxWrite = min(512,
          await _central.getMaximumWriteLength(peripheral, type: GATTCharacteristicWriteType.withResponse));
      _log.fine('$token: GATT ready in ${watch.elapsedMilliseconds} ms, write length ${session._maxWrite}');
      session._scheduleIdleClose();
      return session;
    } catch (e) {
      session._end();
      try {
        await _central.disconnect(peripheral);
      } catch (_) {}
      rethrow;
    }
  }

  @override
  Future<Uint8List> readIdentity(String token, {Duration? timeout}) async {
    final t = timeout ?? const Duration(seconds: 20);
    final session = await _session(token, t);
    final value = await _central.readCharacteristic(session._peripheral, session._identity).timeout(t);
    session._scheduleIdleClose();
    return value;
  }

  @override
  Future<BleLink> connect(String token, {Duration? timeout}) async {
    final t = timeout ?? const Duration(seconds: 30);
    final session = await _session(token, t);
    if (session._link != null) throw StateError('$token already has a link');
    session._idleTimer?.cancel();
    final link = _CentralLink(this, session);
    session._link = link;
    try {
      await _central.setCharacteristicNotifyState(session._peripheral, session._tx, state: true).timeout(t);
    } catch (e) {
      await link.close();
      rethrow;
    }
    return link;
  }

  // -- Peripheral role -------------------------------------------------------

  @override
  Stream<BleLink> get incoming => _incoming.stream;

  @override
  Future<void> startAdvertising(String token, Uint8List identity) async {
    await _poweredOn(_peripheral);
    final tx = GATTCharacteristic.mutable(
      uuid: _txUuid,
      properties: [GATTCharacteristicProperty.notify],
      permissions: [],
      descriptors: [],
    );
    final rx = GATTCharacteristic.mutable(
      uuid: _rxUuid,
      properties: [GATTCharacteristicProperty.write],
      permissions: [GATTCharacteristicPermission.write],
      descriptors: [],
    );
    final id = GATTCharacteristic.immutable(uuid: _identityUuid, value: identity, descriptors: []);
    _tx = tx;
    if (!_listening) {
      _listening = true;
      _subs
        ..add(_peripheral.characteristicNotifyStateChanged.listen(_onNotifyState))
        ..add(_peripheral.characteristicWriteRequested.listen(_onWrite));
      if (Platform.isAndroid) {
        // Darwin has no peripheral-side connection events; there an
        // unsubscribe is the only sign that a central went away.
        _subs.add(_peripheral.connectionStateChanged.listen((e) {
          if (e.state == ConnectionState.disconnected) _peripheralLinks[e.central.uuid.toString()]?._end();
        }));
      }
    }
    await _peripheral.removeAllServices();
    await _peripheral.addService(GATTService(
      uuid: _serviceUuid,
      isPrimary: true,
      includedServices: [],
      characteristics: [rx, tx, id],
    ));
    await _peripheral.startAdvertising(Platform.isAndroid
        ? Advertisement(
            serviceUUIDs: [_serviceUuid],
            manufacturerSpecificData: [
              ManufacturerSpecificData(id: p.manufacturerId, data: Uint8List.fromList(token.codeUnits)),
            ],
          )
        : Advertisement(name: p.advertisedName(token), serviceUUIDs: [_serviceUuid]));
    _advertising = true;
    _log.fine('advertising $token');
  }

  Future<void> _onNotifyState(GATTCharacteristicNotifyStateChangedEventArgs e) async {
    if (e.characteristic.uuid != _txUuid) return;
    final key = e.central.uuid.toString();
    if (!e.state) {
      _peripheralLinks[key]?._end();
      return;
    }
    _peripheralLinks[key]?._end(); // a stale link from the same central
    int maxNotify;
    try {
      maxNotify = min(512, await _peripheral.getMaximumNotifyLength(e.central));
    } catch (_) {
      maxNotify = 20;
    }
    final link = _PeripheralLink(this, e.central, maxNotify);
    _peripheralLinks[key] = link;
    _incoming.add(link);
  }

  Future<void> _onWrite(GATTCharacteristicWriteRequestedEventArgs e) async {
    if (e.characteristic.uuid != _rxUuid) return;
    final link = _peripheralLinks[e.central.uuid.toString()];
    if (link != null && !link._ended) {
      link._values.add(e.request.value);
      await _respond(e.request);
    } else {
      try {
        await _peripheral.respondWriteRequestWithError(e.request, error: GATTError.insufficientAuthorization);
      } catch (_) {}
    }
  }

  Future<void> _respond(GATTWriteRequest request) async {
    try {
      await _peripheral.respondWriteRequest(request);
    } catch (e) {
      _log.fine('respondWriteRequest failed: $e');
    }
  }

  @override
  Future<void> stopAdvertising() async {
    if (!_advertising) return;
    _advertising = false;
    await _peripheral.stopAdvertising();
  }

  @override
  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    try {
      if (_scanning) await stopScan();
      await stopAdvertising();
    } catch (_) {}
    for (final l in _peripheralLinks.values.toList()) {
      await l.close();
    }
    for (final s in _sessions.values.toList()) {
      await s._link?.close();
      s._end();
    }
    await _incoming.close();
    await _sightings.close();
  }
}

/// Waits until Bluetooth is on, asking for permissions on Android.
Future<void> _poweredOn(BluetoothLowEnergyManager manager, {Duration timeout = const Duration(seconds: 30)}) async {
  if (manager.state == BluetoothLowEnergyState.poweredOn) return;
  final on = Completer<void>();
  var authorizing = false;
  Future<void> check(BluetoothLowEnergyState state) async {
    if (on.isCompleted) return;
    if (state == BluetoothLowEnergyState.poweredOn) {
      on.complete();
    } else if (state == BluetoothLowEnergyState.unauthorized && Platform.isAndroid && !authorizing) {
      authorizing = true;
      if (!await manager.authorize() && !on.isCompleted) {
        on.completeError(StateError('Bluetooth permissions denied'));
      }
    } else if (state == BluetoothLowEnergyState.unsupported && !on.isCompleted) {
      on.completeError(StateError('Bluetooth LE is not supported on this device'));
    }
  }

  final sub = manager.stateChanged.listen((e) => check(e.state));
  try {
    await check(manager.state);
    await on.future.timeout(timeout);
  } finally {
    await sub.cancel();
  }
}

/// A GATT connection, as central, to one device.
class _GattSession {
  final BluetoothLowEnergyRadio _radio;
  final String _token;
  final Peripheral _peripheral;
  late GATTCharacteristic _rx;
  late GATTCharacteristic _tx;
  late GATTCharacteristic _identity;
  int _maxWrite = 20;
  _CentralLink? _link;
  Timer? _idleTimer;
  bool _ended = false;

  _GattSession(this._radio, this._token, this._peripheral);

  /// Disconnects if no link uses the session within [sessionReuse].
  void _scheduleIdleClose() {
    _idleTimer?.cancel();
    if (_link != null) return;
    _idleTimer = Timer(_radio.sessionReuse, () {
      if (_link == null && !_ended) {
        _log.fine('$_token: idle GATT connection closed');
        unawaited(_radio._central.disconnect(_peripheral).catchError((_) {}));
        _end();
      }
    });
  }

  void _end() {
    if (_ended) return;
    _ended = true;
    _idleTimer?.cancel();
    _link?._end();
    final key = _peripheral.uuid.toString();
    if (identical(_radio._sessions[key], this)) _radio._sessions.remove(key);
  }
}

class _CentralLink implements BleLink {
  final BluetoothLowEnergyRadio _radio;
  final _GattSession _session;
  final _values = StreamController<Uint8List>();
  final _done = Completer<void>();

  _CentralLink(this._radio, this._session);

  @override
  bool get isCentral => true;

  @override
  String get remoteId => _session._peripheral.uuid.toString();

  @override
  int get maxValueLength => _session._maxWrite;

  @override
  Stream<Uint8List> get values => _values.stream;

  @override
  Future<void> send(Uint8List value) {
    if (_done.isCompleted) return Future.error(StateError('BLE link closed'));
    return _radio._central.writeCharacteristic(_session._peripheral, _session._rx,
        value: value, type: GATTCharacteristicWriteType.withResponse);
  }

  @override
  Future<void> close() async {
    if (_done.isCompleted) return;
    _end();
    try {
      await _radio._central.disconnect(_session._peripheral);
    } catch (_) {}
    _session._end();
  }

  void _end() {
    if (_done.isCompleted) return;
    _done.complete();
    unawaited(_values.close());
  }

  @override
  Future<void> get done => _done.future;
}

class _PeripheralLink implements BleLink {
  final BluetoothLowEnergyRadio _radio;
  final Central _central;
  @override
  final int maxValueLength;
  final _values = StreamController<Uint8List>();
  final _done = Completer<void>();

  _PeripheralLink(this._radio, this._central, this.maxValueLength);

  bool get _ended => _done.isCompleted;

  @override
  bool get isCentral => false;

  @override
  String get remoteId => _central.uuid.toString();

  @override
  Stream<Uint8List> get values => _values.stream;

  @override
  Future<void> send(Uint8List value) {
    final tx = _radio._tx;
    if (_ended || tx == null) return Future.error(StateError('BLE link closed'));
    return _radio._peripheral.notifyCharacteristic(_central, tx, value: value);
  }

  @override
  Future<void> close() async {
    if (_ended) return;
    _end();
    // Only Android can drop a central; on Darwin the central disconnects
    // when it reads the close frame.
    if (Platform.isAndroid) {
      try {
        await _radio._peripheral.disconnect(_central);
      } catch (_) {}
    }
  }

  void _end() {
    if (_ended) return;
    _done.complete();
    unawaited(_values.close());
    final key = _central.uuid.toString();
    if (identical(_radio._peripheralLinks[key], this)) _radio._peripheralLinks.remove(key);
  }

  @override
  Future<void> get done => _done.future;
}
