# Changelog

## Unreleased

- `BleDiscovery` keeps its link budget for inbound connections too: when
  nodes dial in past `maxLinks`, it closes the newest inbound connections.
  After a connection to a token, it does not dial that token again for
  `retryAfter`.
- `BleDiscovery.minRssi`: devices heard weaker than this are not dialed.
- `BleDiscovery.swapMargin` and `minLinkAge` (off by default): a full node
  replaces its weakest link with a device that is that many dB stronger.
- Testing: `FakeBleNetwork.setRssi` sets the signal strength two radios hear
  each other at.
- Security: `BleDiscovery` no longer reports a peer it did not reach. The
  identity characteristic is not authenticated, so a device could publish
  another node's peer ID; with dart_libp2p before 4.11.0 the dial then
  succeeded to the impostor and `peerFound` named the copied peer. Discovery
  now checks that the dialed peer is connected, and forgets the token's
  peer ID otherwise.
- Docs: how to quiet the `bluetooth_low_energy` plugin's `INFO` logs (one
  line per advertisement and per GATT value) in `doc/platforms.md`; the
  example app does it.
- Guides in `doc/`: getting started, platforms, discovery, testing without
  Bluetooth, how it works. `example/mesh_in_memory.dart` (A - B - C gossip on
  in-memory radios), which the tests run; the doc samples come from the
  examples (`tool/embed_examples.dart`).

## 0.1.0 - 2026-10-25

First release. Needs dart_libp2p 4.10.0 or later.

- `BleTransport` and `BleListener`: the `/ble/<token>` transport. Each
  connection is one GATT link (RX write, TX notify); libp2p secures it with
  Noise and multiplexes it with yamux.
- `BleConn`: framing with a type byte (data, close), writes split to the
  link's largest value, TCP read semantics, and pushback of leftover bytes
  for the upgrader.
- `BluetoothLowEnergyRadio`: the radio on Android, iOS and macOS
  (bluetooth_low_energy 6.2). iOS and macOS advertise the token in the local
  name; Android advertises it in manufacturer data and does not rename the
  phone. Advertising is not restarted when a central connects.
- `BleDiscovery`: scans, reads the peer ID, and connects to nearby nodes
  (lower token dials first, at most 4 links). It looks at known tokens
  again periodically because iOS reports a device once per scan.
- `package:dart_libp2p_ble/testing.dart`: `FakeBleNetwork`, radios in memory
  with range control, to test meshes without Bluetooth.
- Tested on devices: Pixel 10a and iPhone, ping and gossipsub.

Known limits: the manufacturer data uses company ID 0xFFFF (reserved for
tests); inbound links do not count against `maxLinks`; writes use write with
response (about 5.7 KB/s each way).
