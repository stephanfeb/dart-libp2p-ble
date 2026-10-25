// BLE spike for the dart-libp2p BLE transport (dart-libp2p-zc4.1).
//
// One device runs "Host" (GATT peripheral): it advertises a service and
// echoes every message it receives. The other runs "Join" (GATT central):
// it scans, connects to a host and measures connect time, write length and
// the round trip of messages of several sizes, over N cycles.
//
// Messages are framed as a 4-byte big-endian length plus payload, cut into
// chunks of the negotiated write/notify length, as the transport will do.
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

final serviceUuid = UUID.fromString('b1e5f00d-0000-4c1b-9d6e-5d1e0a9f2b01');
final rxUuid = UUID.fromString('b1e5f00d-0001-4c1b-9d6e-5d1e0a9f2b01'); // central -> host
final txUuid = UUID.fromString('b1e5f00d-0002-4c1b-9d6e-5d1e0a9f2b01'); // host -> central

const messageSizes = [256, 2048, 8192];

void main() => runApp(const SpikeApp());

class SpikeApp extends StatelessWidget {
  const SpikeApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'BLE spike',
        theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
        home: const HomePage(),
      );
}

/// Joins chunks back into length-prefixed messages.
class Reassembler {
  final _buffer = BytesBuilder();
  final void Function(Uint8List message) onMessage;

  Reassembler(this.onMessage);

  void add(Uint8List chunk) {
    _buffer.add(chunk);
    while (true) {
      final bytes = _buffer.toBytes();
      if (bytes.length < 4) return;
      final length = ByteData.sublistView(bytes, 0, 4).getUint32(0);
      if (bytes.length < 4 + length) return;
      onMessage(Uint8List.fromList(Uint8List.sublistView(bytes, 4, 4 + length)));
      _buffer.clear();
      _buffer.add(Uint8List.sublistView(bytes, 4 + length));
    }
  }
}

/// Cuts a message into length-prefixed chunks of at most [chunkSize] bytes.
Iterable<Uint8List> frame(Uint8List message, int chunkSize) sync* {
  final framed = Uint8List(4 + message.length);
  ByteData.sublistView(framed).setUint32(0, message.length);
  framed.setRange(4, framed.length, message);
  for (var i = 0; i < framed.length; i += chunkSize) {
    yield Uint8List.sublistView(framed, i, min(i + chunkSize, framed.length));
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _log = <String>[];
  final _logScroll = ScrollController();
  String _mode = 'idle';

  void log(String line) {
    final t = DateTime.now().toIso8601String().substring(11, 23);
    // Also printed, so a `flutter run` console has the full log.
    debugPrint('[spike] $line');
    if (!mounted) return;
    // A panel can log from its initState, while the tree is building; a
    // setState then throws, so the line is added after the frame.
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => log(line));
      return;
    }
    setState(() => _log.add('$t $line'));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScroll.hasClients) _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('BLE spike · ${Platform.operatingSystem} · $_mode'),
        actions: [
          IconButton(
            tooltip: 'Copy log',
            icon: const Icon(Icons.copy),
            onPressed: () => Clipboard.setData(ClipboardData(text: _log.join('\n'))),
          ),
          IconButton(
            tooltip: 'Clear log',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => setState(_log.clear),
          ),
        ],
      ),
      body: Column(children: [
        if (_mode == 'idle')
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              Expanded(
                child: FilledButton(
                  onPressed: () => setState(() => _mode = 'host'),
                  child: const Text('Host (peripheral)'),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: FilledButton.tonal(
                  onPressed: () => setState(() => _mode = 'join'),
                  child: const Text('Join (central)'),
                ),
              ),
            ]),
          ),
        if (_mode == 'host') HostPanel(log: log),
        if (_mode == 'join') JoinPanel(log: log),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            controller: _logScroll,
            itemCount: _log.length,
            itemBuilder: (_, i) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
              child: Text(_log[i], style: const TextStyle(fontFamily: 'Menlo', fontSize: 11)),
            ),
          ),
        ),
      ]),
    );
  }
}

/// Awaits [future], failing after [seconds] with a message that names [name].
Future<T> step<T>(String name, Future<T> future, int seconds) => future.timeout(
      Duration(seconds: seconds),
      onTimeout: () => throw TimeoutException('$name timed out after ${seconds}s'),
    );

