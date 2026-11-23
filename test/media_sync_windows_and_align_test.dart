import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/media/media_sync_service.dart';
import 'package:ccs_eeg_app/src/media/synced_media_panel.dart';

Uint8List _asciiBytes(String s) => Uint8List.fromList(ascii.encode(s));

Uint8List _u32le(int v) =>
    (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List();

Uint8List _riffWavWithChunks(List<({String id, Uint8List payload})> chunks) {
  final body = BytesBuilder();
  body.add(_asciiBytes('WAVE'));
  for (final c in chunks) {
    body.add(_asciiBytes(c.id));
    body.add(_u32le(c.payload.length));
    body.add(c.payload);
    if (c.payload.length % 2 == 1) body.addByte(0);
  }
  final bodyBytes = body.takeBytes();
  final out = BytesBuilder();
  out.add(_asciiBytes('RIFF'));
  out.add(_u32le(bodyBytes.length));
  out.add(bodyBytes);
  return out.takeBytes();
}

void main() {
  group('MediaSyncService.findToolInPaths', () {
    test('returns null on Windows when ffmpeg.exe is missing', () {
      final dir = Directory.systemTemp.createTempSync('ccs_find_tool_missing_');
      addTearDown(() => dir.deleteSync(recursive: true));

      final found = MediaSyncService.findToolInPaths(
        'ffmpeg',
        searchDirs: [dir.path, r'C:\nonexistent_ffmpeg_dir'],
        isWindows: true,
      );
      expect(found, isNull);
    });

    test('finds existing tool executable on Windows and Unix', () {
      final dir = Directory.systemTemp.createTempSync('ccs_find_tool_ok_');
      addTearDown(() => dir.deleteSync(recursive: true));

      final sep = Platform.pathSeparator;
      final winExe = File('${dir.path}${sep}ffmpeg.exe')..writeAsStringSync('stub');
      final unixExe = File('${dir.path}${sep}ffprobe')..writeAsStringSync('stub');
      expect(winExe.existsSync(), isTrue);
      expect(unixExe.existsSync(), isTrue);

      final foundWin = MediaSyncService.findToolInPaths(
        'ffmpeg',
        searchDirs: [r'C:\nonexistent_ffmpeg_dir', '${dir.path}/'],
        isWindows: true,
      );
      expect(foundWin, isNotNull);
      expect(foundWin!.endsWith('ffmpeg.exe'), isTrue);
      expect(File(foundWin).existsSync(), isTrue);

      final foundUnix = MediaSyncService.findToolInPaths(
        'ffprobe',
        searchDirs: ['/nonexistent/bin', dir.path],
        isWindows: false,
      );
      expect(foundUnix, isNotNull);
      expect(foundUnix!.endsWith('ffprobe'), isTrue);
      expect(File(foundUnix).existsSync(), isTrue);
    });
  });

  group('MediaSyncService.findSiblingTimestampedVideos', () {
    test('finds same-session sibling videos sorted smallest-first and filters out-of-window clips', () async {
      final root = Directory.systemTemp.createTempSync('ccs_sibling_videos_');
      addTearDown(() => root.deleteSync(recursive: true));

      final sep = Platform.pathSeparator;
      final audioDir = Directory('${root.path}${sep}Audiofiles${sep}Sub03_Audio')..createSync(recursive: true);
      final videoDir = Directory('${root.path}${sep}Videofiles${sep}Sub03_Video')..createSync(recursive: true);

      final wavFile = File('${audioDir.path}${sep}1_TKG03_Meditation.wav')
        ..writeAsBytesSync(List<int>.filled(128, 0));

      // Smallest valid same-session clip (~32s after EEG start).
      final vidSmall = File('${videoDir.path}${sep}2026-11-13 08-53-24_Meditation1.mp4')
        ..writeAsBytesSync(List<int>.filled(100, 1));
      // Larger valid same-session clip (~407s after EEG start).
      final vidLarge = File('${videoDir.path}${sep}2026-11-13 08-59-39_Meditation2.mp4')
        ..writeAsBytesSync(List<int>.filled(500, 2));
      // Out-of-window afternoon recording (~6h later) -> filtered out.
      File('${videoDir.path}${sep}2026-11-13 15-04-00_Afternoon_Task.mp4')
          .writeAsBytesSync(List<int>.filled(50, 3));
      // Video without timestamp in name -> ignored.
      File('${videoDir.path}${sep}calibration_no_clock.mp4')
          .writeAsBytesSync(List<int>.filled(40, 4));

      final results = await MediaSyncService.findSiblingTimestampedVideos(
        wavFile.path,
        eegStartTime: DateTime(2026, 11, 13, 8, 52, 51),
        eegDurationSec: 3720.0,
      );

      expect(results.length, 2);
      expect(results[0].path, vidSmall.path);
      expect(results[0].bytes, 100);
      expect(results[0].startTime, DateTime(2026, 11, 13, 8, 53, 24));
      expect(results[1].path, vidLarge.path);
      expect(results[1].bytes, 500);
    });
  });

  group('MediaSyncService.parseWavEmbeddedTimestamp', () {
    test('parses BWF bext originationDate and originationTime', () async {
      final dir = Directory.systemTemp.createTempSync('ccs_wav_bext_');
      addTearDown(() => dir.deleteSync(recursive: true));

      final bext = Uint8List(346);
      bext.setRange(320, 330, _asciiBytes('2026-11-13'));
      bext.setRange(330, 338, _asciiBytes('08:51:52'));

      final bytes = _riffWavWithChunks([
        (id: 'fmt ', payload: Uint8List(16)),
        (id: 'data', payload: Uint8List(32)),
        (id: 'bext', payload: bext),
      ]);
      final wav = File('${dir.path}${Platform.pathSeparator}bext.wav')
        ..writeAsBytesSync(bytes);

      final parsed = await MediaSyncService.parseWavEmbeddedTimestamp(wav.path);
      expect(parsed, isNotNull);
      expect(parsed!.startTime, DateTime(2026, 11, 13, 8, 51, 52));
      expect(parsed.source, 'WAV Broadcast (bext) header');
    });

    test('parses LIST INFO ICRD timestamp', () async {
      final dir = Directory.systemTemp.createTempSync('ccs_wav_icrd_');
      addTearDown(() => dir.deleteSync(recursive: true));

      final icrdVal = _asciiBytes('2026-11-13 09:15:30\x00');
      final listPayload = BytesBuilder()
        ..add(_asciiBytes('INFO'))
        ..add(_asciiBytes('ICRD'))
        ..add(_u32le(icrdVal.length))
        ..add(icrdVal);

      final bytes = _riffWavWithChunks([
        (id: 'fmt ', payload: Uint8List(16)),
        (id: 'LIST', payload: listPayload.takeBytes()),
        (id: 'data', payload: Uint8List(16)),
      ]);
      final wav = File('${dir.path}${Platform.pathSeparator}icrd.wav')
        ..writeAsBytesSync(bytes);

      final parsed = await MediaSyncService.parseWavEmbeddedTimestamp(wav.path);
      expect(parsed, isNotNull);
      expect(parsed!.startTime, DateTime(2026, 11, 13, 9, 15, 30));
      expect(parsed.source, 'WAV LIST/INFO (ICRD) header');
    });

    test('returns null when WAV has no embedded timestamp chunk', () async {
      final dir = Directory.systemTemp.createTempSync('ccs_wav_plain_');
      addTearDown(() => dir.deleteSync(recursive: true));

      final bytes = _riffWavWithChunks([
        (id: 'fmt ', payload: Uint8List(16)),
        (id: 'data', payload: Uint8List(16)),
      ]);
      final wav = File('${dir.path}${Platform.pathSeparator}plain.wav')
        ..writeAsBytesSync(bytes);

      final parsed = await MediaSyncService.parseWavEmbeddedTimestamp(wav.path);
      expect(parsed, isNull);
    });
  });

  group('MediaSyncService .ccssync.json sidecar', () {
    test('saves and loads per-session offsets without overwriting sibling entries', () async {
      final dir = Directory.systemTemp.createTempSync('ccs_sync_sidecar_');
      addTearDown(() => dir.deleteSync(recursive: true));

      final mediaPath = '${dir.path}${Platform.pathSeparator}phone_audio.wav';
      File(mediaPath).writeAsBytesSync(const [0, 1]);

      expect(
        await MediaSyncService.loadSyncOffset(mediaPath: mediaPath, eegKey: 'session_a'),
        isNull,
      );

      await MediaSyncService.saveSyncOffset(
        mediaPath: mediaPath,
        eegKey: 'session_a',
        offsetSeconds: -60.25,
        alignmentSource: 'landmark sync',
        syncNote: 'Synced at 1:00 -> EEG 0:00',
      );
      await MediaSyncService.saveSyncOffset(
        mediaPath: mediaPath,
        eegKey: 'session_b',
        offsetSeconds: 14.5,
        alignmentSource: 'manual slide',
        syncNote: 'Slid to +14.50 s',
      );

      final a = await MediaSyncService.loadSyncOffset(
        mediaPath: mediaPath,
        eegKey: 'session_a',
      );
      final b = await MediaSyncService.loadSyncOffset(
        mediaPath: mediaPath,
        eegKey: 'session_b',
      );
      final missing = await MediaSyncService.loadSyncOffset(
        mediaPath: mediaPath,
        eegKey: 'session_c',
      );

      expect(a, isNotNull);
      expect(a!.offsetSeconds, closeTo(-60.25, 1e-6));
      expect(a.alignmentSource, 'landmark sync');
      expect(b, isNotNull);
      expect(b!.offsetSeconds, closeTo(14.5, 1e-6));
      expect(b.alignmentSource, 'manual slide');
      expect(missing, isNull);
    });
  });

  group('MediaSyncController.parseFlexibleTimeSec', () {
    test('parses signed seconds, mm:ss, and hh:mm:ss and rejects invalid input', () {
      expect(MediaSyncController.parseFlexibleTimeSec('-60'), -60.0);
      expect(MediaSyncController.parseFlexibleTimeSec('−10.5'), -10.5);
      expect(MediaSyncController.parseFlexibleTimeSec('12.5'), 12.5);
      expect(MediaSyncController.parseFlexibleTimeSec('39:00'), 2340.0);
      expect(MediaSyncController.parseFlexibleTimeSec('-1:30.5'), -90.5);
      expect(MediaSyncController.parseFlexibleTimeSec('1:02:03.5'), 3723.5);

      expect(MediaSyncController.parseFlexibleTimeSec(''), isNull);
      expect(MediaSyncController.parseFlexibleTimeSec('abc'), isNull);
      expect(MediaSyncController.parseFlexibleTimeSec('1:75'), isNull);
      expect(MediaSyncController.parseFlexibleTimeSec('1:2:3:4'), isNull);
      expect(MediaSyncController.parseFlexibleTimeSec('--5'), isNull);
    });
  });
}
