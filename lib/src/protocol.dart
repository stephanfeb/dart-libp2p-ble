import 'dart:math';

import 'package:dart_libp2p/core/multiaddr.dart';

/// The multiaddr protocol name of the BLE transport: `/ble/<token>`.
const bleProtocolName = 'ble';

/// GATT service of a libp2p BLE node.
const serviceUuid = 'b1e5f00d-0000-4c1b-9d6e-5d1e0a9f2b01';

/// Central to peripheral: the central writes connection bytes here.
const rxCharacteristicUuid = 'b1e5f00d-0001-4c1b-9d6e-5d1e0a9f2b01';

/// Peripheral to central: the peripheral notifies connection bytes here.
const txCharacteristicUuid = 'b1e5f00d-0002-4c1b-9d6e-5d1e0a9f2b01';

/// Read-only: the peripheral's peer ID (multihash bytes), so that a central
/// knows whom it dials before the Noise handshake proves it.
const identityCharacteristicUuid = 'b1e5f00d-0003-4c1b-9d6e-5d1e0a9f2b01';

/// Prefix of the advertised local name; the token follows it.
///
/// iOS and macOS can advertise only a local name and service UUIDs, so
/// there the token travels in the name. With the 128-bit service UUID, the
/// legacy advertisement leaves room for a name of 8 characters.
const advertisedNamePrefix = 'p2';

/// Company ID of the manufacturer data that carries the token on Android.
///
/// Android advertises only the phone's Bluetooth name (bluetooth_low_energy
/// sets a custom name by renaming the whole phone), so there the token goes
/// in manufacturer data: 3 (flags) + 18 (service UUID) + 10 = 31 bytes, the
/// legacy maximum. 0xFFFF is the ID that the Bluetooth SIG reserves for
/// tests; a published version needs an assigned company ID.
const manufacturerId = 0xFFFF;

/// Length of a token: 6 characters of [_tokenAlphabet] (30 bits).
const tokenLength = 6;

const _tokenAlphabet = 'abcdefghijklmnopqrstuvwxyz234567';

/// Makes a random token. A node uses a new token each time it starts, so
/// that the token does not track the device for long.
String newToken([Random? random]) {
  final r = random ?? Random.secure();
  return List.generate(tokenLength, (_) => _tokenAlphabet[r.nextInt(_tokenAlphabet.length)]).join();
}

/// True if [token] has the form that [newToken] makes.
bool isValidToken(String token) =>
    token.length == tokenLength && token.split('').every(_tokenAlphabet.contains);

/// The advertised local name for [token].
String advertisedName(String token) => '$advertisedNamePrefix$token';

/// The token in an advertised local name, or null if [name] is not one.
String? tokenFromAdvertisedName(String? name) {
  if (name == null || !name.startsWith(advertisedNamePrefix)) return null;
  final token = name.substring(advertisedNamePrefix.length);
  return isValidToken(token) ? token : null;
}

/// The token in manufacturer data from [manufacturerId], or null.
String? tokenFromManufacturerData(int id, List<int> data) {
  if (id != manufacturerId) return null;
  final token = String.fromCharCodes(data);
  return isValidToken(token) ? token : null;
}

/// `/ble/<token>`.
MultiAddr bleAddr(String token) => MultiAddr('/$bleProtocolName/$token');

/// The token in a `/ble/<token>[/p2p/<id>]` address, or null.
String? tokenOf(MultiAddr addr) => addr.valueForProtocol(bleProtocolName);

/// True if [addr] is `/ble/<token>`, optionally followed by `/p2p/<id>`.
bool isBleAddr(MultiAddr addr) {
  final c = addr.components;
  if (c.isEmpty || c.first.$1.name != bleProtocolName) return false;
  if (c.length == 1) return true;
  return c.length == 2 && c[1].$1.name == 'p2p';
}

/// First byte of every GATT value that carries connection bytes.
abstract final class FrameType {
  /// The rest of the value is connection bytes.
  static const data = 0x00;

  /// The sender closed the connection. Needed because an iOS peripheral
  /// cannot disconnect a central.
  static const close = 0x01;
}
