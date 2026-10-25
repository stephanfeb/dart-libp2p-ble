# Testing without Bluetooth

Real radios are slow to test with: you need devices, and they must be near
each other. `package:dart_libp2p_ble/testing.dart` gives **in-memory radios**
that behave as BLE links do, so you can test your protocol, or a whole mesh,
in `flutter test`.

```dart
import 'package:dart_libp2p_ble/testing.dart';
```

## A network of radios

A `FakeBleNetwork` holds the radios. Every pair is in range unless you say
otherwise, so you can build a partial mesh:

<!-- example: example/mesh_in_memory.dart#network -->
```dart
final network = FakeBleNetwork();
final radioA = network.newRadio();
final radioB = network.newRadio();
final radioC = network.newRadio();
network.setInRange(radioA, radioC, false); // A and C cannot hear each other
```
<!-- /example -->

Give each radio to a `BleTransport` in place of `BluetoothLowEnergyRadio`.
Everything above the radio is the real code: the transport, Noise, yamux,
discovery and your protocols.

<!-- example: example/mesh_in_memory.dart#node -->
```dart
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
```
<!-- /example -->

A shorter `yieldFor` makes the test faster. On devices, keep the default.

The whole program is [`example/mesh_in_memory.dart`](../example/mesh_in_memory.dart):
A sends a message on gossipsub, and C gets it through B.

```sh
flutter test test/examples_test.dart
```

## What you can control

| Setting | Default | What it does |
|---|---|---|
| `FakeBleNetwork(maxValueLength:)` | 512 | Largest GATT value. Set 20 or 182 to test small MTUs: connections split their writes into more values. |
| `FakeBleNetwork(latency:)` | none | Delay of each value. Values stay in order. |
| `setInRange(a, b, false)` | in range | `a` and `b` do not see each other and cannot connect. Links that are open stay open. |
| `radio.openLinks` | | Number of links a radio has open, in both roles. |

## What it does not cover

The in-memory radios have no platform behavior: no permissions, no
advertising limits, no changing peripheral IDs, and no lost links. Test on
devices too before you ship; [Platforms](platforms.md) lists what is
different on each.
