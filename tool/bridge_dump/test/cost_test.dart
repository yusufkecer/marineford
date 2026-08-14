import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marineford/marineford.dart';
import 'package:marineford_cli/src/flutter_bridge.dart';

/// What an interpreted widget build costs, and the rule that follows from it.
///
/// Not in `bench/`, for the same reason the round-trip test is not in
/// `packages/marineford`: that harness is pure Dart and this needs Flutter.
/// It moves there when flutter_eval compiles from pub.
///
/// The measurement is direct — one interpreted build timed against one native
/// build of the same tree — because the cost is large enough to measure on its
/// own. The repository's rule about never recovering a small number by
/// subtracting two large ones does not apply here; this number *is* the large
/// one.
///
/// A caveat worth keeping honest: `flutter test` runs the Dart VM in JIT mode,
/// and the interpreter is ordinary Dart code, so an AOT release build will not
/// match this exactly. The ratio to a native build is the durable part.
void main() {
  const id = 'pkg:app/lib/screen.dart#orderCard';

  const patch = '''
import 'package:flutter/material.dart';

class RuntimeOverride {
  const RuntimeOverride(this.id, {this.version});
  final String id;
  final String? version;
}

@RuntimeOverride('$id', version: '>=1.0.0 <2.0.0')
Widget orderCard(Map<String, dynamic> order) {
  return Card(
    child: Padding(
      padding: EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(order['title'], style: TextStyle(fontSize: 18.0)),
          SizedBox(height: 8.0),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [Text(order['name']), Text(order['price'])],
          ),
          Container(
            padding: EdgeInsets.symmetric(vertical: 8.0),
            child: Text(order['total']),
          ),
          ElevatedButton(onPressed: () {}, child: Text('Reorder')),
        ],
      ),
    ),
  );
}
''';

  test('an interpreted widget build costs a fraction of a frame', () {
    final compiler = Compiler();
    registerFlutterBridges(compiler);
    final program = compiler.compile(<String, Map<String, String>>{
      'patch': <String, String>{'main.dart': patch},
    });
    final runtime = Runtime(program.write().buffer.asByteData())
      ..addPlugin(flutterEvalPlugin)
      ..addPlugin(const MarinefordSandbox())
      ..loadGlobalOverrides();

    Patch.activate(runtime, resolveSlots(runtime, Version.parse('1.4.0')));
    addTearDown(Patch.deactivate);

    const order = <String, dynamic>{
      'title': 'Order #4821',
      'name': 'Espresso',
      'price': r'$4.00',
      'total': r'$62.00',
    };

    // Through the real dispatcher, so the number includes crossing the
    // boundary and converting the result — what a shim actually pays.
    Widget? patched() {
      final result =
          Patch.invoke1(Patch.slot(id)!, MarinefordJson.wrap(order), id);
      return MarinefordJson.valueOf<Widget>(result);
    }

    expect(patched(), isA<Card>(), reason: 'measure a hit, not a fallback');

    const warmup = 200;
    const runs = 2000;
    for (var i = 0; i < warmup; i++) {
      patched();
    }
    final interpreted = Stopwatch()..start();
    for (var i = 0; i < runs; i++) {
      patched();
    }
    interpreted.stop();

    for (var i = 0; i < warmup; i++) {
      _nativeCard(order);
    }
    final native = Stopwatch()..start();
    for (var i = 0; i < runs; i++) {
      _nativeCard(order);
    }
    native.stop();

    final each = interpreted.elapsedMicroseconds / runs;
    final nativeEach = native.elapsedMicroseconds / runs;
    const frameBudgetUs = 16600.0;

    // ignore: avoid_print
    print('interpreted: ${each.toStringAsFixed(1)}us  '
        'native: ${nativeEach.toStringAsFixed(2)}us  '
        '${(each / nativeEach).toStringAsFixed(0)}x  '
        '${(each / frameBudgetUs * 100).toStringAsFixed(2)}% of a 60fps frame');
    // ignore: avoid_print
    print('=> ${(frameBudgetUs / each).floor()} such builds would fill a '
        'frame. Patch a screen or a section; never a list row.');

    // A ceiling, not a budget. It is loose on purpose: this runs on whatever
    // machine happens to have flutter_eval working, so it is here to catch an
    // order-of-magnitude regression, not to police a few percent.
    expect(each, lessThan(500),
        reason: 'an interpreted card build should stay well inside a frame');
  });
}

Widget _nativeCard(Map<String, dynamic> order) => Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(order['title'] as String,
                style: const TextStyle(fontSize: 18)),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(order['name'] as String),
                Text(order['price'] as String),
              ],
            ),
            Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(order['total'] as String),
            ),
            ElevatedButton(onPressed: () {}, child: const Text('Reorder')),
          ],
        ),
      ),
    );
