# Platforms

The package runs on **Android, iOS and macOS**, through the
[bluetooth_low_energy](https://pub.dev/packages/bluetooth_low_energy) plugin
(6.2). Each device is a central (it scans and dials) and a peripheral (it
advertises and accepts) at the same time.

Tested on devices: a Pixel 10a and an iPhone, in both
directions, with ping and gossipsub.

## Android

Add the permissions to `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.BLUETOOTH_SCAN"
    android:usesPermissionFlags="neverForLocation" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
<uses-permission android:name="android.permission.BLUETOOTH_ADVERTISE" />
<!-- Android 11 and earlier -->
<uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" android:maxSdkVersion="30" />
```

The radio asks the user for the permissions when it first needs Bluetooth.
`neverForLocation` tells Android that the app does not use scans to find the
user's location, so Android 12 and later do not ask for location.

What is different on Android:

- **The token goes in manufacturer data**, not in the device name. The
  plugin can set a name only by renaming the whole phone, and the radio
  never does that.
- **Advertising continues during a connection.** The controller stops
  connectable advertising when a central connects, and the Android stack
  turns it on again by itself. The radio never stops and starts advertising
  because of a connection: with the plugin, that breaks advertising.
- **The MTU is requested.** As a central, the radio asks for an MTU of 517,
  so a GATT value can carry up to 512 bytes.

## iOS

Add the usage descriptions to `ios/Runner/Info.plist`. iOS shows them when
it asks the user for Bluetooth access:

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Connects to people nearby over Bluetooth.</string>
<key>NSBluetoothPeripheralUsageDescription</key>
<string>Lets people nearby connect to you over Bluetooth.</string>
```

What is different on iOS:

- **The token goes in the local name** (`p2<token>`). iOS can advertise
  only a local name and service UUIDs.
- **A peripheral cannot disconnect a central.** The transport sends a close
  frame, and the central disconnects when it reads it.
- **Peripheral IDs change.** When an Android device connects again, it often
  comes back with a new address, so iOS gives it a new ID. The radio finds
  devices by token, so this does not matter to your app.

## macOS

Add `NSBluetoothAlwaysUsageDescription` to `macos/Runner/Info.plist`, as on
iOS, and the Bluetooth entitlement to both
`macos/Runner/DebugProfile.entitlements` and `Release.entitlements`:

```xml
<key>com.apple.security.device.bluetooth</key>
<true/>
```

macOS advertises and connects as iOS does.

## Deployment targets

Current Xcode versions build for iOS 15.0 or later and macOS 12.0 or later;
an older target fails the build. Set them in the Podfile and in the Xcode
project.

## Not tested yet

- **The app in the background.** iOS limits advertising and scanning in the
  background, and Android can stop a background app's scans. Expect
  connections to drop when the app leaves the foreground.
- **Three or more devices on real radios.** The mesh is tested with
  in-memory radios ([Testing](testing.md)); on devices, so far two at a time.
- **Android as the central to an iPhone over many connections**, and other
  pairs (iPhone to iPad, iPhone to Mac).

## Testing on devices

- **Bluetooth must be on.** The radio waits up to 30 seconds for it to be
  on (and on Android, for the user to give the permissions), then fails.
- **Turn on the transport's logs** to see each step. The loggers are
  `BleTransport`, `BleConn`, `BleDiscovery` and `BluetoothLowEnergyRadio`, at
  level `FINE`.
- **Quiet the Bluetooth plugin's logs.** `bluetooth_low_energy` logs every
  advertisement it sees and every GATT value it writes or reads at level
  `INFO`, through the loggers `CentralManager` and `PeripheralManager`. That
  is many lines a second, with the bytes. An app that prints `INFO` records
  sees all of them. Set those two loggers to `WARNING`:

<!-- example: example/main.dart#logging -->
```dart
Logger.root.level = Level.INFO;
Logger.root.onRecord.listen((r) => print('${r.level.name} ${r.loggerName}: ${r.message}'));
// bluetooth_low_energy logs every advertisement and GATT value at INFO,
// many lines a second: keep only its warnings.
hierarchicalLoggingEnabled = true;
for (final name in ['CentralManager', 'PeripheralManager']) {
  Logger(name).level = Level.WARNING;
}
```
<!-- /example -->
- **The test app in the repository** (`spike/`) runs a libp2p host on BLE
  with discovery, pings and gossip, and shows the log on screen.
