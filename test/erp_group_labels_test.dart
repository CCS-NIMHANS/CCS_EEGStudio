import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/erp/publication_plots.dart';

void main() {
  testWidgets('preserves saved groups and leaves unknown subjects unassigned', (
    tester,
  ) async {
    Map<String, String>? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: ErpGroupLabelDialog(
          files: const [
            {'subject': 'S1', 'group': 'Experienced'},
            {'subject': 'S2'},
          ],
          initialGroups: const {},
          onSaved: (groups) => saved = Map.of(groups),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Unassigned'), findsWidgets);
    await tester.tap(find.text('Apply Groups'));
    expect(saved, {'S1': 'Experienced', 'S2': ''});
  });

  testWidgets('renaming a group updates assigned participants', (tester) async {
    Map<String, String>? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: ErpGroupLabelDialog(
          files: const [
            {'subject': 'S1'},
          ],
          initialGroups: const {'S1': 'CONTROL'},
          onSaved: (groups) => saved = Map.of(groups),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField).first, 'Novice');
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Apply Groups'));
    expect(saved, {'S1': 'Novice'});
  });
}
