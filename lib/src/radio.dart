import 'dart:async';
import 'dart:typed_data';

/// One GATT connection between this device and a nearby one, seen as an
/// ordered, reliable channel of values (each at most [maxValueLength] bytes).
///
/// On the central side, [send] writes the RX characteristic and [values] are
/// TX notifications. On the peripheral side, [send] notifies TX and [values]
/// are RX writes.
abstract class BleLink {
  /// True if this device is the GATT central of the link (it dialed).
  bool get isCentral;

  /// A platform ID of the remote device, for logs and the remote address of
  /// an inbound connection. It can change between connections.
  String get remoteId;

  /// Largest value [send] accepts.
  int get maxValueLength;

  /// Values from the remote device, in order. The stream closes when the
  /// link is lost or closed.
  Stream<Uint8List> get values;

  /// Sends one value. Completes when the platform has taken it; values sent
  /// one after another arrive in order.
  Future<void> send(Uint8List value);

  /// Ends the link. A central disconnects; a peripheral stops sending (iOS
  /// cannot disconnect a central).
  Future<void> close();

  /// Completes when the link is lost or closed.
  Future<void> get done;
}

/// A nearby device that advertises the libp2p BLE service.
class BleSighting {
  /// The token in its advertised name.
  final String token;

  /// Signal strength, if the platform gives one.
  final int? rssi;

  const BleSighting(this.token, {this.rssi});

  @override
  String toString() => 'BleSighting($token, rssi: $rssi)';
}

/// The platform BLE radio, in both roles, as the transport needs it.
///
/// [BluetoothLowEnergyRadio] is the real one; [FakeBleRadio] (in
/// `package:dart_libp2p_ble/testing.dart`) connects radios in memory.
abstract class BleRadio {
  /// Serves the libp2p GATT service with [identity] (the local peer ID bytes)
  /// in its identity characteristic, and advertises [token].
  ///
  /// A central that subscribes to TX opens a link: it arrives on [incoming].
  Future<void> startAdvertising(String token, Uint8List identity);

  /// Stops advertising and serving. Open links stay open.
  Future<void> stopAdvertising();

  /// Links that nearby centrals opened to this device.
  Stream<BleLink> get incoming;

  /// Starts scanning for the libp2p BLE service. Sightings arrive on
  /// [sightings], one or more per device.
  Future<void> startScan();

  Future<void> stopScan();

  Stream<BleSighting> get sightings;

  /// Reads the identity characteristic (the peer ID bytes) of the device
  /// that advertises [token]. The GATT connection this opens is kept for a
  /// short time, so that a [connect] right after it does not connect again.
  Future<Uint8List> readIdentity(String token, {Duration? timeout});

  /// Opens a link, as central, to the device that advertises [token].
  Future<BleLink> connect(String token, {Duration? timeout});

  /// Stops scanning and advertising and closes all links.
  Future<void> dispose();
}