/// Waits until Bluetooth is powered on (or fails after [timeout]).
///
/// The first state is often `unknown`; on Android it can then become
/// `unauthorized`, and the app must ask for the Bluetooth permissions.
Future<void> waitPoweredOn(BluetoothLowEnergyManager manager, void Function(String) log,
    {Duration timeout = const Duration(seconds: 30)}) async {
  if (manager.state == BluetoothLowEnergyState.poweredOn) return;
  log('Bluetooth state ${manager.state}; waiting for poweredOn');
  final poweredOn = Completer<void>();
  var authorizing = false;
  Future<void> onState(BluetoothLowEnergyState state) async {
    if (poweredOn.isCompleted) return;
    if (state == BluetoothLowEnergyState.poweredOn) {
      poweredOn.complete();
    } else if (state == BluetoothLowEnergyState.unauthorized && Platform.isAndroid && !authorizing) {
      authorizing = true;
      log('asking for Bluetooth permissions');
      final granted = await manager.authorize();
      if (!granted && !poweredOn.isCompleted) {
        poweredOn.completeError(StateError('Bluetooth permissions denied'));
      }
    } else {
      log('Bluetooth state $state');
    }
  }

  final sub = manager.stateChanged.listen((e) => onState(e.state));
  try {
    // The state can change between the first check and the listen.
    await onState(manager.state);
    await poweredOn.future.timeout(timeout);
  } finally {
    await sub.cancel();
  }
}

// ---------------------------------------------------------------- Host ---

class HostPanel extends StatefulWidget {
  final void Function(String) log;
  const HostPanel({super.key, required this.log});

  @override
  State<HostPanel> createState() => _HostPanelState();
}

class _HostPanelState extends State<HostPanel> {
  final _manager = PeripheralManager();
  final _subs = <StreamSubscription>[];
  final _reassemblers = <String, Reassembler>{};
  GATTCharacteristic? _tx;
  final _name = 'SV${Random().nextInt(0xffffff).toRadixString(16).padLeft(6, '0')}';
  bool _advertising = false;
  int _echoed = 0;
  // Off by default: the Android stack can re-enable the advertising set by
  // itself after a connection, and a stop + start can then leave it off.
  bool _restartOnDisconnect = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final log = widget.log;
    try {
      await waitPoweredOn(_manager, log);
      final tx = GATTCharacteristic.mutable(
        uuid: txUuid,
        properties: [GATTCharacteristicProperty.notify],
        permissions: [],
        descriptors: [],
      );
      _tx = tx;
      final rx = GATTCharacteristic.mutable(
        uuid: rxUuid,
        properties: [GATTCharacteristicProperty.write, GATTCharacteristicProperty.writeWithoutResponse],
        permissions: [GATTCharacteristicPermission.write],
        descriptors: [],
      );
      _subs.add(_manager.characteristicWriteRequested.listen((e) async {
        if (e.characteristic.uuid != rxUuid) return;
        final central = e.central;
        final key = central.uuid.toString();
        _reassemblers.putIfAbsent(key, () => Reassembler((message) => _echo(central, message)))
            .add(e.request.value);
        try {
          await _manager.respondWriteRequest(e.request);
        } catch (_) {
          // A write without response needs no answer on some platforms.
        }
      }));
      _subs.add(_manager.characteristicNotifyStateChanged.listen((e) {
        log('central ${e.central.uuid.toString().substring(0, 8)} notify=${e.state}');
        if (!e.state) _reassemblers.remove(e.central.uuid.toString());
      }));
      await _manager.removeAllServices();
      await _manager.addService(GATTService(
        uuid: serviceUuid,
        isPrimary: true,
        includedServices: [],
        characteristics: [rx, tx],
      ));
      if (Platform.isAndroid) {
        // Android only (Darwin has no peripheral-side connection events).
        // Many Android controllers stop a connectable advertisement when a
        // central connects, so advertising is restarted on each change.
        _subs.add(_manager.connectionStateChanged.listen((e) {
          final id = e.central.uuid.toString().substring(0, 8);
          log('central $id ${e.state.name}');
          if (e.state == ConnectionState.disconnected) {
            _reassemblers.remove(e.central.uuid.toString());
            if (_restartOnDisconnect) _restartAdvertising();
          }
        }));
      }
      await _manager.startAdvertising(_advertisement);
      if (!mounted) return;
      setState(() => _advertising = true);
      log('advertising as $_name');
    } catch (e) {
      log('HOST ERROR: $e');
    }
  }

  Advertisement get _advertisement => Advertisement(
        name: Platform.isWindows ? null : _name,
        serviceUUIDs: [serviceUuid],
      );

  bool _restarting = false;

  /// Stops and starts advertising again, waiting [_restartDelays] between the
  /// two. A start that gets no answer within 5 s is tried again after a
  /// longer delay.
  Future<void> _restartAdvertising() async {
    if (_restarting) return;
    _restarting = true;
    try {
      for (final (i, delay) in _restartDelays.indexed) {
        try {
          await step('stopAdvertising', _manager.stopAdvertising(), 5);
          await Future.delayed(delay);
          await step('startAdvertising', _manager.startAdvertising(_advertisement), 5);
          widget.log('advertising restarted (attempt ${i + 1}, delay ${delay.inMilliseconds} ms)');
          return;
        } catch (e) {
          widget.log('advertising restart attempt ${i + 1} (delay ${delay.inMilliseconds} ms) failed: $e');
        }
      }
    } finally {
      _restarting = false;
    }
  }

  static const _restartDelays = [
    Duration(milliseconds: 300),
    Duration(seconds: 1),
    Duration(seconds: 3),
  ];

  Future<void> _echo(Central central, Uint8List message) async {
    try {
      final notifyLength = await _manager.getMaximumNotifyLength(central);
      for (final chunk in frame(message, notifyLength)) {
        await _manager.notifyCharacteristic(central, _tx!, value: chunk);
      }
      if (mounted) setState(() => _echoed++);
    } catch (e) {
      widget.log('echo failed: $e');
    }
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _manager.stopAdvertising();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_advertising ? 'Advertising as $_name · echoed $_echoed messages' : 'Starting…',
              style: Theme.of(context).textTheme.titleMedium),
          if (Platform.isAndroid)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Restart advertising on disconnect'),
              value: _restartOnDisconnect,
              onChanged: (v) => setState(() => _restartOnDisconnect = v),
            ),
        ]),
      );
}

