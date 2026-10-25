# How it works

This page follows a connection from the advertisement to the libp2p
upgrader. You do not need it to use the package; it helps when something
goes wrong.

## Addresses

A node listens on `/ble/<token>`. The token is 6 characters from a base32
alphabet (`a`-`z`, `2`-`7`), random each time the transport is made. It
means something only to devices nearby, and only while the node runs: it is
how a node finds a device in a scan, not a lasting name.

`/ble` is a multiaddr protocol in the multicodec private-use range (code
`0x300b1e`). dart_libp2p 4.10.0 knows it.

## Advertising

Each node advertises the libp2p BLE service UUID and its token:

| Platform | Token in | Why |
|---|---|---|
| iOS, macOS | The local name, `p2<token>` | iOS can advertise only a local name and service UUIDs. |
| Android | Manufacturer data, company ID `0xFFFF` | The plugin sets a name only by renaming the whole phone. |

A legacy advertisement has 31 bytes. With the 128-bit service UUID (18 bytes)
and the flags (3), 10 bytes are left: room for `p2` and the token in a name,
or for the manufacturer data.

`0xFFFF` is the company ID that the Bluetooth SIG reserves for tests. A later
version will use an assigned ID.

## The GATT service

| Characteristic | UUID | Properties | Carries |
|---|---|---|---|
| Service | `b1e5f00d-0000-4c1b-9d6e-5d1e0a9f2b01` | | |
| RX | `b1e5f00d-0001-…` | write | Bytes from the central to the peripheral |
| TX | `b1e5f00d-0002-…` | notify | Bytes from the peripheral to the central |
| Identity | `b1e5f00d-0003-…` | read | The peripheral's peer ID (multihash bytes) |

## A connection

The dialer is the central; the listener is the peripheral.

1. The central finds the token in a scan. If it saw the device before, it
   tries that peripheral for at most 4 seconds, then scans again: the device
   can have a new address.
2. It connects, discovers the service, and (on Android) asks for an MTU of
   517. The largest value is what the platform reports for write with
   response, at most 512 bytes.
3. Discovery reads the identity characteristic, so the dialer knows the peer
   ID before the handshake. The GATT connection stays open for 10 seconds,
   so the dial that follows uses it.
4. The central subscribes to TX notifications. That is the moment the
   peripheral accepts the connection.
5. The libp2p upgrader runs multistream-select, Noise and yamux on it, as on
   TCP. Noise proves the peer ID that the identity characteristic gave.

## Framing

Each GATT value starts with a type byte:

| Type | Byte | Rest of the value |
|---|---|---|
| Data | `0x00` | Connection bytes |
| Close | `0x01` | Nothing: the sender closed the connection |

A write is split into values of at most the largest value minus one byte.
Writes are sent one after the other, so bytes arrive in order. The close
frame is needed because an iOS peripheral cannot disconnect a central: the
central disconnects when it reads it.

`BleConn` reads as a TCP connection does: it returns empty bytes at the end
of the stream. It also takes back bytes that the upgrader read too far during
negotiation (`PushbackStream`, dart_libp2p 4.10.0), so the next layer gets
them.

## Speed

Measured between an iPhone and a Pixel 10a, with write with response and
512-byte values:

| | Result |
|---|---|
| Connect, discover and subscribe | about 4.9 s (median) |
| Round trip, 256 bytes | 93 ms |
| Round trip, 2 KB | 388 ms |
| Round trip, 8 KB | 1.4 s |
| Throughput | about 5.7 KB/s each way |

BLE is for messages, not files. Chat, presence and small records fit well;
for large transfers, connect over Wi-Fi when you can.

## Limits

- Writes use write with response. Write without response could be faster,
  but is not tested yet.
- The radio does not run in the background ([Platforms](platforms.md)).
- The manufacturer data uses the test company ID `0xFFFF`.
