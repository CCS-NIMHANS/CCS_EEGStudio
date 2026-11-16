import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:xml/xml.dart';
import 'models.dart';

class XdfStreamInfo {
  const XdfStreamInfo(this.id, this.name, this.type, this.rate, this.channels);
  final int id, channels;
  final String name, type;
  final double rate;
  @override
  String toString() => '$name · $type · $channels channels · $rate Hz';
}

class _Float64Buffer {
  _Float64Buffer([int initialCapacity = 1024])
    : _data = Float64List(initialCapacity);
  Float64List _data;
  int length = 0;

  void add(double v) {
    if (length == _data.length) {
      final next = Float64List(_data.length * 2);
      next.setRange(0, length, _data);
      _data = next;
    }
    _data[length++] = v;
  }

  double operator [](int index) => _data[index];
}

class _Stream {
  _Stream(this.id, this.xml);
  final int id;
  final XmlDocument xml;
  String field(String key) =>
      xml.rootElement.getElement(key)?.innerText.trim() ?? '';
  int get count => int.parse(field('channel_count'));
  double get rate => double.parse(field('nominal_srate'));
  String get format => field('channel_format');
  final times = _Float64Buffer();
  final flatValues = _Float64Buffer(4096);
  final events = <(double, String)>[];
  final clocks = <(double, double)>[];
  double last = 0;
  XdfStreamInfo get info =>
      XdfStreamInfo(id, field('name'), field('type'), rate, count);
  double corrected(double time) {
    if (clocks.isEmpty) return time;
    if (time <= clocks.first.$1) return time + clocks.first.$2;
    for (var i = 1; i < clocks.length; i++) {
      final a = clocks[i - 1], b = clocks[i];
      if (time <= b.$1) {
        final f = (time - a.$1) / (b.$1 - a.$1);
        return time + a.$2 + f * (b.$2 - a.$2);
      }
    }
    return time + clocks.last.$2;
  }
}

class _Reader {
  _Reader(this.bytes, [int start = 0, int? end])
    : _bd = ByteData.sublistView(bytes),
      pos = start,
      end = end ?? bytes.length;
  final Uint8List bytes;
  final ByteData _bd;
  final int end;
  int pos;

  void _ensure(int n) {
    if (n < 0 || pos + n > end) {
      throw const FormatException('Truncated XDF chunk');
    }
  }

  int u8() {
    _ensure(1);
    return bytes[pos++];
  }

  int u16() {
    _ensure(2);
    final v = _bd.getUint16(pos, Endian.little);
    pos += 2;
    return v;
  }

  int u32() {
    _ensure(4);
    final v = _bd.getUint32(pos, Endian.little);
    pos += 4;
    return v;
  }

  int u64() {
    _ensure(8);
    final v = _bd.getUint64(pos, Endian.little);
    pos += 8;
    return v;
  }

  int variable() => switch (u8()) {
    1 => u8(),
    4 => u32(),
    8 => u64(),
    _ => throw const FormatException('Invalid XDF variable integer'),
  };

  String string(int n) {
    _ensure(n);
    final s = utf8.decode(Uint8List.sublistView(bytes, pos, pos + n));
    pos += n;
    return s;
  }

  double number(String format) {
    switch (format) {
      case 'float32':
        _ensure(4);
        final v = _bd.getFloat32(pos, Endian.little);
        pos += 4;
        return v;
      case 'double64':
        _ensure(8);
        final v = _bd.getFloat64(pos, Endian.little);
        pos += 8;
        return v;
      case 'int8':
        _ensure(1);
        return _bd.getInt8(pos++).toDouble();
      case 'int16':
        _ensure(2);
        final v = _bd.getInt16(pos, Endian.little).toDouble();
        pos += 2;
        return v;
      case 'int32':
        _ensure(4);
        final v = _bd.getInt32(pos, Endian.little).toDouble();
        pos += 4;
        return v;
      case 'int64':
        _ensure(8);
        final v = _bd.getInt64(pos, Endian.little).toDouble();
        pos += 8;
        return v;
      default:
        throw FormatException('Unsupported XDF channel format: $format');
    }
  }
}

