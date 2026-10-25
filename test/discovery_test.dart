import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/crypto/ed25519.dart';
import 'package:dart_libp2p/core/network/network.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p_ble/dart_libp2p_ble.dart';
import 'package:dart_libp2p_ble/testing.dart';
import 'package:dart_libp2p_pubsub/dart_libp2p_pubsub.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/hosts.dart';

BleDiscovery _discovery(Host h, BleTransport t,
        {int maxLinks = 4, int? minRssi, int? swapMargin, Duration retryAfter = const Duration(seconds: 30)}) =>
    BleDiscovery(
      host: h,
      transport: t,
      yieldFor: const Duration(seconds: 1),
      recheckEvery: const Duration(milliseconds: 200),
      maxLinks: maxLinks,
      minRssi: minRssi,
      swapMargin: swapMargin,
      minLinkAge: Duration.zero,
      retryAfter: retryAfter,
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

    test('a device that copies another peer ID is not reported as that peer', () async {
      final net = FakeBleNetwork();
      final victim = PeerId.fromPublicKey((await generateEd25519KeyPair()).publicKey);
      // The impostor publishes the victim's peer ID; Noise proves its own.
      final (impostor, _, _) = await newBleHost(net, token: 'zzzzzz', claimedPeer: victim);
      final (dialer, dialerBle, _) = await newBleHost(net, token: 'aaaaaa');
      final d = _discovery(dialer, dialerBle);
      final found = <PeerId>[];
      d.peerFound.listen(found.add);
      addTearDown(() async {
        await d.dispose();
        await impostor.close();
        await dialer.close();
      });
      await d.start();

      // Give discovery time to see the impostor and dial it.
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(found, isNot(contains(victim)));
      expect(dialer.network.connectedness(victim), equals(Connectedness.notConnected));
      expect(d.knownTokens['zzzzzz'], isNot(equals(victim)));
    }, timeout: const Timeout(Duration(minutes: 1)));

    test('a device heard below minRssi is not dialed', () async {
      final net = FakeBleNetwork();
      final (me, meBle, meRadio) = await newBleHost(net, token: 'aaaaaa');
      final (far, _, farRadio) = await newBleHost(net, token: 'bbbbbb');
      final (near, _, _) = await newBleHost(net, token: 'cccccc');
      net.setRssi(meRadio, farRadio, -95);
      final d = _discovery(me, meBle, minRssi: -85);
      addTearDown(() async {
        await d.dispose();
        for (final h in [me, far, near]) {
          await h.close();
        }
      });
      await d.start();
      await _until(() => me.network.connectedness(near.id) == Connectedness.connected);
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(me.network.connectedness(far.id), equals(Connectedness.notConnected));
    }, timeout: const Timeout(Duration(minutes: 1)));

    test('inbound connections past maxLinks are closed, newest first', () async {
      final net = FakeBleNetwork();
      // 'zzzzzz' has the highest token, so the others dial it.
      final (hub, hubBle, _) = await newBleHost(net, token: 'zzzzzz');
      final others = [
        for (final t in ['aaaaaa', 'bbbbbb', 'cccccc', 'dddddd']) await newBleHost(net, token: t)
      ];
      final hubD = _discovery(hub, hubBle, maxLinks: 2);
      final ds = [for (final (h, t, _) in others) _discovery(h, t, retryAfter: const Duration(seconds: 1))];
      addTearDown(() async {
        for (final d in [hubD, ...ds]) {
          await d.dispose();
        }
        for (final h in [hub, for (final (h, _, _) in others) h]) {
          await h.close();
        }
      });
      await hubD.start();
      // The first two dial in, then the other two.
      await ds[0].start();
      await ds[1].start();
      await _until(() => hubD.bleConnections == 2);
      final first = {others[0].$1.id, others[1].$1.id};
      await ds[2].start();
      await ds[3].start();

      // The late ones keep dialing (retryAfter 1 s); the hub stays at 2 and
      // keeps its first links.
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        await _until(() => hubD.bleConnections <= 2, within: const Duration(seconds: 2));
      }
      await _until(() => hubD.bleConnections == 2);
      expect(first.every((p) => hub.network.connectedness(p) == Connectedness.connected), isTrue);
    }, timeout: const Timeout(Duration(minutes: 1)));

    test('a full node swaps its weakest link for a much stronger device', () async {
      final net = FakeBleNetwork();
      final (me, meBle, meRadio) = await newBleHost(net, token: 'aaaaaa');
      final (weak, _, weakRadio) = await newBleHost(net, token: 'bbbbbb');
      final (strong, _, strongRadio) = await newBleHost(net, token: 'cccccc');
      net
        ..setRssi(meRadio, weakRadio, -85)
        ..setInRange(meRadio, strongRadio, false);
      final d = _discovery(me, meBle, maxLinks: 1, swapMargin: 15);
      addTearDown(() async {
        await d.dispose();
        for (final h in [me, weak, strong]) {
          await h.close();
        }
      });
      await d.start();
      await _until(() => me.network.connectedness(weak.id) == Connectedness.connected);

      // 'cccccc' comes in range 10 dB stronger: not enough.
      net
        ..setRssi(meRadio, strongRadio, -75)
        ..setInRange(meRadio, strongRadio, true);
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(me.network.connectedness(weak.id), equals(Connectedness.connected));
      expect(me.network.connectedness(strong.id), equals(Connectedness.notConnected));

      // 30 dB stronger: it replaces the weak link.
      net.setRssi(meRadio, strongRadio, -55);
      await _until(() =>
          me.network.connectedness(strong.id) == Connectedness.connected &&
          me.network.connectedness(weak.id) != Connectedness.connected);
      expect(d.bleConnections, equals(1));
    }, timeout: const Timeout(Duration(minutes: 1)));
  });
}
