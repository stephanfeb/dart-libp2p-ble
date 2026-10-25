import 'dart:async';
import 'dart:io' show Socket;
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_libp2p/core/crypto/keys.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/common.dart';
import 'package:dart_libp2p/core/network/conn.dart';
import 'package:dart_libp2p/core/network/context.dart';
import 'package:dart_libp2p/core/network/mux.dart' show PushbackStream;
import 'package:dart_libp2p/core/network/rcmgr.dart';
import 'package:dart_libp2p/core/network/stream.dart';
import 'package:dart_libp2p/core/network/transport_conn.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:logging/logging.dart';

import 'protocol.dart';
import 'radio.dart';

final _log = Logger('BleConn');

/// A raw libp2p connection over one [BleLink]: a byte stream that the
/// upgrader secures with Noise and multiplexes with yamux.
///
/// Every GATT value starts with a [FrameType] byte. Data values carry the
/// connection bytes in order; a close value ends the connection.
class BleConn implements TransportConn, PushbackStream {
  final BleLink _link;
  final PeerId _localPeer;
  final PeerId? _remotePeer;
  final MultiAddr _localAddr;
  final MultiAddr _remoteAddr;
  final String _id;
  final _BleConnStats _stats;

  final _buffer = BytesBuilder(copy: false);
  Completer<void>? _readWaiter;
  bool _remoteDone = false;
  bool _closed = false;
  Future<void> _writeTail = Future.value();
  Duration? _readTimeout;
  Duration? _writeTimeout;
  late final StreamSubscription<Uint8List> _valuesSub;

  static int _nextId = 0;

  BleConn({
    required BleLink link,
    required PeerId localPeer,
    PeerId? remotePeer,
    required MultiAddr localAddr,
    required MultiAddr remoteAddr,
  })  : _link = link,
        _localPeer = localPeer,
        _remotePeer = remotePeer,
        _localAddr = localAddr,
        _remoteAddr = remoteAddr,
        _id = 'ble-${_nextId++}',
        _stats = _BleConnStats(Stats(
          direction: link.isCentral ? Direction.outbound : Direction.inbound,
          opened: DateTime.now(),
        )) {
    _valuesSub = _link.values.listen(_onValue, onDone: _onLinkDone, onError: (Object e) {
      _log.fine('$_id link error: $e');
      _onLinkDone();
    });
  }

  void _onValue(Uint8List value) {
    if (value.isEmpty) return;
    switch (value[0]) {
      case FrameType.data:
        if (value.length > 1) {
          _buffer.add(Uint8List.sublistView(value, 1));
          _wakeReader();
        }
      case FrameType.close:
        _log.fine('$_id remote closed');
        _onLinkDone();
        // The central ends the GATT connection, so the peripheral's link
        // goes too.
        unawaited(_link.close());
      default:
        _log.warning('$_id unknown frame type ${value[0]}; closing');
        unawaited(close());
    }
  }

  void _onLinkDone() {
    if (_remoteDone) return;
    _remoteDone = true;
    _wakeReader();
  }

  void _wakeReader() {
    final w = _readWaiter;
    if (w != null && !w.isCompleted) w.complete();
  }

  // -- TransportConn ---------------------------------------------------------

  /// Reads exactly [length] bytes, or whatever is buffered if [length] is
  /// null. At end of stream it returns the bytes that are left, then an empty
  /// list. After [close] it throws [StateError].
  @override
  Future<Uint8List> read([int? length]) async {
    if (length != null && length < 0) throw ArgumentError('length cannot be negative');
    if (length == 0) return Uint8List(0);
    while (true) {
      if (_closed) throw StateError('Connection closed.');
      final available = _buffer.length;
      if (length == null ? available > 0 : available >= length) return _take(length ?? available);
      if (_remoteDone) return _take(length == null ? available : min(length, available));

      final waiter = _readWaiter = Completer<void>();
      final timeout = _readTimeout;
      if (timeout != null && timeout > Duration.zero) {
        await waiter.future.timeout(timeout,
            onTimeout: () => throw TimeoutException('BLE read timed out after $timeout'));
      } else {
        await waiter.future;
      }
    }
  }

