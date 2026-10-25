import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/network/network.dart';
import 'package:dart_libp2p_ble/dart_libp2p_ble.dart';
import 'package:dart_libp2p_ble/testing.dart';
import 'package:dart_libp2p_pubsub/dart_libp2p_pubsub.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/hosts.dart';

BleDiscovery _discovery(Host h, BleTransport t) => BleDiscovery(
      host: h,
      transport: t,
      yieldFor: const Duration(seconds: 1),
      recheckEvery: const Duration(milliseconds: 200),
    );

Future<void> _until(bool Function() ok, {Duration within = const Duration(seconds: 20)}) async {
  final deadline = DateTime.now().add(within);
  while (!ok()) {
    if (DateTime.now().isAfter(deadline)) fail('condition not met within $within');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

void main() {
  group('BleDiscovery (fake radio)', () {
    test('nodes in a room connect once per pair and gossip reaches all of them', () async {
      final net = FakeBleNetwork();
      final nodes = [for (var i = 0; i < 4; i++) await newBleHost(net)];
      final discoveries = [for (final (h, t, _) in nodes) _discovery(h, t)];
      final pubsubs = <PubSub>[];
      for (final (h, _, _) in nodes) {
        final ps = PubSub(h, GossipSubRouter());
        await ps.start();
        pubsubs.add(ps);
      }
      addTearDown(() async {
        for (final d in discoveries) {
          await d.dispose();
        }
        for (final ps in pubsubs) {
          await ps.stop();
        }
        for (final (h, _, _) in nodes) {
          await h.close();
        }
      });
      final subs = [for (final ps in pubsubs) ps.subscribe('/room')];
      for (final d in discoveries) {
        await d.start();
      }

      // Everyone ends up connected to everyone (4 nodes, maxLinks 4).
      await _until(() => nodes.every((n) =>
          nodes.where((m) => m != n).every((m) => n.$1.network.connectedness(m.$1.id) == Connectedness.connected)));
      // No pair has two connections.
      for (final (h, _, _) in nodes) {
        for (final (o, _, _) in nodes) {
          if (o != h) expect(h.network.connsToPeer(o.id).length, equals(1), reason: 'duplicate links');
        }
      }

      // A message from node 0 reaches the other three.
      final got = [
        for (final s in subs.skip(1))
          s.stream.cast<dynamic>().map((m) => utf8.decode(m.data as List<int>)).firstWhere((t) => t == 'hi all')
      ];
      final timer = Timer.periodic(const Duration(milliseconds: 500),
          (_) => pubsubs[0].publish('/room', Uint8List.fromList(utf8.encode('hi all'))));
      try {
        await Future.wait(got).timeout(const Duration(seconds: 30));
      } finally {
        timer.cancel();
      }
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('the higher token dials when the lower one does not', () async {
      final net = FakeBleNetwork();
      final (low, _, _) = await newBleHost(net, token: 'aaaaaa');
      final (high, highBle, _) = await newBleHost(net, token: 'zzzzzz');
      final d = _discovery(high, highBle); // 'aaaaaa' runs no discovery
      addTearDown(() async {
        await d.dispose();
        await low.close();
        await high.close();
      });
      await d.start();
      await _until(() => high.network.connectedness(low.id) == Connectedness.connected);
      expect(d.knownTokens['aaaaaa'], equals(low.id));
    }, timeout: const Timeout(Duration(minutes: 1)));
  });
}