const _liveAmp32Labels = [
  'Fp1', 'Fz', 'F3', 'F7', 'FT9', 'FC5', 'FC1', 'C3', 'T7', 'TP9',
  'CP5', 'CP1', 'Pz', 'P3', 'P7', 'O1', 'Oz', 'O2', 'P4', 'P8',
  'TP10', 'CP6', 'CP2', 'Cz', 'C4', 'T8', 'FT10', 'FC6', 'FC2', 'F4',
  'F8', 'Fp2',
];

List<String> _normalizeChannelLabels(List<String> rawLabels) {
  final genericCount = rawLabels
      .where((l) {
        final u = l.trim().toUpperCase();
        return u.startsWith('EEG 1_') ||
            u.startsWith('EEG_') ||
            u.startsWith('CH_') ||
            u.startsWith('CH ');
      })
      .length;
  if (genericCount >= 16) {
    final out = List<String>.from(rawLabels);
    for (var i = 0; i < _liveAmp32Labels.length && i < out.length; i++) {
      out[i] = _liveAmp32Labels[i];
    }
    return out;
  }
  return rawLabels;
}

/// Chunked XDF 1.0 import. Refuse clock resets/data gaps rather than silently
/// compressing time and moving ERP events. No Python dependency is required.
class XdfLoader {
  Future<Map<int, _Stream>> _read(
    String path, {
    bool headersOnly = false,
    int? streamId,
    bool Function()? isCancelled,
    void Function(double)? onProgress,
  }) async {
    final streams = <int, _Stream>{};
    if (headersOnly) {
      final file = File(path).openSync();
      try {
        final length = file.lengthSync();
        if (ascii.decode(file.readSync(4)) != 'XDF:')
          throw const FormatException('Not an XDF file');
        while (file.positionSync() < length) {
          if (isCancelled?.call() ?? false) {
            throw StateError('File loading cancelled');
          }
          final size = file.readByteSync();
          if (![1, 4, 8].contains(size))
            throw const FormatException('Invalid XDF chunk length');
          final raw = file.readSync(size);
          if (raw.length != size)
            throw const FormatException('Truncated XDF chunk length');
          final data = ByteData.sublistView(raw);
          final n = size == 1
              ? data.getUint8(0)
              : size == 4
              ? data.getUint32(0, Endian.little)
              : data.getUint64(0, Endian.little);
          final start = file.positionSync();
          if (n < 2 || start + n > length)
            throw const FormatException('Truncated XDF chunk');
          final tagBytes = file.readSync(2);
          final tag = ByteData.sublistView(tagBytes).getUint16(0, Endian.little);
          if (tag == 2) {
            final reader = _Reader(file.readSync(n - 2));
            final id = reader.u32();
            final stream = _Stream(id, XmlDocument.parse(reader.string(n - 6)));
            if (streams.containsKey(id))
              throw const FormatException('Duplicate XDF stream ID');
            if (stream.count <= 0 ||
                stream.count > 100000 ||
                !stream.rate.isFinite ||
                stream.rate < 0) {
              throw const FormatException('Invalid XDF stream dimensions');
            }
            streams[id] = stream;
          }
          file.setPositionSync(start + n);
        }
        return streams;
      } finally {
        file.closeSync();
      }
    }

    final bytes = await File(path).readAsBytes();
    if (bytes.length < 4 || ascii.decode(bytes.sublist(0, 4)) != 'XDF:') {
      throw const FormatException('Not an XDF file');
    }
    final reader = _Reader(bytes, 4, bytes.length);
    final length = bytes.length;
    var chunkCounter = 0;
    while (reader.pos < length) {
      if ((chunkCounter++ & 1023) == 0) {
        if (isCancelled?.call() ?? false) {
          throw StateError('File loading cancelled');
        }
        onProgress?.call((reader.pos / length) * .75);
      }
      final n = reader.variable();
      final start = reader.pos;
      if (n < 2 || start + n > length) {
        throw const FormatException('Truncated XDF chunk');
      }
      final tag = reader.u16();
      final chunkEnd = start + n;
      if (tag == 2) {
        final id = reader.u32();
        final stream = _Stream(id, XmlDocument.parse(reader.string(n - 6)));
        if (streams.containsKey(id))
          throw const FormatException('Duplicate XDF stream ID');
        if (stream.count <= 0 ||
            stream.count > 100000 ||
            !stream.rate.isFinite ||
            stream.rate < 0) {
          throw const FormatException('Invalid XDF stream dimensions');
        }
        streams[id] = stream;
      } else if (tag == 3 || tag == 4) {
        final id = reader.u32();
        final stream = streams[id];
        if (stream == null) {
          throw const FormatException('XDF sample precedes its stream header');
        }
        final include =
            streamId == null ||
            id == streamId ||
            stream.format == 'string' ||
            stream.rate == 0;
        if (include && tag == 4) {
          stream.clocks.add((
            reader.number('double64'),
            reader.number('double64'),
          ));
        } else if (include) {
          final count = reader.variable();
          if (count > n)
            throw const FormatException('Invalid XDF sample count');
          final chCount = stream.count;
          final fmt = stream.format;
          final isString = fmt == 'string';
          final isEventRate = stream.rate == 0;
          final dt = stream.rate > 0 ? 1 / stream.rate : 0.0;
          for (var i = 0; i < count; i++) {
            final flag = reader.u8();
            final time = flag == 8
                ? reader.number('double64')
                : flag == 0
                ? stream.last + dt
                : throw const FormatException('Invalid XDF timestamp flag');
            if (!time.isFinite)
              throw const FormatException('Non-finite XDF timestamp');
            stream.last = time;
            if (isString) {
              final labels = [
                for (var c = 0; c < chCount; c++)
                  reader.string(reader.variable()),
              ];
              stream.events.add((time, labels.join(' | ')));
            } else if (isEventRate) {
              final values = [
                for (var c = 0; c < chCount; c++) reader.number(fmt),
              ];
              stream.events.add((
                time,
                values.map((v) => v.toString()).join(' | '),
              ));
            } else {
              stream.times.add(time);
              for (var c = 0; c < chCount; c++) {
                stream.flatValues.add(reader.number(fmt));
              }
            }
          }
        }
      }
      reader.pos = chunkEnd;
    }
    return streams;
  }

