import 'package:flutter/material.dart';
import 'package:marineford/marineford.dart';

part 'collect_day_screen.marineford.dart';

/// The screen, and the UI chokepoint inside it.
///
/// `api_client.dart` shows the chokepoint pattern applied to data: one marked
/// normaliser absorbs whatever the backend does. This is the same idea applied
/// to what the user sees, and the reason it is a separate marker is that the
/// two break for different reasons. A backend that renames a field is a data
/// problem. A row that shows the wrong thing *given correct data* is a
/// rendering problem, and no amount of patching the normaliser fixes it.
class CollectDayScreen extends StatelessWidget {
  /// Creates a [CollectDayScreen] showing [day].
  const CollectDayScreen({required this.day, super.key});

  /// The collection day, already parsed — whatever `parseCollectDay` made of
  /// the response.
  final String day;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Atık Toplama')),
        body: Center(
          // The marked function is called from `build`; `build` itself is not
          // marked and cannot be. A `BuildContext` cannot cross the boundary,
          // and that restriction is doing real work — it forces the marker onto
          // a function whose inputs are data, which is the only kind a patch can
          // be handed.
          child: collectDayCard(<String, dynamic>{
            'day': day,
            'label': 'Toplama günü',
          }),
        ),
      );
}

/// The UI chokepoint.
///
/// Marked, so the card can be rebuilt by a patch. It takes a map rather than
/// typed arguments for the same reason the normaliser does: a patch can be
/// handed JSON-shaped data and nothing else, and a map leaves room to send a
/// field the shipped build does not read yet.
///
/// What it does today is deliberately slightly wrong — see the patch in
/// `patch/lib/card.dart`.
@patchable
Widget _collectDayCard(Map<String, dynamic> data) {
  return Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // The bug. `Belirlenmemiş` means "not determined" — it is the value
          // the parser returns when it could not find a day, and showing it in
          // the same large, confident style as a real answer is what the
          // support tickets were about. It shipped this way.
          Text(
            data['label'] as String,
            style: const TextStyle(fontSize: 14),
          ),
          const SizedBox(height: 8),
          Text(
            data['day'] as String,
            style: const TextStyle(fontSize: 28),
          ),
        ],
      ),
    ),
  );
}
