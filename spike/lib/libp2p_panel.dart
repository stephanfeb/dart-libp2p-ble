// "libp2p" mode: a real libp2p host on the dart_libp2p_ble transport.
//
// Discovery finds nearby nodes and connects (Noise + yamux over GATT); the
// panel pings every connected peer every 5 s and can send gossipsub
// messages on one topic, so 3+ devices test the mesh too. Switch discovery
// off on one device to make the other one the dialer (central).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_libp2p/config/config.dart';
import 'package:dart_libp2p/core/crypto/ed25519.dart';
import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/p2p/protocol/ping/ping.dart';
import 'package:dart_libp2p_ble/dart_libp2p_ble.dart';
import 'package:dart_libp2p_pubsub/dart_libp2p_pubsub.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';

const _topic = '/ble-spike/1';

/// Logger names whose FINE records go to the screen log; other loggers only
/// show warnings and errors.
const _verboseLoggers = {'BleTransport', 'BleConn', 'BleDiscovery', 'BluetoothLowEnergyRadio'};

String _short(PeerId p) {
  final s = p.toBase58();
  return s.substring(s.length - 6);
}

class _PeerInfo {
  final DateTime connectedAt;
  Duration? lastRtt;
  int pingsOk = 0;
  int pingsFailed = 0;
  _PeerInfo(this.connectedAt);
}

class Libp2pPanel extends StatefulWidget {
  final void Function(String) log;
  const Libp2pPanel({super.key, required this.log});

  @override
  State<Libp2pPanel> createState() => _Libp2pPanelState();
}

class _Libp2pPanelState extends State<Libp2pPanel> {
  Host? _host;
  BleTransport? _ble;
  BleDiscovery? _discovery;
  PubSub? _pubsub;
  final _subs = <StreamSubscription>[];
  final _timers = <Timer>[];
  final _peers = <PeerId, _PeerInfo>{};
  final _startWatch = Stopwatch();
  bool _discoveryOn = true;
  bool _starting = false;
  int _sent = 0;
  int _received = 0;

  void _log(String line) => widget.log(line);

  @override
  void initState() {
    super.initState();
    hierarchicalLoggingEnabled = true;
    Logger.root.level = Level.FINE;
    _subs.add(Logger.root.onRecord.listen((r) {
      if (_verboseLoggers.contains(r.loggerName) || r.level >= Level.WARNING) {
        _log('[${r.loggerName}] ${r.message}${r.error != null ? ' (${r.error})' : ''}');
      }
    }));
  }

