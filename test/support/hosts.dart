import 'package:dart_libp2p/config/config.dart';
import 'package:dart_libp2p/core/crypto/ed25519.dart';
import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p_ble/dart_libp2p_ble.dart';
import 'package:dart_libp2p_ble/testing.dart';

/// A started host whose only transport is BLE over [net].
///
/// [claimedPeer] is the peer ID the transport publishes in its identity
/// characteristic; by default the host's own. Another one makes an impostor.
Future<(Host, BleTransport, FakeBleRadio)> newBleHost(FakeBleNetwork net, {String? token, PeerId? claimedPeer}) async {
  final keyPair = await generateEd25519KeyPair();
  final peerId = PeerId.fromPublicKey(keyPair.publicKey);
  final radio = net.newRadio();
  final ble = BleTransport(radio: radio, localPeer: claimedPeer ?? peerId, token: token);
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
  return (host, ble, radio);
}

/// Connects [from] to [to] over BLE.
Future<void> connectBle(Host from, Host to, BleTransport toBle) =>
    from.connect(AddrInfo(to.id, [toBle.listenAddr]));
