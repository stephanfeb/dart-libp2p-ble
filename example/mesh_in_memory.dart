// Three nodes in a line, A - B - C, chat over gossipsub without Bluetooth.
//
// A and C are out of range of each other, so A's message reaches C through
// B. The radios are in memory (package:dart_libp2p_ble/testing.dart); the
// rest of the stack (Noise, yamux, gossipsub, BleDiscovery) is the real one.
// test/examples_test.dart runs this program.

// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_libp2p/config/config.dart';
import 'package:dart_libp2p/core/crypto/ed25519.dart';
import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p_ble/dart_libp2p_ble.dart';
import 'package:dart_libp2p_ble/testing.dart';
import 'package:dart_libp2p_pubsub/dart_libp2p_pubsub.dart';

const _topic = '/chat/1';

// #region node
/// A node on [radio]: a host with only the BLE transport, gossipsub, and
/// discovery that connects to the nodes in range.
Future<(Host, PubSub, BleDiscovery)> _node(BleRadio radio) async {
  final keyPair = await generateEd25519KeyPair();
  final peerId = PeerId.fromPublicKey(keyPair.publicKey);
  final ble = BleTransport(radio: radio, localPeer: peerId);
  final host = await Libp2p.new_([
    Libp2p.identity(keyPair),
    Libp2p.transport(ble),
    Libp2p.listenAddrs([ble.listenAddr]),
    Libp2p.autoNAT(false),
    Libp2p.relay(false),
    Libp2p.autoRelay(false),
    Libp2p.holePunching(false),
  ]);
  await host.start();
  final pubsub = PubSub(host, GossipSubRouter());
  await pubsub.start();
  final discovery = BleDiscovery(host: host, transport: ble, yieldFor: const Duration(seconds: 1));
  return (host, pubsub, discovery);
}
// #endregion node

Future<void> main() async {
  // #region network
  final network = FakeBleNetwork();
  final radioA = network.newRadio();
  final radioB = network.newRadio();
  final radioC = network.newRadio();
  network.setInRange(radioA, radioC, false); // A and C cannot hear each other
  // #endregion network

  final nodes = [for (final r in [radioA, radioB, radioC]) await _node(r)];
  final [(_, a, _), (_, _, _), (_, c, _)] = nodes;

  // #region chat
  for (final (_, pubsub, _) in nodes) {
    pubsub.subscribe(_topic);
  }
  final atC = c.subscribe(_topic).stream.cast<PubSubMessage>().map((m) => utf8.decode(m.data)).first;
  for (final (_, _, discovery) in nodes) {
    await discovery.start();
  }

  // Gossipsub builds its mesh on heartbeats, so the first messages can go
  // nowhere: send until C has one.
  final sender = Timer.periodic(const Duration(milliseconds: 500), (_) {
    a.publish(_topic, Uint8List.fromList(utf8.encode('hello from A')));
  });
  print('C got: ${await atC.timeout(const Duration(seconds: 30))}');
  sender.cancel();
  // #endregion chat

  for (final (host, pubsub, discovery) in nodes) {
    await discovery.dispose();
    await pubsub.stop();
    await host.close();
  }
}
