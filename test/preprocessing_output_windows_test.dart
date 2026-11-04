import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/models.dart';
import 'package:ccs_eeg_app/src/extraction_service.dart';

void main() {
  test('GEDAI internal windows do not define saved epochs', () async {
    final dir = Directory.systemTemp.createTempSync('output_windows_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final rec = EegRecording(
      path: '${dir.path}/raw.ccseeg',
      format: 'ccseeg',
      sampleRate: 100,
      labels: ['Fz', 'Cz', 'Pz', 'Oz'],
      sampleCount: 1200,
      preview: [
        for (var c = 0; c < 4; c++)
          Float32List.fromList([
            for (var t = 0; t < 1200; t++)
              math.sin(t * (c + 6) * 2 * math.pi / 100) +
                  .2 * math.sin(t * .31 + c),
          ]),
      ],
      markers: [
        const EegMarker(type: 'Event', description: 'Cue', startSeconds: 3.5),
      ],
    );
    final config = AnalysisConfig()
      ..filter = false
      ..downsample = false
      ..badChannels = false
      ..interpolate = false;
    expect(config.epochBeforeGedai, false);
    expect(config.gedaiEpochSeconds, 1);
    final clean = await ExtractionService().preprocess(
      recording: rec,
      outputPath: '${dir.path}/continuous.ccseeg',
      options: config.toPreprocessingOptions(),
      onProgress: (p, m) {},
    );
    expect(clean.isEpoched, false);
    expect(clean.sampleCount, 1200);
    expect(clean.markers.single.startSeconds, 3.5);
    config.epochBeforeGedai = true;
    final windows = await ExtractionService().preprocess(
      recording: rec,
      outputPath: '${dir.path}/fixed.ccseeg',
      options: config.toPreprocessingOptions(),
      outputWindowSeconds: 5,
      outputOverlapSeconds: 2,
      onProgress: (p, m) {},
    );
    expect(windows.pointsPerEpoch, 500);
    expect(windows.epochCount, 3);
    expect(windows.markers.length, 2);
    expect(windows.markers.map((m) => m.epochIndex), [0, 1]);
    expect(windows.markers.map((m) => m.startSeconds), [3.5, .5]);
  });
}
