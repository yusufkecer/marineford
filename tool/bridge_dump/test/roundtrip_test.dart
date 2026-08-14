import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marineford/marineford.dart';
import 'package:marineford_cli/src/flutter_bridge.dart';

/// The one test that needs both halves of the split at once.
///
/// `marineford_cli` compiles Flutter patches without Flutter, from bundled
/// declarations. `marineford` runs them with Flutter, through flutter_eval's
/// wrappers. Each half is covered by its own package's tests, but only a test
/// with both can show that what one produces is what the other expects — and
/// that is the claim the whole design rests on.
///
/// It lives here because this is the only package that has both, and this
/// package is outside the workspace and outside CI. That is not where an
/// integration test belongs. It is here until flutter_eval compiles against
/// current Flutter from pub, at which point `packages/marineford` can take a
/// dev dependency on it and this moves there.
///
/// The declarations are registered by `marineford_cli`, deliberately: this must
/// exercise the bundled data, not flutter_eval's own plugin. Registering the
/// plugin here would pass even if the bundle were empty.
void main() {
  const id = 'pkg:app/lib/screen.dart#orderCard';

  /// Compiles [body] the way the CLI does — no Flutter in the compiler.
  Runtime compile(String body) {
    final compiler = Compiler();
    registerFlutterBridges(compiler);
    final program = compiler.compile(<String, Map<String, String>>{
      'patch': <String, String>{
        'main.dart': '''
import 'package:flutter/material.dart';

class RuntimeOverride {
  const RuntimeOverride(this.id, {this.version});
  final String id;
  final String? version;
}

// The constraint is not decoration. Without `version:` dart_eval records the
// literal string `<null`, which fails to parse at load time and drops the
// override in silence — the case `PatchLinter` warns about.
@RuntimeOverride('$id', version: '>=1.0.0 <2.0.0')
$body
''',
      },
    });
    final runtime = Runtime(program.write().buffer.asByteData());
    // Only the runtime half gets flutter_eval, which is exactly the split the
    // design claims: wrappers at runtime, declarations at build time.
    runtime.addPlugin(flutterEvalPlugin);
    runtime.addPlugin(const MarinefordSandbox());
    runtime.loadGlobalOverrides();
    return runtime;
  }

  void activate(Runtime runtime) => Patch.activate(
        runtime,
        resolveSlots(runtime, Version.parse('1.4.0')),
        onFailure: (id, error, stackTrace) {},
      );

  tearDown(Patch.deactivate);

  /// What a generated shim does, written out: dispatch, convert, check.
  Widget? dispatch(Map<String, dynamic> data) {
    final slot = Patch.slot(id);
    if (slot == null) return null;
    final result = Patch.invoke1(slot, MarinefordJson.wrap(data), id);
    if (result == null || identical(result, patchedNull)) return null;
    return MarinefordJson.valueOf<Widget>(result);
  }

  testWidgets('a patch compiled without Flutter renders with it',
      (tester) async {
    activate(compile('''
Widget orderCard(Map<String, dynamic> data) {
  return Column(
    children: [
      Text(data['title']),
      Padding(
        padding: EdgeInsets.all(8.0),
        child: Text(data['total']),
      ),
    ],
  );
}
'''));

    final widget = dispatch(<String, dynamic>{
      'title': 'Order #4821',
      'total': r'$62.00',
    });

    expect(widget, isNotNull,
        reason: 'the conversion must carry a widget across unchanged');
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: widget!)));
    expect(find.text('Order #4821'), findsOneWidget);
    expect(find.text(r'$62.00'), findsOneWidget);
  });

  testWidgets('a patch that returns the wrong type falls back', (tester) async {
    // The safety property, unchanged by widgets: a patch whose result does not
    // fit the signature is a patch bug, and the original runs instead.
    activate(compile('''
Widget orderCard(Map<String, dynamic> data) {
  return data['title'];
}
'''));

    expect(dispatch(<String, dynamic>{'title': 'Order #4821'}), isNull);
  });

  testWidgets('a patch cannot reach the network through Image.network',
      (tester) async {
    // flutter_eval gates this behind `assertPermission('network', url)` and
    // marineford grants nothing, so it is denied. Worth an actual test rather
    // than a reading of flutter_eval's source: this is the boundary that makes
    // "a patch cannot add capabilities" true, and it now has to hold across a
    // second library's bridges as well as dart_eval's own.
    activate(compile('''
Widget orderCard(Map<String, dynamic> data) {
  return Image.network(data['url']);
}
'''));

    expect(
      dispatch(<String, dynamic>{'url': 'https://example.com/pixel.png'}),
      isNull,
      reason: 'the patch must fail and fall back, not fetch',
    );
    expect(Patch.failureCount, greaterThan(0),
        reason: 'and the failure must be counted, so it eventually deactivates',
    );
  });

  testWidgets('a patch cannot read an asset either', (tester) async {
    activate(compile('''
Widget orderCard(Map<String, dynamic> data) {
  return Image.asset(data['name']);
}
'''));

    expect(dispatch(<String, dynamic>{'name': 'secrets.png'}), isNull);
    expect(Patch.failureCount, greaterThan(0));
  });

  test('the bundled declarations name the flutter_eval they came from', () {
    // A patch compiled against declarations the app's flutter_eval does not
    // have fails at runtime and falls back — silently, which is the failure
    // mode worth being able to diagnose.
    expect(kFlutterBridgeVersion, isNotEmpty);
    expect(kFlutterBridgeVersion, isNot('unknown'));
  });
}
