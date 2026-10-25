import 'dart:async';

import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/network/network.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:logging/logging.dart';

import 'ble_transport.dart';
import 'protocol.dart';
import 'radio.dart';

final _log = Logger('BleDiscovery');

/// Finds nearby libp2p BLE nodes and connects to them.
///
/// Every node scans and advertises. When two nodes see each other, the one
/// with the lower token dials; the other dials too if no connection came
/// after [yieldFor], in case it cannot be heard. A node keeps at most
/// [maxLinks] BLE connections; gossipsub and other protocols relay across
/// the partial mesh.
class BleDiscovery {
  final Host host;
  final BleTransport transport;

  /// Most BLE connections this node keeps, in both directions.
  final int maxLinks;

  /// How long the higher token waits for the lower one to dial.
  final Duration yieldFor;

  /// How long to wait before trying a token again after a failure.
  final Duration retryAfter;

  /// How long a learned `/ble` address stays in the peerstore.
  final Duration addrTtl;

  /// How often the tokens seen so far are looked at again. iOS reports a
  /// device once per scan, so waits and retries cannot rely on new
  /// sightings.
  final Duration recheckEvery;

  final _seen = <String>{};
  final _peerOfToken = <String, PeerId>{};
  final _firstSeen = <String, DateTime>{};
  final _notBefore = <String, DateTime>{};
  final _dialing = <String>{};
  final _found = StreamController<PeerId>.broadcast();
  StreamSubscription<BleSighting>? _sub;
  Timer? _recheck;
  bool _started = false;

  BleDiscovery({
    required this.host,
    required this.transport,
    this.maxLinks = 4,
    this.yieldFor = const Duration(seconds: 8),
    this.retryAfter = const Duration(seconds: 30),
    this.addrTtl = const Duration(minutes: 10),
    this.recheckEvery = const Duration(seconds: 3),
  });

  BleRadio get _radio => transport.radio;

  /// Peers this node connected to over BLE (each once).
  Stream<PeerId> get peerFound => _found.stream;

  /// The peers of the tokens seen so far.
  Map<String, PeerId> get knownTokens => Map.unmodifiable(_peerOfToken);

  Future<void> start() async {
    if (_started) return;
    _started = true;
    _sub = _radio.sightings.listen((s) {
      if (s.token == transport.token) return;
      _seen.add(s.token);
      _consider(s.token);
    });
    _recheck = Timer.periodic(recheckEvery, (_) => _seen.toList().forEach(_consider));
    await _radio.startScan();
  }

  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    _recheck?.cancel();
    await _sub?.cancel();
    _sub = null;
    await _radio.stopScan();
  }

  /// Number of open BLE connections.
  int get bleConnections =>
      host.network.conns.where((c) => !c.isClosed && c.remoteMultiaddr.hasProtocol(bleProtocolName)).length;

  void _consider(String token) {
    if (!_started || _dialing.contains(token)) return;
    final now = DateTime.now();
    final notBefore = _notBefore[token];
    if (notBefore != null && now.isBefore(notBefore)) return;
    final known = _peerOfToken[token];
    if (known != null && host.network.connectedness(known) == Connectedness.connected) return;
    if (bleConnections >= maxLinks) return;

    final first = _firstSeen.putIfAbsent(token, () => now);
    final weDial = transport.token.compareTo(token) < 0;
    if (!weDial && now.difference(first) < yieldFor) {
      // The other side dials; the recheck looks again.
      return;
    }
    unawaited(_dial(token));
  }

  Future<void> _dial(String token) async {
    _dialing.add(token);
    try {
      var peer = _peerOfToken[token];
      if (peer == null) {
        final identity = await _radio.readIdentity(token);
        peer = PeerId.fromBytes(identity);
        _peerOfToken[token] = peer;
      }
      if (peer == host.id) return;
      if (host.network.connectedness(peer) == Connectedness.connected) {
        // It dialed us meanwhile.
        _log.fine('$token: already connected to ${peer.toBase58()}');
        return;
      }
      final addr = bleAddr(token);
      await host.peerStore.addrBook.addAddrs(peer, [addr], addrTtl);
      await host.connect(AddrInfo(peer, [addr]));
      _log.fine('$token: connected to ${peer.toBase58()}');
      _found.add(peer);
    } catch (e) {
      _log.fine('$token: dial failed: $e');
      _notBefore[token] = DateTime.now().add(retryAfter);
    } finally {
      _dialing.remove(token);
    }
  }

  Future<void> dispose() async {
    await stop();
    await _found.close();
  }
}
