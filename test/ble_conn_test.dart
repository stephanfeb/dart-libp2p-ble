import 'dart:typed_data';

import 'package:dart_libp2p/core/crypto/ed25519.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p_ble/dart_libp2p_ble.dart';
import 'package:dart_libp2p_ble/testing.dart';
import 'package:flutter_test/flutter_test.dart';

Future<PeerId> _peer() async => PeerId.fromPublicKey((await generateEd25519KeyPair()).publicKey);

void main() {
  group('BleConn', () {
    late FakeBleNetwork net;
    late BleConn a; // central
    late BleConn b; // peripheral

    Future<void> open({int maxValueLength = 20}) async {
      net = FakeBleNetwork(maxValueLength: maxValueLength);
      final ra = net.newRadio();
      final rb = net.newRadio();
      await rb.startAdvertising('bbbbbb', Uint8List(0));
      final incoming = rb.incoming.first;
      final la = await ra.connect('bbbbbb');
      final lb = await incoming;
      final pa = await _peer();
      final pb = await _peer();
      a = BleConn(link: la, localPeer: pa, remotePeer: pb, localAddr: bleAddr('aaaaaa'), remoteAddr: bleAddr('bbbbbb'));
      b = BleConn(link: lb, localPeer: pb, localAddr: bleAddr('bbbbbb'), remoteAddr: bleAddr('aaaaaa'));
    }

    test('a write larger than one GATT value arrives whole and in order', () async {
      await open(maxValueLength: 20);
      final data = Uint8List.fromList(List.generate(1000, (i) => i & 0xff));
      await a.write(data);
      expect(await b.read(1000), equals(data));
    });

    test('read(n) waits for n bytes; read() returns what is buffered', () async {
      await open();
      final first = b.read(5);
      await a.write(Uint8List.fromList([1, 2, 3]));
      await a.write(Uint8List.fromList([4, 5, 6, 7]));
      expect(await first, equals([1, 2, 3, 4, 5]));
      expect(await b.read(), equals([6, 7]));
    });

    test('both directions work at once', () async {
      await open();
      await Future.wait([a.write(Uint8List.fromList([1])), b.write(Uint8List.fromList([2]))]);
      expect(await b.read(1), equals([1]));
      expect(await a.read(1), equals([2]));
    });

    test('pushData puts bytes in front of the buffer', () async {
      await open();
      await a.write(Uint8List.fromList([3, 4]));
      await Future<void>.delayed(Duration.zero);
      b.pushData(Uint8List.fromList([1, 2]));
      expect(await b.read(4), equals([1, 2, 3, 4]));
    });

    test('close from the peripheral side ends the stream at the central', () async {
      await open();
      await b.write(Uint8List.fromList([9]));
      await b.close();
      expect(await a.read(), equals([9]));
      expect(await a.read(), isEmpty); // end of stream
      expect(a.isClosed, isTrue);
    });

    test('a read after a local close throws StateError', () async {
      await open();
      await a.close();
      expect(() => a.read(), throwsStateError);
      expect(() => a.write(Uint8List(1)), throwsStateError);
    });

    test('a pending read wakes with end of stream when the remote closes', () async {
      await open();
      final pending = b.read(10);
      await a.close();
      expect(await pending, isEmpty);
    });

    test('the transport state tells the swarm to upgrade the connection', () async {
      await open();
      expect(a.state.security, isEmpty);
      expect(a.state.streamMultiplexer, isEmpty);
      expect(a.state.transport, equals('ble'));
    });
  });
}
