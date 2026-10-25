// Two nearby devices find each other over Bluetooth LE and ping.
//
// Run this in a Flutter app on two devices (Android, iOS or macOS). Add the
// Bluetooth permissions (Android) and usage descriptions (iOS, macOS) that
// bluetooth_low_energy documents.

// ignore_for_file: avoid_print
import 'package:dart_libp2p/config/config.dart';
import 'package:dart_libp2p/core/crypto/ed25519.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/p2p/protocol/ping/ping.dart';
import 'package:dart_libp2p_ble/dart_libp2p_ble.dart';

Future<void> main() async {
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

  final discovery = BleDiscovery(host: host, transport: ble);
  discovery.peerFound.listen((peer) async {
    final result = await PingService(host).ping(peer).first;
    print('ping ${peer.toBase58()}: ${result.rtt?.inMilliseconds} ms');
  });
  await discovery.start();
}
