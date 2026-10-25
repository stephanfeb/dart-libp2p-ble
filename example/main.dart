// Two nearby devices find each other over Bluetooth LE and ping.
//
// Run this in a Flutter app on two devices (Android, iOS or macOS). Add the
// Bluetooth permissions (Android) and usage descriptions (iOS, macOS) that
// doc/platforms.md lists.

// ignore_for_file: avoid_print
import 'package:dart_libp2p/config/config.dart';
import 'package:dart_libp2p/core/crypto/ed25519.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/p2p/protocol/ping/ping.dart';
import 'package:dart_libp2p_ble/dart_libp2p_ble.dart';
import 'package:logging/logging.dart';

Future<void> main() async {
  // #region logging
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((r) => print('${r.level.name} ${r.loggerName}: ${r.message}'));
  // bluetooth_low_energy logs every advertisement and GATT value at INFO,
  // many lines a second: keep only its warnings.
  hierarchicalLoggingEnabled = true;
  for (final name in ['CentralManager', 'PeripheralManager']) {
    Logger(name).level = Level.WARNING;
  }
  // #endregion logging

  // #region host
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
  // #endregion host

  // #region discovery
  final discovery = BleDiscovery(host: host, transport: ble);
  discovery.peerFound.listen((peer) async {
    final result = await PingService(host).ping(peer).first;
    print('ping ${peer.toBase58()}: ${result.rtt?.inMilliseconds} ms');
  });
  await discovery.start();
  // #endregion discovery
}
