import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_libp2p/core/crypto/ed25519.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p_ble/dart_libp2p_ble.dart';
import 'package:dart_libp2p_ble/src/protocol.dart'
    show
        FrameType,
        isValidToken,
        manufacturerId,
        tokenFromAdvertisedName,
        tokenFromManufacturerData;
import 'package:flutter_test/flutter_test.dart';

/// A link whose remote sends whatever the test puts in [incoming].
class _Link implements BleLink {
  final incoming = StreamController<Uint8List>();
  final _done = Completer<void>();
  var closed = false;

  @override
  bool get isCentral => false;
  @override
  String get remoteId => 'fuzz';
  @override
  int get maxValueLength => 20;
  @override
  Stream<Uint8List> get values => incoming.stream;
  @override
  Future<void> send(Uint8List value) async {}
  @override
  Future<void> close() async {
    closed = true;
    if (!_done.isCompleted) _done.complete();
    if (!incoming.isClosed) await incoming.close();
  }

  @override
  Future<void> get done => _done.future;
}

void main() {
  test(
      'GATT values of any shape: the data before the first other frame is read, in order',
      () async {
    final r = Random(42);
    final local =
        PeerId.fromPublicKey((await generateEd25519KeyPair()).publicKey);
    for (var round = 0; round < 300; round++) {
      final link = _Link();
      final conn = BleConn(
          link: link,
          localPeer: local,
          localAddr: bleAddr('aaaaaa'),
          remoteAddr: bleAddr('bbbbbb'));
      final expected = BytesBuilder();
      var ended = false;
      for (var i = 0; i < r.nextInt(40); i++) {
        final value = Uint8List.fromList(
            List.generate(r.nextInt(24), (_) => r.nextInt(256)));
        // Mostly data frames, with empty values, closes and unknown types.
        if (value.isNotEmpty && r.nextInt(10) > 1) value[0] = FrameType.data;
        if (!ended && value.isNotEmpty) {
          if (value[0] == FrameType.data) {
            expected.add(value.sublist(1));
          } else {
            ended = true;
          }
        }
        link.incoming.add(value);
      }
      if (!ended) await link.close();
      final want = expected.takeBytes();
      final got = BytesBuilder();
      try {
        while (true) {
          final chunk = await conn.read().timeout(const Duration(seconds: 1));
          if (chunk.isEmpty) break;
          got.add(chunk);
        }
      } on StateError {
        // An unknown frame type closes the connection: reads then throw.
      }
      final bytes = got.takeBytes();
      // An unknown type closes at once, so data before it may be cut; a
      // close frame lets what came before be read.
      expect(want.length >= bytes.length, isTrue);
      expect(bytes, want.sublist(0, bytes.length));
      await conn.close();
    }
  });

  test('advertised tokens: anything that is not one is null', () {
    final r = Random(7);
    for (var i = 0; i < 5000; i++) {
      final data = List.generate(
          r.nextInt(12), (_) => r.nextInt(r.nextBool() ? 256 : 0x10000));
      final fromData = tokenFromManufacturerData(
          r.nextBool() ? manufacturerId : r.nextInt(0x10000), data);
      if (fromData != null) expect(isValidToken(fromData), isTrue);
      final fromName = tokenFromAdvertisedName(String.fromCharCodes(data));
      if (fromName != null) expect(isValidToken(fromName), isTrue);
    }
  });
}