  Future<void> _start() async {
    setState(() => _starting = true);
    try {
      final keyPair = await generateEd25519KeyPair();
      final peerId = PeerId.fromPublicKey(keyPair.publicKey);
      final ble = BleTransport(radio: BluetoothLowEnergyRadio(), localPeer: peerId);
      final host = await Libp2p.new_([
        Libp2p.identity(keyPair),
        Libp2p.transport(ble),
        Libp2p.listenAddrs([ble.listenAddr]),
        Libp2p.autoNAT(false),
        Libp2p.relay(false),
        Libp2p.autoRelay(false),
        Libp2p.holePunching(false),
      ]);
      await host.start();
      _startWatch.start();
      _log('host ${_short(peerId)} (${Platform.operatingSystem}) token ${ble.token}, '
          'discovery ${_discoveryOn ? 'on' : 'OFF (wait to be dialed)'}');

      final pubsub = PubSub(host, GossipSubRouter());
      await pubsub.start();
      final sub = pubsub.subscribe(_topic);
      _subs.add(sub.stream.listen((m) {
        final msg = m as PubSubMessage;
        if (msg.from == host.id) return;
        _received++;
        _log('GOSSIP from ${_short(msg.from)}: ${utf8.decode(msg.data)}');
        if (mounted) setState(() {});
      }));

      if (_discoveryOn) {
        final discovery = BleDiscovery(host: host, transport: ble);
        _subs.add(discovery.peerFound.listen((p) => _log('discovery dialed ${_short(p)}')));
        await discovery.start();
        _discovery = discovery;
      }

      _timers
        ..add(Timer.periodic(const Duration(seconds: 1), (_) => _refreshPeers()))
        ..add(Timer.periodic(const Duration(seconds: 5), (_) => _pingAll()));
      setState(() {
        _host = host;
        _ble = ble;
        _pubsub = pubsub;
      });
    } catch (e, st) {
      _log('START FAILED: $e\n$st');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  void _refreshPeers() {
    final host = _host;
    if (host == null) return;
    final now = host.network.peers.toSet();
    for (final p in now) {
      if (!_peers.containsKey(p)) {
        _peers[p] = _PeerInfo(DateTime.now());
        final conns = host.network.connsToPeer(p);
        final dir = conns.isEmpty ? '?' : conns.first.stat.stats.direction.name;
        _log('CONNECTED ${_short(p)} ($dir) at ${_startWatch.elapsedMilliseconds} ms after start, '
            '${conns.length} conn(s), ${conns.map((c) => c.remoteMultiaddr).join(', ')}');
      }
    }
    for (final p in _peers.keys.toList()) {
      if (!now.contains(p)) {
        final info = _peers.remove(p)!;
        _log('DISCONNECTED ${_short(p)} after ${DateTime.now().difference(info.connectedAt).inSeconds} s '
            '(pings ${info.pingsOk} ok, ${info.pingsFailed} failed)');
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _pingAll() async {
    final host = _host;
    if (host == null) return;
    for (final p in _peers.keys.toList()) {
      final info = _peers[p];
      if (info == null) continue;
      try {
        final r = await PingService(host).ping(p).first.timeout(const Duration(seconds: 10));
        if (r.hasError) throw r.error!;
        info.lastRtt = r.rtt;
        info.pingsOk++;
      } catch (e) {
        info.pingsFailed++;
        _log('ping ${_short(p)} failed: $e');
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _send() async {
    final pubsub = _pubsub;
    if (pubsub == null) return;
    final text = 'hello #${++_sent} from ${_short(_host!.id)} (${Platform.operatingSystem})';
    try {
      await pubsub.publish(_topic, Uint8List.fromList(utf8.encode(text)));
      _log('GOSSIP sent: $text');
    } catch (e) {
      _log('GOSSIP send failed: $e');
    }
    setState(() {});
  }

  @override
  void dispose() {
    for (final t in _timers) {
      t.cancel();
    }
    for (final s in _subs) {
      s.cancel();
    }
    unawaited(_shutdown());
    super.dispose();
  }

  Future<void> _shutdown() async {
    await _discovery?.dispose();
    await _pubsub?.stop();
    await _host?.close();
  }

  @override
  Widget build(BuildContext context) {
    final host = _host;
    final text = Theme.of(context).textTheme;
    if (host == null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Discovery (scan and dial)'),
            subtitle: const Text('Off: only advertise, so the other device dials'),
            value: _discoveryOn,
            onChanged: _starting ? null : (v) => setState(() => _discoveryOn = v),
          ),
          FilledButton(
            onPressed: _starting ? null : _start,
            child: Text(_starting ? 'Starting…' : 'Start libp2p host'),
          ),
        ]),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Me ${_short(host.id)} · token ${_ble!.token} · discovery ${_discoveryOn ? 'on' : 'off'}',
            style: text.titleSmall),
        const SizedBox(height: 4),
        if (_peers.isEmpty) const Text('No peers yet'),
        for (final MapEntry(key: p, value: info) in _peers.entries)
          Text('${_short(p)} · rtt ${info.lastRtt?.inMilliseconds ?? '-'} ms · '
              'pings ${info.pingsOk}/${info.pingsOk + info.pingsFailed}'),
        const SizedBox(height: 8),
        Row(children: [
          FilledButton.tonal(onPressed: _send, child: const Text('Send gossip')),
          const SizedBox(width: 12),
          Text('sent $_sent · received $_received'),
        ]),
      ]),
    );
  }
}