  Future<List<XdfStreamInfo>> inspect(String path) async =>
      (await _read(path, headersOnly: true)).values
          .where((s) => s.rate > 0 && s.format != 'string')
          .map((s) => s.info)
          .toList();

  Future<EegRecording> load(
    String path, {
    int? streamId,
    void Function(double)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final streams = await _read(
      path,
      streamId: streamId,
      isCancelled: isCancelled,
      onProgress: (p) => onProgress?.call(p * .75),
    );
    var candidates = streams.values
        .where((s) => s.rate > 0 && s.format != 'string')
        .toList();
    if (streamId != null)
      candidates = candidates.where((s) => s.id == streamId).toList();
    if (candidates.length != 1) {
      final eeg = candidates
          .where((s) => s.field('type').toLowerCase() == 'eeg')
          .toList();
      if (eeg.length == 1) {
        candidates = eeg;
      } else {
        throw const FormatException(
          'Select one numeric XDF stream before loading.',
        );
      }
    }
    final stream = candidates.single;
    if (stream.times.length < 2)
      throw const FormatException('XDF stream has fewer than two samples');
    for (final s in streams.values) {
      for (var i = 1; i < s.clocks.length; i++) {
        if (s.clocks[i].$1 <= s.clocks[i - 1].$1 ||
            (s.clocks[i].$2 - s.clocks[i - 1].$2).abs() > .5) {
          throw const FormatException(
            'XDF contains a clock reset. Repair/split it with pyxdf before ERP analysis.',
          );
        }
      }
    }
    final rawTimes = Float64List(stream.times.length);
    for (var i = 0; i < stream.times.length; i++) {
      rawTimes[i] = stream.corrected(stream.times[i]);
    }
    final effectiveRate = (rawTimes.length - 1) / (rawTimes.last - rawTimes.first);
    if (!effectiveRate.isFinite || effectiveRate <= 0)
      throw const FormatException('Invalid XDF time axis');
    final rate = (stream.rate > 0 &&
            (effectiveRate - stream.rate).abs() / stream.rate <= 0.005)
        ? stream.rate
        : effectiveRate;
    for (var i = 1; i < rawTimes.length; i++) {
      if (rawTimes[i] <= rawTimes[i - 1] ||
          rawTimes[i] - rawTimes[i - 1] > 5 / stream.rate) {
        throw const FormatException(
          'XDF has non-monotonic timestamps or a data gap; split/repair the stream before analysis.',
        );
      }
    }
    final outCount = rate == effectiveRate
        ? rawTimes.length
        : ((rawTimes.last - rawTimes.first) * rate).round() + 1;
    final channelXml =
        stream.xml
            .findAllElements('channels')
            .firstOrNull
            ?.findElements('channel')
            .toList() ??
        [];
    final rawLabels = <String>[
      for (var c = 0; c < stream.count; c++)
        c < channelXml.length
            ? channelXml[c].getElement('label')?.innerText.trim() ??
                  'Ch${c + 1}'
            : 'Ch${c + 1}',
    ];
    final labels = _normalizeChannelLabels(rawLabels);
    final scales = [
      for (var c = 0; c < stream.count; c++)
        _unitScale(
          c < channelXml.length
              ? channelXml[c].getElement('unit')?.innerText ?? ''
              : '',
        ),
    ];
    final chCount = stream.count;
    final channels = [
      for (var c = 0; c < chCount; c++) Float32List(outCount),
    ];
    var left = 0;
    final t0 = rawTimes.first;
    final tEnd = rawTimes.last;
    final flat = stream.flatValues;
    for (var i = 0; i < outCount; i++) {
      if ((i & 8191) == 0) {
        if (isCancelled?.call() ?? false) {
          throw StateError('File loading cancelled');
        }
        onProgress?.call(.75 + .25 * i / outCount);
      }
      final t = (t0 + i / rate).clamp(t0, tEnd);
      while (left + 1 < rawTimes.length - 1 && rawTimes[left + 1] < t) {
        left++;
      }
      final f = ((t - rawTimes[left]) / (rawTimes[left + 1] - rawTimes[left]))
          .clamp(0.0, 1.0);
      final leftBase = left * chCount;
      final rightBase = (left + 1) * chCount;
      for (var c = 0; c < chCount; c++) {
        channels[c][i] =
            (flat[leftBase + c] * (1 - f) + flat[rightBase + c] * f) *
            scales[c];
      }
    }
    final markers = <EegMarker>[];
    for (final s in streams.values) {
      for (final event in s.events) {
        final t = s.corrected(event.$1) - t0;
        if (t >= 0 && t <= tEnd - t0) {
          markers.add(
            EegMarker(
              type: s.field('name'),
              description: event.$2,
              startSeconds: t,
            ),
          );
        }
      }
    }
    markers.sort((a, b) => a.startSeconds.compareTo(b.startSeconds));
    onProgress?.call(1);
    if (channels.any((channel) => channel.any((v) => !v.isFinite))) {
      throw const FormatException(
        'XDF contains non-finite signal samples. Repair the signal before import.',
      );
    }
    return EegRecording(
      path: path,
      sampleRate: rate,
      labels: labels,
      preview: channels,
      sampleCount: outCount,
      format: 'xdf',
      markers: markers,
      provenance: {
        'xdf_stream_id': stream.id,
        'xdf_stream_name': stream.field('name'),
        'xdf_nominal_rate': stream.rate,
        'xdf_effective_rate': effectiveRate,
        'xdf_uniform_resampling': true,
        'xdf_units': 'microvolts; unspecified channel units assumed microvolts',
      },
    );
  }

  double _unitScale(String unit) => switch (unit
      .trim()
      .toLowerCase()
      .replaceAll('µ', 'u')
      .replaceAll('μ', 'u')) {
    'v' || 'volt' || 'volts' => 1e6,
    'mv' || 'millivolt' || 'millivolts' => 1e3,
    'nv' || 'nanovolt' || 'nanovolts' => 1e-3,
    _ => 1,
  };
}

Future<List<XdfStreamInfo>> inspectXdfInWorker(String path) =>
    Isolate.run(() => XdfLoader().inspect(path));

Future<EegRecording> loadXdfInWorker(String path, {int? streamId}) =>
    Isolate.run(() => XdfLoader().load(path, streamId: streamId));