  Uint8List _take(int n) {
    final all = _buffer.takeBytes();
    if (n < all.length) _buffer.add(Uint8List.sublistView(all, n));
    return n == all.length ? all : Uint8List.fromList(Uint8List.sublistView(all, 0, n));
  }

  /// Puts [data] back in front of the read buffer (bytes that
  /// multistream-select read past its negotiation).
  @override
  void pushData(Uint8List data) {
    if (data.isEmpty) return;
    final rest = _buffer.takeBytes();
    _buffer
      ..add(data)
      ..add(rest);
    _wakeReader();
  }

  @override
  Future<void> write(Uint8List data) {
    if (_closed) return Future.error(StateError('Connection closed.'));
    if (_remoteDone) return Future.error(StateError('BLE link is closed.'));
    if (data.isEmpty) return Future.value();
    final done = _writeTail.then((_) => _send(data));
    // A failed write must not block the ones after it.
    _writeTail = done.catchError((_) {});
    return done;
  }

  Future<void> _send(Uint8List data) async {
    final chunk = _link.maxValueLength - 1;
    for (var i = 0; i < data.length; i += chunk) {
      final end = min(i + chunk, data.length);
      final value = Uint8List(1 + end - i)
        ..[0] = FrameType.data
        ..setRange(1, 1 + end - i, data, i);
      final sent = _link.send(value);
      final timeout = _writeTimeout;
      await (timeout != null && timeout > Duration.zero
          ? sent.timeout(timeout, onTimeout: () => throw TimeoutException('BLE write timed out after $timeout'))
          : sent);
    }
  }

  @override
  Socket get socket => throw UnsupportedError('A BLE connection has no socket');

  @override
  void setReadTimeout(Duration timeout) => _readTimeout = timeout;

  @override
  void setWriteTimeout(Duration timeout) => _writeTimeout = timeout;

  @override
  void notifyActivity() {}

  // -- Conn ------------------------------------------------------------------

  /// Sends a close value after the pending writes, then ends the link.
  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _wakeReader();
    if (!_remoteDone) {
      try {
        await _writeTail.timeout(const Duration(seconds: 2));
        await _link.send(Uint8List.fromList([FrameType.close])).timeout(const Duration(seconds: 2));
      } catch (e) {
        _log.fine('$_id close frame not sent: $e');
      }
    }
    await _valuesSub.cancel();
    await _link.close();
  }

  @override
  String get id => _id;

  @override
  bool get isClosed => _closed || _remoteDone;

  @override
  PeerId get localPeer => _localPeer;

  @override
  PeerId get remotePeer =>
      _remotePeer ?? (throw StateError('Remote PeerId not yet established for this raw connection.'));

  @override
  Future<PublicKey?> get remotePublicKey async => _remotePeer?.extractPublicKey();

  @override
  MultiAddr get localMultiaddr => _localAddr;

  @override
  MultiAddr get remoteMultiaddr => _remoteAddr;

  @override
  ConnState get state => const ConnState(
        streamMultiplexer: '',
        security: '',
        transport: bleProtocolName,
        usedEarlyMuxerNegotiation: false,
      );

  @override
  ConnStats get stat => _stats;

  @override
  ConnScope get scope => NullScope();

  @override
  Future<P2PStream> newStream(Context context) =>
      throw UnsupportedError('A raw BLE connection has no streams; upgrade it first');

  @override
  Future<List<P2PStream>> get streams => Future.value(const []);

  @override
  String toString() => 'BleConn($_id, $_remoteAddr)';
}

class _BleConnStats implements ConnStats {
  @override
  final Stats stats;

  _BleConnStats(this.stats);

  @override
  int get numStreams => 0;
}
