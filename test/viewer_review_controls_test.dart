import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/models.dart';
import 'package:ccs_eeg_app/src/eeg_viewer.dart';
import 'package:ccs_eeg_app/src/ica_review.dart';
import 'package:ccs_eeg_app/src/processing_settings_dialog.dart';

EegRecording recording(String path, List<String> labels, double rate, {Map<String, dynamic> provenance = const {}}) => EegRecording(
  path: path, sampleRate: rate, labels: labels, sampleCount: (rate * 30).round(), format: 'edf',
  preview: [for (final _ in labels) Float32List.fromList(List.generate((rate * 30).round(), (i) => (i % 7).toDouble()))], provenance: provenance,
);
void main() {
  test('explicit interpolation status takes precedence over legacy inference', () {
    final rec = recording('/tmp/clean.edf', ['C3', 'Cz'], 10, provenance: {
      'summary': {'bad_channels': ['C3', 'Cz'], 'interpolated_channels': ['C3']},
      'interactive_applied_steps': {'interpolate': {'interpolate': true}},
    });
    expect(rec.interpolatedChannels, {'C3'});
    expect(recording('/tmp/raw.edf', ['C3'], 10).interpolatedChannels, isEmpty);
  });
  testWidgets('comparison matches channels across channel counts and sample rates', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize); addTearDown(tester.view.resetDevicePixelRatio);
    final clean = recording('/tmp/clean.edf', ['Cz', 'Fz'], 10);
    final raw = recording('/tmp/raw.edf', ['Fz', 'AUX', 'Cz'], 20);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: EegViewer(recording: clean, rawRecording: raw, selection: const ViewerSelection.empty(), onSelectionChanged: (_) {}))));
    await tester.tap(find.byTooltip('Compare recordings side by side'));
    await tester.pump();
    expect(find.textContaining('2 matched channels'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });
  testWidgets('ICA fixed amplitude survives time navigation and returns to Auto', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000); tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize); addTearDown(tester.view.resetDevicePixelRatio);
    final rec = recording('/tmp/clean.edf', ['Cz'], 10, provenance: {'summary': {'ica': {'ica': {
      'blink_stage': {'ran': true, 'removed': [], 'review': {
        'probabilities': [[1.0]], 'class_names': ['Brain'], 'mixing': [[1.0]],
        'traces': [List.generate(300, (i) => i % 7)], 'trace_sample_rate': 10, 'trace_duration_seconds': 30,
      }},
    }}}});
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (context) => TextButton(onPressed: () => showIcaReview(context, rec), child: const Text('Review'))))));
    await tester.tap(find.text('Review')); await tester.pumpAndSettle();
    final field = find.widgetWithText(TextFormField, 'Fixed ± amplitude (a.u.)');
    await tester.ensureVisible(field); await tester.enterText(field, '12'); await tester.testTextInput.receiveAction(TextInputAction.done); await tester.pump();
    dynamic painter() => tester.widgetList<CustomPaint>(find.byType(CustomPaint)).map((w) => w.painter).firstWhere((p) => p.runtimeType.toString() == '_TracePainter');
    expect(painter().limit, 12);
    await tester.ensureVisible(find.byTooltip('Next time window')); await tester.tap(find.byTooltip('Next time window')); await tester.pump();
    expect(painter().limit, 12);
    await tester.ensureVisible(find.text('Autoscale')); await tester.tap(find.text('Autoscale')); await tester.pump();
    expect(painter().limit, isNull);
    expect(tester.takeException(), isNull);
  });
  testWidgets('MIC settings contain ROI controls and omit recording-format controls', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (context) => TextButton(onPressed: () => showProcessingSettings(context, AnalysisConfig(), 'Feature Extraction', section: 'MIC', availableChannels: ['Fz', 'Pz']), child: const Text('Settings'))))));
    await tester.tap(find.text('Settings')); await tester.pumpAndSettle();
    expect(find.text('MIC parameters'), findsOneWidget);
    expect(find.text('Seed region'), findsOneWidget);
    expect(find.text('Target region'), findsOneWidget);
    expect(find.text('Saved recording format (all workflows)'), findsNothing);
    expect(find.text('Frequency bands (shared by band-based features)'), findsOneWidget);
    await tester.tap(find.text('Cancel')); await tester.pumpAndSettle();
  });
}