// ---------------------------------------------------------------- Join ---

class JoinPanel extends StatefulWidget {
  final void Function(String) log;
  const JoinPanel({super.key, required this.log});

  @override
  State<JoinPanel> createState() => _JoinPanelState();
}

class _JoinPanelState extends State<JoinPanel> {
  final _manager = CentralManager();
  final _found = <String, DiscoveredEventArgs>{};
  StreamSubscription? _discoverySub;
  bool _running = false;
  int _cycles = 10;
  bool _withResponse = true;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    try {
      await waitPoweredOn(_manager, widget.log);
      _discoverySub = _manager.discovered.listen((e) {
        if (mounted) setState(() => _found[e.peripheral.uuid.toString()] = e);
      });
      await _manager.startDiscovery(serviceUUIDs: [serviceUuid]);
      widget.log('scanning');
    } catch (e) {
      widget.log('SCAN ERROR: $e');
    }
  }

  @override
  void dispose() {
    _discoverySub?.cancel();
    _manager.stopDiscovery();
    super.dispose();
  }

  /// Scans for the host by its advertised [name]. An Android host can
  /// advertise from a new random address after each connection, and iOS then
  /// gives it a new peripheral ID; the old one can no longer be connected.
  Future<Peripheral> _rediscover(Peripheral previous, String name) async {
    final watch = Stopwatch()..start();
    final found = _manager.discovered.firstWhere((e) => e.advertisement.name == name);
    await _manager.startDiscovery(serviceUUIDs: [serviceUuid]);
    try {
      final e = await step('rediscover $name', found, 30);
      final changed = e.peripheral.uuid != previous.uuid;
      widget.log('rediscovered in ${watch.elapsedMilliseconds} ms, '
          'peripheral ID ${changed ? 'CHANGED ${e.peripheral.uuid.toString().substring(0, 8)}' : 'same'}');
      return e.peripheral;
    } finally {
      await _manager.stopDiscovery();
    }
  }

  Future<void> _run(Peripheral peripheral, String name) async {
    final log = widget.log;
    setState(() => _running = true);
    await _manager.stopDiscovery();
    final connectMs = <int>[];
    final rtts = <int, List<int>>{for (final s in messageSizes) s: []};
    var ok = 0;
    var failed = 0;
    int? mtu;
    int? writeLength;
    for (var cycle = 1; cycle <= _cycles; cycle++) {
      final subs = <StreamSubscription>[];
      StreamIterator<Uint8List>? replyQueue;
      try {
        if (cycle > 1) peripheral = await _rediscover(peripheral, name);
        final watch = Stopwatch()..start();
        await step('connect', _manager.connect(peripheral), 15);
        final tConnect = watch.elapsedMilliseconds;
        final services = await step('discoverGATT', _manager.discoverGATT(peripheral), 10);
        final tDiscover = watch.elapsedMilliseconds;
        final service = services.firstWhere((s) => s.uuid == serviceUuid);
        final rx = service.characteristics.firstWhere((c) => c.uuid == rxUuid);
        final tx = service.characteristics.firstWhere((c) => c.uuid == txUuid);

        final replies = StreamController<Uint8List>();
        final reassembler = Reassembler(replies.add);
        subs.add(_manager.characteristicNotified.listen((e) {
          if (e.peripheral.uuid == peripheral.uuid && e.characteristic.uuid == txUuid) {
            reassembler.add(e.value);
          }
        }));
        await step('subscribe', _manager.setCharacteristicNotifyState(peripheral, tx, state: true), 10);
        connectMs.add(watch.elapsedMilliseconds);
        final split = 'connect $tConnect + discoverGATT ${tDiscover - tConnect} (${services.length} services) '
            '+ subscribe ${watch.elapsedMilliseconds - tDiscover}';

        final type = _withResponse
            ? GATTCharacteristicWriteType.withResponse
            : GATTCharacteristicWriteType.withoutResponse;
        if (Platform.isAndroid) mtu = await step('requestMTU', _manager.requestMTU(peripheral, mtu: 517), 10);
        final length = await _manager.getMaximumWriteLength(peripheral, type: type);
        writeLength = length;

        replyQueue = StreamIterator(replies.stream);
        final times = <String>[];
        for (final size in messageSizes) {
          final message = Uint8List.fromList(List.generate(size, (i) => (i * 31 + cycle) & 0xff));
          final t = Stopwatch()..start();
          for (final chunk in frame(message, length)) {
            await step('write', _manager.writeCharacteristic(peripheral, rx, value: chunk, type: type), 10);
          }
          if (!await step('echo of ${size}B', replyQueue.moveNext(), 20)) {
            throw StateError('reply stream closed');
          }
          final reply = replyQueue.current;
          if (reply.length != size || reply[size ~/ 2] != message[size ~/ 2]) {
            throw StateError('echo of $size bytes came back wrong (${reply.length} bytes)');
          }
          rtts[size]!.add(t.elapsedMilliseconds);
          times.add('${size}B ${t.elapsedMilliseconds} ms');
        }
        ok++;
        log('cycle $cycle ok: connect ${connectMs.last} ms [$split], ${times.join(', ')}');
      } catch (e) {
        failed++;
        log('cycle $cycle FAILED: $e');
      } finally {
        await replyQueue?.cancel();
        for (final s in subs) {
          await s.cancel();
        }
        try {
          await _manager.disconnect(peripheral).timeout(const Duration(seconds: 5));
        } catch (_) {}
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }

    String stats(List<int> v) {
      if (v.isEmpty) return '-';
      final s = [...v]..sort();
      return 'median ${s[s.length ~/ 2]} ms, min ${s.first}, max ${s.last}';
    }

    log('=== SUMMARY ${Platform.operatingSystem} -> $name, '
        '${_withResponse ? 'write with response' : 'write without response'} ===');
    log('cycles $ok ok / $failed failed of $_cycles');
    log('connect+discover+subscribe: ${stats(connectMs)}');
    log('max write length: $writeLength${mtu != null ? ', MTU $mtu' : ''}');
    for (final size in messageSizes) {
      log('round trip ${size}B: ${stats(rtts[size]!)}');
    }
    if (!mounted) return;
    setState(() => _running = false);
    await _manager.startDiscovery(serviceUUIDs: [serviceUuid]);
  }

  @override
  Widget build(BuildContext context) {
    final entries = _found.values.toList()..sort((a, b) => b.rssi.compareTo(a.rssi));
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(children: [
        Row(children: [
          const Text('Cycles'),
          const SizedBox(width: 8),
          DropdownButton<int>(
            value: _cycles,
            items: [1, 10, 50].map((c) => DropdownMenuItem(value: c, child: Text('$c'))).toList(),
            onChanged: _running ? null : (v) => setState(() => _cycles = v!),
          ),
          const SizedBox(width: 16),
          const Text('Write with response'),
          Switch(
            value: _withResponse,
            onChanged: _running ? null : (v) => setState(() => _withResponse = v),
          ),
        ]),
        if (entries.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('Scanning for hosts…')),
        for (final e in entries)
          ListTile(
            dense: true,
            title: Text(e.advertisement.name ?? '(no name)'),
            subtitle: Text('RSSI ${e.rssi}  ${e.peripheral.uuid.toString().substring(0, 8)}'),
            trailing: FilledButton(
              onPressed: _running ? null : () => _run(e.peripheral, e.advertisement.name ?? '?'),
              child: Text(_running ? 'Running…' : 'Run test'),
            ),
          ),
      ]),
    );
  }
}
