# Discovery

`BleDiscovery` connects a node to the nodes in range. Every node advertises
(when its host listens on `/ble`) and scans (when discovery starts).

```dart
final discovery = BleDiscovery(host: host, transport: ble);
await discovery.start();
```

## Who dials

When a node sees another node's token, it:

1. Reads the other node's peer ID from its identity characteristic.
2. Adds `/ble/<token>` to the peerstore for that peer.
3. Connects with `host.connect`. Noise then proves the peer ID.

If both nodes dialed at the same time, a pair would get two links. To stop
that, **the node with the lower token dials**. The node with the higher token
waits, and dials only if no connection came after `yieldFor` (8 seconds), in
case the other node cannot hear it.

A node keeps at most `maxLinks` BLE connections (4). Phones can hold only a
few BLE links at a time, and each link shares the same radio time. In a room
with more nodes, each node connects to some of them, and the protocols on
top relay across the partial mesh.

## A mesh

Gossipsub works on the links as they are. Start a `PubSub` on each host and
subscribe to a topic: a message reaches every node that is connected
through other nodes, also nodes out of range of the sender.

<!-- example: example/mesh_in_memory.dart#chat -->
```dart
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
```
<!-- /example -->

This example runs on in-memory radios: [Testing without Bluetooth](testing.md)
shows the rest of it.

## Settings

| Parameter | Default | What it does |
|---|---|---|
| `maxLinks` | 4 | Most BLE connections this node opens. |
| `yieldFor` | 8 s | How long the higher token waits for the lower one to dial. |
| `retryAfter` | 30 s | How long to wait before trying a token again after a dial fails. |
| `addrTtl` | 10 min | How long a learned `/ble` address stays in the peerstore. |
| `recheckEvery` | 3 s | How often the tokens seen so far are looked at again. |

`recheckEvery` exists because iOS reports a device only once per scan. A
node that waits (`yieldFor`) or backs off (`retryAfter`) cannot count on a
new sighting to try again, so it looks at the tokens it knows on a timer.

## What discovery tells you

- `peerFound`: each peer that this node connected to, once.
- `knownTokens`: the peer ID of each token seen so far.
- `bleConnections`: the number of open BLE connections.

Connections that another node dialed do not show in `peerFound`. To see all
peers, watch the host's network.

## Limits

- **Inbound links do not count against `maxLinks`.** A node opens at most
  `maxLinks` links, but it accepts every node that dials it.
- **Tokens change on restart.** A token means something only to devices
  nearby, and only while the node runs. To find a known peer again, use its
  peer ID, not its token.
- **Discovery is open.** Any device in range can read your peer ID and
  connect. Noise proves who the peer is, but not that you met them: to know
  that, compare something in person (a QR code, or a short code on both
  screens).
