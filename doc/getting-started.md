# Getting started

## Install

```sh
flutter pub add dart_libp2p_ble
```

The package needs Flutter 3.24 or later and dart_libp2p 4.10.0 or later.
It runs on Android, iOS and macOS. It is a Flutter package, because the
Bluetooth plugin is: a plain Dart program can use only the
[in-memory radios](testing.md).

Before the first run, add the Bluetooth permissions and usage descriptions
for each platform. [Platforms](platforms.md) lists them.

## A host on Bluetooth LE

Give the host a `BleTransport` and listen on its address. The transport
needs your peer ID, because it publishes it to nearby devices.

<!-- example: example/main.dart#host -->
```dart
final keyPair = await generateEd25519KeyPair();
final peerId = PeerId.fromPublicKey(keyPair.publicKey);
final ble = BleTransport(radio: BluetoothLowEnergyRadio(), localPeer: peerId);
final host = await Libp2p.new_([
  Libp2p.identity(keyPair),
  Libp2p.transport(ble),
  Libp2p.listenAddrs([ble.listenAddr]), // /ble/<token>
  // No IP network: turn off the NAT and relay services.
  Libp2p.autoNAT(false),
  Libp2p.relay(false),
  Libp2p.autoRelay(false),
  Libp2p.holePunching(false),
]);
await host.start();
print('listening on ${ble.listenAddr}');
```
<!-- /example -->

Three things matter here:

- **The listen address is `/ble/<token>`.** The token is 6 random
  characters, new each time the transport is made. Listening starts the GATT
  service and advertises the token.
- **The NAT and relay services are off.** They need an IP network. With only
  BLE, they have nothing to do.
- **BLE can be one of several transports.** Add TCP or UDX too, and the host
  uses BLE for `/ble` addresses and the others for IP addresses.

## Connect to nearby devices

`BleDiscovery` scans for other nodes and connects to them. `peerFound` tells
you about each new peer it connects to:

<!-- example: example/main.dart#discovery -->
```dart
final discovery = BleDiscovery(host: host, transport: ble);
discovery.peerFound.listen((peer) async {
  final result = await PingService(host).ping(peer).first;
  print('ping ${peer.toBase58()}: ${result.rtt?.inMilliseconds} ms');
});
await discovery.start();
```
<!-- /example -->

Run the app on two devices, near each other:

```
listening on /ble/k3vq7m
ping 12D3KooW…: <round trip> ms
```

`peerFound` only reports the peers that this node dialed. When the other
node dials first, watch the host's network instead (`host.network.peers`, or
the `EvtPeerConnectednessChanged` event).

## Without discovery

If you already know a nearby node's token and peer ID (from a QR code, say),
dial it as any other address:

```dart
await host.connect(AddrInfo(peerId, [MultiAddr('/ble/k3vq7m')]));
```

The device must be in range and advertising. The radio scans for the token
and connects.

## Next

- [Platforms](platforms.md): permissions, and what to expect on each platform.
- [Discovery](discovery.md): build a mesh, and tune when nodes dial.
