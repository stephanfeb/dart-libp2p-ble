# dart_libp2p_ble

Bluetooth LE transport (`/ble`) for [dart-libp2p](https://github.com/stephanfeb/dart-libp2p):
phones and Macs nearby connect without a network. Each connection is one GATT
link; libp2p secures it with Noise and multiplexes it with yamux, as on TCP.

Status: in development (dart-libp2p-zc4). Tested in memory (`FakeBleNetwork`);
device tests run with the app in `spike/`.

```dart
final ble = BleTransport(radio: BluetoothLowEnergyRadio(), localPeer: peerId);
final host = await Libp2p.new_([
  Libp2p.identity(keyPair),
  Libp2p.transport(ble),
  Libp2p.listenAddrs([ble.listenAddr]), // /ble/<token>
]);
await host.start();
final discovery = BleDiscovery(host: host, transport: ble);
await discovery.start(); // scans, and connects to nearby nodes
```

## How it works

- **Service**: one GATT service with RX (central writes), TX (peripheral
  notifies) and an identity characteristic (the peer ID, read before dialing;
  Noise then proves it).
- **Advertising**: the service UUID and a 6-character token. iOS and macOS
  put the token in the local name (`p2<token>`); Android puts it in
  manufacturer data (company ID 0xFFFF, for tests), because the plugin can
  only set a name by renaming the phone.
- **Addresses**: `/ble/<token>`. A token is new each time the node starts;
  it means something only to devices nearby. Devices are found by token,
  never by platform peripheral ID, which changes.
- **Framing**: each GATT value starts with a type byte (data, close). The
  close frame exists because an iOS peripheral cannot disconnect a central.
- **Discovery**: every node scans and advertises; the lower token dials, the
  higher one dials after 8 s if no connection came. At most 4 links per node;
  gossipsub relays across the partial mesh.

## Tests

```
flutter test
```
