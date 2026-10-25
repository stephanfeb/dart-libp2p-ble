import 'package:dart_libp2p/core/network/network.dart';
import 'package:dart_libp2p/p2p/protocol/ping/ping.dart';
import 'package:dart_libp2p_ble/testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/hosts.dart';

void main() {
  group('libp2p over BLE (fake radio)', () {
    test('two hosts connect, upgrade with Noise and yamux, and ping', () async {
      final net = FakeBleNetwork(maxValueLength: 182);
      final (a, _, _) = await newBleHost(net);
      final (b, bBle, _) = await newBleHost(net);
      addTearDown(() async {
        await a.close();
        await b.close();
      });

      await connectBle(a, b, bBle);
      expect(a.network.connectedness(b.id), equals(Connectedness.connected));

      final conn = a.network.connsToPeer(b.id).single;
      expect(conn.state.security, contains('noise'));
      expect(conn.state.streamMultiplexer, contains('yamux'));

      final result = await PingService(a).ping(b.id).first.timeout(const Duration(seconds: 10));
      expect(result.hasError, isFalse, reason: '${result.error}');
    });

    test('works with 20-byte GATT values and latency on every value', () async {
      // 20 bytes is the payload of the default 23-byte ATT MTU.
      final net = FakeBleNetwork(maxValueLength: 20, latency: const Duration(milliseconds: 5));
      final (a, _, _) = await newBleHost(net);
      final (b, bBle, _) = await newBleHost(net);
      addTearDown(() async {
        await a.close();
        await b.close();
      });

      await connectBle(a, b, bBle);
      final result = await PingService(a).ping(b.id).first.timeout(const Duration(seconds: 60));
      expect(result.hasError, isFalse, reason: '${result.error}');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('identify tells the dialed peer the dialer\'s /ble listen address', () async {
      final net = FakeBleNetwork();
      final (a, aBle, _) = await newBleHost(net);
      final (b, bBle, _) = await newBleHost(net);
      addTearDown(() async {
        await a.close();
        await b.close();
      });

      await connectBle(a, b, bBle);
      // Identify runs after the connection is up.
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (DateTime.now().isBefore(deadline)) {
        final addrs = await b.peerStore.addrBook.addrs(a.id);
        if (addrs.any((x) => x.toString() == aBle.listenAddr.toString())) return;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      fail('b never learned ${aBle.listenAddr} for a');
    });
  });
}
