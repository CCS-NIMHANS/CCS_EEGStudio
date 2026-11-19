import 'package:flutter/material.dart';

/// Definition of an ERP component window, polarity, and electrode ROI.
class ErpComponentSpec {
  const ErpComponentSpec({
    required this.name,
    required this.windowStartMs,
    required this.windowEndMs,
    required this.polarity,
    required this.roiChannels,
    this.colorValue = 0xFF38BDF8,
  });

  final String name;
  final double windowStartMs;
  final double windowEndMs;
  final double polarity; // +1.0 for positive, -1.0 for negative
  final List<String> roiChannels;
  final int colorValue;

  static const List<int> paletteColorValues = [
    0xFF38BDF8, // sky blue
    0xFFA78BFA, // violet
    0xFF34D399, // emerald
    0xFFFBBF24, // amber
    0xFFF472B6, // pink
    0xFFFB7185, // rose
  ];

  String get roiString => roiChannels.join(', ');
  Color get color => Color(colorValue);

  ErpComponentSpec copyWith({
    String? name,
    double? windowStartMs,
    double? windowEndMs,
    double? polarity,
    List<String>? roiChannels,
    int? colorValue,
  }) => ErpComponentSpec(
    name: name ?? this.name,
    windowStartMs: windowStartMs ?? this.windowStartMs,
    windowEndMs: windowEndMs ?? this.windowEndMs,
    polarity: polarity ?? this.polarity,
    roiChannels: roiChannels ?? List<String>.from(this.roiChannels),
    colorValue: colorValue ?? this.colorValue,
  );

  Map<String, dynamic> toRustJson() => {
    'name': name,
    'window': [windowStartMs / 1000.0, windowEndMs / 1000.0],
    'polarity': polarity,
    'roi': roiChannels,
  };

  Map<String, dynamic> toJson() => {
    'name': name,
    'window_start_ms': windowStartMs,
    'window_end_ms': windowEndMs,
    'polarity': polarity,
    'roi': roiChannels,
    'color': colorValue,
  };

  factory ErpComponentSpec.fromJson(
    Map<String, dynamic> json, {
    int index = 0,
  }) {
    double startMs = 300.0;
    double endMs = 600.0;
    final w = json['window'];
    if (w is List && w.length >= 2) {
      startMs = (w[0] as num).toDouble() * 1000.0;
      endMs = (w[1] as num).toDouble() * 1000.0;
    } else {
      startMs = (json['window_start_ms'] as num?)?.toDouble() ?? 300.0;
      endMs = (json['window_end_ms'] as num?)?.toDouble() ?? 600.0;
    }
    return ErpComponentSpec(
      name: '${json['name'] ?? 'Component ${index + 1}'}',
      windowStartMs: startMs,
      windowEndMs: endMs,
      polarity: (json['polarity'] as num?)?.toDouble() ?? 1.0,
      roiChannels: ((json['roi'] as List?) ?? const [])
          .map((e) => '$e'.trim())
          .where((s) => s.isNotEmpty)
          .toList(),
      colorValue:
          (json['color'] as num?)?.toInt() ??
          paletteColorValues[index % paletteColorValues.length],
    );
  }

  static List<ErpComponentSpec> oddballPresets() => const [
    ErpComponentSpec(
      name: 'N100',
      windowStartMs: 80,
      windowEndMs: 150,
      polarity: -1.0,
      roiChannels: ['Cz', 'Fz'],
      colorValue: 0xFF38BDF8,
    ),
    ErpComponentSpec(
      name: 'P200',
      windowStartMs: 150,
      windowEndMs: 250,
      polarity: 1.0,
      roiChannels: ['Cz', 'FC1', 'FC2'],
      colorValue: 0xFFA78BFA,
    ),
    ErpComponentSpec(
      name: 'P300',
      windowStartMs: 280,
      windowEndMs: 450,
      polarity: 1.0,
      roiChannels: ['Pz', 'Cz'],
      colorValue: 0xFF34D399,
    ),
  ];

  static List<ErpComponentSpec> defaultForProfile({
    required String componentName,
    required double startMs,
    required double endMs,
    required double polarity,
    required String roiText,
  }) {
    final channels = roiText
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    return [
      ErpComponentSpec(
        name: componentName.trim().isEmpty ? 'Primary ERP' : componentName.trim(),
        windowStartMs: startMs,
        windowEndMs: endMs,
        polarity: polarity,
        roiChannels: channels.isEmpty ? ['Cz'] : channels,
        colorValue: paletteColorValues.first,
      ),
    ];
  }
}
