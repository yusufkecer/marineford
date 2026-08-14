// Compiled by dart_eval, not by Dart, so it declares the annotation it needs
// rather than importing it — the same reason `normalize.dart` does. Two
// libraries in one package may each declare their own; neither imports the
// other.
import 'package:flutter/material.dart';

class RuntimeOverride {
  const RuntimeOverride(this.id, {this.version});
  final String id;
  final String? version;
}

/// Rebuilds the card so a missing day no longer looks like an answer.
///
/// The shipped build renders whatever `parseCollectDay` returned at 28pt,
/// including its "could not determine" placeholder — so a user whose response
/// the app failed to read was told, confidently and in large type, that their
/// collection day is "Belirlenmemiş". That is a rendering bug: the data was
/// already correct by the time it got here, so no amount of patching the
/// normaliser fixes it. It needs the widget rebuilt, which is what this does.
///
/// Note what is *not* here: no new screen, no navigation, no capability the
/// app did not already have. The same card, arranged correctly.
@RuntimeOverride(
  'pkg:json_drift_app/lib/collect_day_screen.dart#collectDayCard',
  version: '>=1.4.0 <1.5.0',
)
Widget card(Map data) {
  final day = data['day'];
  final known = day != 'Belirlenmemiş';

  return Card(
    child: Padding(
      padding: EdgeInsets.all(16.0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            known ? data['label'] : 'Toplama günü alınamadı',
            style: TextStyle(fontSize: 14.0),
          ),
          SizedBox(height: 8.0),
          Text(
            known ? day : 'Daha sonra tekrar deneyin',
            // The whole fix, in one number: a placeholder is no longer set in
            // the size reserved for a real answer.
            style: TextStyle(fontSize: known ? 28.0 : 16.0),
          ),
        ],
      ),
    ),
  );
}
