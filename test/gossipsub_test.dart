import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p_ble/testing.dart';
import 'package:dart_libp2p_pubsub/dart_libp2p_pubsub.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/hosts.dart';

const topic = '/ble-chat/test';

/// Publishes from [pub] until [sub] receives a message from [from], or fails
/// after [within]. Gossipsub builds its mesh on heartbeats, so the first
/// publishes can go nowhere.
Future<String> deliver(PubSub pub, Host from, Subscription sub, {Duration within = const Duration(seconds: 30)}) async {
  final got = sub.stream
      .cast<dynamic>()
      .where((m) => m.from == from.id)
      .map((m) => utf8.decode(m.data as List<int>))
      .first;
  var n = 0;
  final timer = Timer.periodic(const Duration(milliseconds: 500), (_) {
    pub.publish(topic, Uint8List.fromList(utf8.encode('hello ${n++}')));
  });
  try {
    return await got.timeout(within);
  } finally {
    timer.cancel();
  }
}

void main() {
  group('gossipsub over BLE (fake radio)', () {
    test('a message crosses a partial mesh A-B-C where A and C are out of range', () async {
      final net = FakeBleNetwork(maxValueLength: 182);
      final (a, _, ra) = await newBleHost(net);
      final (b, bBle, _) = await newBleHost(net);
      final (c, cBle, rc) = await newBleHost(net);
      net.setInRange(ra, rc, false);

      final pubsubs = <PubSub>[];
      for (final h in [a, b, c]) {
        final ps = PubSub(h, GossipSubRouter());
        await ps.start();
        pubsubs.add(ps);
      }
      addTearDown(() async {
        for (final ps in pubsubs) {
          await ps.stop();
        }
        for (final h in [a, b, c]) {
          await h.close();
        }
      });
      final [pa, pb, pc] = pubsubs;
      final subA = pa.subscribe(topic);
      pb.subscribe(topic);
      final subC = pc.subscribe(topic);

      await connectBle(a, b, bBle);
      await connectBle(c, b, bBle);
      // A cannot reach C directly.
      await expectLater(connectBle(a, c, cBle), throwsA(anything));

      expect(await deliver(pa, a, subC), startsWith('hello'));
      expect(await deliver(pc, c, subA), startsWith('hello'));
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
