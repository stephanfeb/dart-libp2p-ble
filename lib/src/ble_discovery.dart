import 'dart:async';

import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/network/common.dart';
import 'package:dart_libp2p/core/network/conn.dart';
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
/// [maxLinks] BLE connections, inbound ones included: when nearby nodes
/// dial in past the budget, the newest inbound connections are closed.
/// Gossipsub and other protocols relay across the partial mesh.
///
/// Signal strength: a device heard below [minRssi] is not dialed. With
/// [swapMargin], a full node that hears a device at least that many dB
/// stronger than its weakest link (one open for [minLinkAge] at least)
/// closes that link and dials the stronger device. Swaps can cut a weak
/// link that was the only bridge to another part of the mesh, so they are
/// off by default.
class BleDiscovery {
  final Host host;
  final BleTransport transport;

  /// Most BLE connections this node keeps, in both directions.
  final int maxLinks;

  /// How long the higher token waits for the lower one to dial.
  final Duration yieldFor;

  /// How long to wait before trying a token again after a failure, and
  /// before dialing it again after a connection to it (so a full node that
  /// closes our connection is not dialed again at once).
  final Duration retryAfter;

  /// Devices heard weaker than this (dBm) are not dialed. Null: no limit.
  final int? minRssi;

  /// When full, a device this many dB stronger than the weakest link
  /// replaces it. Null: no swaps.
  final int? swapMargin;

  /// Links younger than this are not swapped out.
  final Duration minLinkAge;

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
  final _rssi = <String, int>{};
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
    this.minRssi,
    this.swapMargin,
    this.minLinkAge = const Duration(minutes: 1),
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
      if (s.rssi case final rssi?) _rssi[s.token] = rssi;
      _consider(s.token);
    });
    _recheck = Timer.periodic(recheckEvery, (_) {
      _trim();
      _seen.toList().forEach(_consider);
    });
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
  int get bleConnections => _bleConns().length;

  List<Conn> _bleConns() =>
      host.network.conns.where((c) => !c.isClosed && c.remoteMultiaddr.hasProtocol(bleProtocolName)).toList();

  /// Closes the newest inbound connections past [maxLinks] (then the newest
  /// outbound ones, which only happens when both sides dialed at once).
  void _trim() {
    final conns = _bleConns();
    final over = conns.length - maxLinks;
    if (over <= 0) return;
    int rank(Conn c) => c.stat.stats.direction == Direction.inbound ? 0 : 1;
    conns.sort((a, b) {
      final byDirection = rank(a).compareTo(rank(b));
      return byDirection != 0 ? byDirection : b.stat.stats.opened.compareTo(a.stat.stats.opened);
    });
    for (final c in conns.take(over)) {
      _log.fine('over the link budget: closing ${c.remotePeer.toBase58()}');
      unawaited(c.close().catchError((Object e) => _log.fine('close: $e')));
    }
  }

  /// The weakest link older than [minLinkAge] whose device was heard, with
  /// its signal strength.
  (Conn, int)? _weakestLink(DateTime now) {
    final tokenOf = {for (final MapEntry(:key, :value) in _peerOfToken.entries) value: key};
    (Conn, int)? weakest;
    for (final c in _bleConns()) {
      if (now.difference(c.stat.stats.opened) < minLinkAge) continue;
      final rssi = _rssi[tokenOf[c.remotePeer]];
      if (rssi == null) continue;
      if (weakest == null || rssi < weakest.$2) weakest = (c, rssi);
    }
    return weakest;
  }

  void _consider(String token) {
    if (!_started || _dialing.contains(token)) return;
    final now = DateTime.now();
    final notBefore = _notBefore[token];
    if (notBefore != null && now.isBefore(notBefore)) return;
    final known = _peerOfToken[token];
    if (known != null && host.network.connectedness(known) == Connectedness.connected) return;
    final rssi = _rssi[token];
    if (minRssi != null && rssi != null && rssi < minRssi!) return;
    if (bleConnections >= maxLinks) {
      final margin = swapMargin;
      // One swap at a time: a closing link still counts.
      if (margin == null || rssi == null || _dialing.isNotEmpty) return;
      final weakest = _weakestLink(now);
      if (weakest == null || rssi < weakest.$2 + margin) return;
      _log.fine('$token ($rssi dBm) replaces ${weakest.$1.remotePeer.toBase58()} (${weakest.$2} dBm)');
      unawaited(weakest.$1.close().catchError((Object e) => _log.fine('close: $e')));
      unawaited(_dial(token));
      return;
    }

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
      // The identity characteristic is not authenticated: a device can
      // copy another node's peer ID. Noise proves who answered, and
      // dart_libp2p before 4.11.0 does not fail the dial when that is
      // someone else, so check that the peer itself is connected.
      if (host.network.connectedness(peer) != Connectedness.connected) {
        _peerOfToken.remove(token);
        throw StateError('$token answered as a different peer than ${peer.toBase58()}');
      }
      _log.fine('$token: connected to ${peer.toBase58()}');
      _notBefore[token] = DateTime.now().add(retryAfter);
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
