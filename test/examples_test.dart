// The code samples in doc/ match the programs they come from
// (tool/embed_examples.dart), and the in-memory example runs, so the guides
// only show code that works. example/main.dart needs Bluetooth; the spike
// app runs it on devices.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../example/mesh_in_memory.dart' as mesh;
import '../tool/embed_examples.dart' as embed;

void main() {
  test('doc samples match the programs they come from', () {
    // flutter test runs in the package root.
    expect(Directory('doc').existsSync(), isTrue);
    expect(embed.embedAll(check: true), isEmpty, reason: 'run dart run tool/embed_examples.dart');
  });

  test('example/mesh_in_memory.dart', () async {
    final out = <String>[];
    await runZoned(mesh.main, zoneSpecification: ZoneSpecification(print: (_, __, ___, line) => out.add(line)));
    expect(out, contains('C got: hello from A'));
  }, timeout: const Timeout(Duration(minutes: 1)));
}
