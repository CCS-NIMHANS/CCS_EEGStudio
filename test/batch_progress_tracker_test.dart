import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/batch_progress_tracker.dart';

void main() {
  test('progress increases monotonically across stages and never hits 1.0 before finish', () {
    var clock = DateTime(2026, 11, 19, 12, 0, 0);
    final tracker = BatchProgressTracker(
      now: () => clock,
      stages: const [
        BatchStageSpec(id: 'prep', label: 'Preprocessing', fileCount: 3, priorWeightPerFile: 1.0),
        BatchStageSpec(id: 'feat', label: 'Feature Extraction', fileCount: 3, priorWeightPerFile: 0.45),
        BatchStageSpec(id: 'plot', label: 'Plotting', fileCount: 3, priorWeightPerFile: 0.25),
      ],
    );

    final samples = <double>[];
    void record() {
      final p = tracker.overallProgress;
      if (samples.isNotEmpty) {
        expect(p, greaterThanOrEqualTo(samples.last));
      }
      expect(p, lessThan(1.0));
      samples.add(p);
    }

    tracker.startStage(0);
    for (var i = 0; i < 3; i++) {
      tracker.beginFile('f$i.vhdr');
      clock = clock.add(const Duration(seconds: 5));
      tracker.updateFileProgress(0.5);
      record();
      clock = clock.add(const Duration(seconds: 5));
      tracker.completeFile();
      record();
    }

    final afterStage0 = samples.last;
    tracker.startStage(1);
    // Must not reset to 0 when Stage 2 begins!
    expect(tracker.overallProgress, greaterThanOrEqualTo(afterStage0));

    for (var i = 0; i < 3; i++) {
      tracker.beginFile('f$i.edf');
      clock = clock.add(const Duration(seconds: 2));
      tracker.updateFileProgress(0.6);
      record();
      clock = clock.add(const Duration(seconds: 3));
      tracker.completeFile();
      record();
    }

    tracker.startStage(2);
    expect(tracker.overallProgress, greaterThanOrEqualTo(samples.last));
    tracker.beginFile('f0.csv');
    clock = clock.add(const Duration(seconds: 2));
    tracker.updateFileProgress(1.0); // clamped to 0.99 internally until finish
    record();

    tracker.finish();
    expect(tracker.overallProgress, 1.0);
    expect(tracker.estimatedRemaining, Duration.zero);
  });

  test('ETA auto-adjusts after completed file, handles mid-file slowdown, and ignores skipped files', () {
    var clock = DateTime(2026, 11, 19, 12, 0, 0);
    final tracker = BatchProgressTracker(
      now: () => clock,
      stages: const [
        BatchStageSpec(id: 'prep', label: 'Preprocessing', fileCount: 4, priorWeightPerFile: 1.0),
        BatchStageSpec(id: 'feat', label: 'Feature Extraction', fileCount: 4, priorWeightPerFile: 0.5),
      ],
    );

    tracker.startStage(0);
    // File 0 skipped immediately -> must NOT count as a 0s file or crash ETA
    tracker.beginFile('skip.vhdr');
    clock = clock.add(const Duration(milliseconds: 20));
    tracker.completeFile(skipped: true);
    expect(tracker.estimatedRemaining, isNull);

    // File 1 takes 10s
    tracker.beginFile('f1.vhdr');
    clock = clock.add(const Duration(seconds: 5));
    tracker.updateFileProgress(0.5); // 5s / 0.5 = 10s est
    final prelimEta = tracker.estimatedRemaining;
    expect(prelimEta, isNotNull);
    expect(prelimEta!.inSeconds, greaterThanOrEqualTo(35)); // ~5s + 2*10s + 4*0.5*10s = 45s

    clock = clock.add(const Duration(seconds: 5));
    tracker.completeFile();

    // File 2 takes 20s (slower!) -> mid-file at 10s with 25% done -> projects 40s for file 2
    tracker.beginFile('f2.vhdr');
    clock = clock.add(const Duration(seconds: 12));
    tracker.updateFileProgress(0.25);
    final adaptedEta = tracker.estimatedRemaining!;
    // Without mid-file slowdown adaptation, 12s > 10s EMA would clamp current file
    // remaining to 0s (total 30s). With adaptation, current file projects ~23.3s -> ~41s.
    expect(adaptedEta.inSeconds, greaterThan(35));
    expect(adaptedEta.inSeconds, lessThan(60));
  });

  test('formatBatchDuration renders seconds, minutes, and hours cleanly', () {
    expect(formatBatchDuration(const Duration(seconds: 9)), '9s');
    expect(formatBatchDuration(const Duration(minutes: 3, seconds: 5)), '3m 05s');
    expect(formatBatchDuration(const Duration(hours: 1, minutes: 7)), '1h 07m');
  });
}
