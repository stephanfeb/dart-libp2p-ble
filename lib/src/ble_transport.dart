import 'dart:async';

import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/conn.dart';
import 'package:dart_libp2p/core/network/transport_conn.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/p2p/transport/listener.dart';
import 'package:dart_libp2p/p2p/transport/transport.dart';
import 'package:dart_libp2p/p2p/transport/transport_config.dart';
import 'package:logging/logging.dart';

import 'ble_conn.dart';
import 'protocol.dart';
import 'radio.dart';

final _log = Logger('BleTransport');

/// The libp2p BLE transport: dials and listens on `/ble/<token>` addresses.
///
/// ```dart
/// final ble = BleTransport(radio: BluetoothLowEnergyRadio(), localPeer: peerId);
/// final host = await Libp2p.new_([
///   Libp2p.identity(keyPair),
///   Libp2p.transport(ble),
///   Libp2p.listenAddrs([ble.listenAddr]),
/// ]);
/// ```
///
/// Each connection is one GATT link; the upgrader runs Noise and yamux on it
/// as on TCP. Listening serves the GATT service and advertises the token;
/// finding nearby nodes is [BleDiscovery]'s job.
class BleTransport implements Transport {
  final BleRadio radio;

  /// The local peer, published in the identity characteristic.
  final PeerId localPeer;

  @override
  final TransportConfig config;

  String _token;
  BleListener? _listener;

  BleTransport({
    required this.radio,
    required this.localPeer,
    String? token,
    TransportConfig? config,
  })  : _token = token ?? newToken(),
        config = config ?? TransportConfig.defaultConfig;

  /// The token this node advertises.
  String get token => _token;

  /// `/ble/<token>`: pass it to `Libp2p.listenAddrs`.
  MultiAddr get listenAddr => bleAddr(_token);

  @override
  List<String> get protocols => const ['/$bleProtocolName'];

  @override
  bool canDial(MultiAddr addr) {
    if (!isBleAddr(addr)) return false;
    final t = tokenOf(addr);
    return t != null && isValidToken(t) && t != _token;
  }

  @override
  bool canListen(MultiAddr addr) {
    final t = isBleAddr(addr) ? tokenOf(addr) : null;
    return t != null && isValidToken(t);
  }

  @override
  Future<Conn> dial(MultiAddr addr, {Duration? timeout, bool simultaneousConnect = false}) async {
    if (!canDial(addr)) throw ArgumentError('BleTransport cannot dial $addr');
    final token = tokenOf(addr)!;
    final p2p = addr.peerId;
    final link = await radio.connect(token, timeout: timeout ?? config.dialTimeout);
    _log.fine('dialed $token (link ${link.remoteId})');
    return BleConn(
      link: link,
      localPeer: localPeer,
      remotePeer: p2p == null ? null : PeerId.fromString(p2p),
      localAddr: listenAddr,
      remoteAddr: bleAddr(token),
    );
  }

  @override
  Future<Listener> listen(MultiAddr addr) async {
    if (!canListen(addr)) throw ArgumentError('BleTransport cannot listen on $addr');
    if (_listener != null && !_listener!.isClosed) {
      throw StateError('BleTransport already listens on ${_listener!.addr}');
    }
    _token = tokenOf(addr)!;
    final listener = BleListener._(this, listenAddr);
    await radio.startAdvertising(_token, localPeer.toBytes());
    _listener = listener;
    _log.fine('listening on $listenAddr');
    return listener;
  }

  @override
  Future<void> dispose() async {
    await _listener?.close();
    await radio.dispose();
  }
}

/// Accepts the links that nearby centrals open, as [BleConn]s.
class BleListener implements Listener {
  final BleTransport _transport;
  final MultiAddr _addr;
  final _controller = StreamController<TransportConn>.broadcast();
  late final StreamSubscription<BleLink> _incomingSub;
  bool _closed = false;

  BleListener._(this._transport, this._addr) {
    _incomingSub = _transport.radio.incoming.listen(_onLink);
  }

  void _onLink(BleLink link) {
    if (_closed) {
      unawaited(link.close());
      return;
    }
    final conn = BleConn(
      link: link,
      localPeer: _transport.localPeer,
      localAddr: _addr,
      remoteAddr: bleAddr(_remoteToken(link.remoteId)),
    );
    _log.fine('accepted ${link.remoteId}');
    _controller.add(conn);
  }

  // The central's token is not known on this side; the address uses a
  // value made from its platform ID. It is not dialable.
  static String _remoteToken(String remoteId) {
    final clean = remoteId.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');
    return clean.isEmpty ? 'central' : 'c${clean.length > 12 ? clean.substring(0, 12) : clean}';
  }

  @override
  MultiAddr get addr => _addr;

  @override
  Future<TransportConn?> accept() async {
    if (_closed) return null;
    try {
      return await _controller.stream.first;
    } on StateError {
      return null; // closed while waiting
    }
  }

  @override
  bool get isClosed => _closed;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _incomingSub.cancel();
    await _transport.radio.stopAdvertising();
    await _controller.close();
  }

  @override
  Stream<TransportConn> get connectionStream => _controller.stream;

  @override
  bool supportsAddr(MultiAddr addr) => _transport.canListen(addr);
}
