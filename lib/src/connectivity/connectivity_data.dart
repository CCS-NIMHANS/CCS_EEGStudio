// Reads connectivity matrices, graph-theory measures and ROI definitions back from a *.features.csv.
//
// Column conventions written by the engine:
//   conn_gcmi_to_<L>, conn_te_time_to_<L>, conn_pair_<measure>_<Band>_to_<L>   channel (row) -> channel L (column)
//   graph_<net>_<measure>        per-channel graph measures      (net = gcmi | te_time | <measure>_<Band>)
//   graphglobal_<net>_<measure>  overall graph measures (the same value on every row)
//   conn_(mic|mim|gc|gc_tr|gc_contrast)_<Band>   ROI -> ROI multivariate connectivity (one value per band)
//   connectivity_settings        JSON incl. the ROI channel lists that were actually used
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

const List<String> kNodeMeasures = [
  'community',
  'strength',
  'out_strength',
  'in_strength',
  'degree',
  'clustering',
  'efficiency',
  'local_efficiency',
  'betweenness',
  'eigenvector',
  'participation',
  'within_module_z',
  'net_flow',
];

const List<String> kGlobalMeasures = [
  'char_path_length',
  'global_efficiency',
  'mean_clustering',
  'transitivity',
  'modularity',
  'n_communities',
  'assortativity',
  'reciprocity',
  'density',
];

const Map<String, String> kMeasureTitles = {
  'community': 'Louvain community',
  'strength': 'Strength',
  'out_strength': 'Out-strength (drive)',
  'in_strength': 'In-strength (received)',
  'degree': 'Degree',
  'clustering': 'Clustering coefficient',
  'efficiency': 'Nodal efficiency',
  'local_efficiency': 'Local efficiency',
  'betweenness': 'Betweenness centrality',
  'eigenvector': 'Eigenvector centrality',
  'participation': 'Participation coefficient',
  'within_module_z': 'Within-module degree z',
  'net_flow': 'Net flow (out − in)/(out + in)',
  'char_path_length': 'Characteristic path length',
  'global_efficiency': 'Global efficiency',
  'mean_clustering': 'Mean clustering',
  'transitivity': 'Transitivity',
  'modularity': 'Modularity Q (Louvain)',
  'n_communities': 'Number of communities',
  'assortativity': 'Assortativity',
  'reciprocity': 'Reciprocity (directed)',
  'density': 'Edge density',
};

class ConnNetwork {
  ConnNetwork({
    required this.key,
    required this.title,
    required this.directed,
    required this.labels,
    required this.matrix,
    required this.nodeMeasures,
    required this.globalMeasures,
  });

  final String key;
  final String title;

  /// Directed: matrix[i][j] is the influence of labels[i] (source) on labels[j] (target).
  final bool directed;
  final List<String> labels;
  final List<List<double>> matrix;
  final Map<String, List<double>> nodeMeasures;
  final Map<String, double> globalMeasures;

  List<int>? get communities {
    final c = nodeMeasures['community'];
    if (c == null || c.any((v) => v.isNaN)) return null;
    return [for (final v in c) v.round()];
  }
}

class RoiDefinition {
  RoiDefinition(this.seedName, this.seed, this.targetName, this.target);
  final String seedName;
  final List<String> seed;
  final String targetName;
  final List<String> target;
}

class ConnectivityData {
  ConnectivityData(this.networks, this.multivariate, this.roi, this.path);
  final List<ConnNetwork> networks;

  /// key like 'mic_Alpha' -> mean value over all rows
  final Map<String, double> multivariate;
  final RoiDefinition? roi;
  final String path;

  static List<String> _split(String line) {
    final out = <String>[];
    final b = StringBuffer();
    var q = false;
    for (var i = 0; i < line.length; i++) {
      final c = line[i];
      if (q) {
        if (c == '"') {
          if (i + 1 < line.length && line[i + 1] == '"') {
            b.write('"');
            i++;
          } else {
            q = false;
          }
        } else {
          b.write(c);
        }
      } else if (c == '"') {
        q = true;
      } else if (c == ',') {
        out.add(b.toString());
        b.clear();
      } else {
        b.write(c);
      }
    }
    out.add(b.toString());
    return out;
  }

  static String _title(String key) {
    if (key == 'gcmi') return 'Gaussian-copula MI (GCMI)';
    if (key == 'te_time') return 'Transfer entropy';
    final p = key.split('_');
    return p.length >= 2
        ? '${p.first.toUpperCase().replaceAll('CIPLV', 'ciPLV').replaceAll('WPLI', 'wPLI')} · ${p.sublist(1).join('_')}'
        : key;
  }

  static Future<ConnectivityData> load(String path) async {
    final lines = await File(path).readAsLines();
    if (lines.isEmpty) throw const FormatException('Empty feature file');
    final header = _split(lines.first);
    final chan = header.indexOf('Chan');
    if (chan < 0) throw const FormatException('No Chan column in the feature file');
    final settingsIdx = header.indexOf('connectivity_settings');

    final pairRe = RegExp(r'^conn_pair_(.+?)_to_(.+)$');
    final gcmiRe = RegExp(r'^conn_gcmi_to_(.+)$');
    final teRe = RegExp(r'^conn_te_time_to_(.+)$');
    final nodeRe = RegExp('^graph_(.+?)_(${kNodeMeasures.join('|')})\$');
    final globalRe = RegExp('^graphglobal_(.+?)_(${kGlobalMeasures.join('|')})\$');
    final mvRe = RegExp(r'^conn_(mic|mim|gc_contrast|gc_tr|gc)_(.+)$');
    final oldGlobalRe = RegExp(r'^graph_(.+?)_(global_efficiency|density)$');

    final matrixCols = <String, List<(int, String)>>{}; // net -> (column index, target label)
    final nodeCols = <String, Map<String, int>>{}; // net -> measure -> column
    final globalCols = <String, Map<String, int>>{};
    final mvCols = <String, int>{};
    for (var i = 0; i < header.length; i++) {
      final h = header[i];
      Match? m;
      if ((m = gcmiRe.firstMatch(h)) != null) {
        matrixCols.putIfAbsent('gcmi', () => []).add((i, m!.group(1)!));
      } else if ((m = teRe.firstMatch(h)) != null) {
        matrixCols.putIfAbsent('te_time', () => []).add((i, m!.group(1)!));
      } else if ((m = pairRe.firstMatch(h)) != null) {
        matrixCols.putIfAbsent(m!.group(1)!, () => []).add((i, m.group(2)!));
      } else if ((m = oldGlobalRe.firstMatch(h)) != null) {
        globalCols.putIfAbsent(m!.group(1)!, () => {})[m.group(2)!] = i;
      } else if ((m = nodeRe.firstMatch(h)) != null) {
        nodeCols.putIfAbsent(m!.group(1)!, () => {})[m.group(2)!] = i;
      } else if ((m = globalRe.firstMatch(h)) != null) {
        globalCols.putIfAbsent(m!.group(1)!, () => {})[m.group(2)!] = i;
      } else if ((m = mvRe.firstMatch(h)) != null) {
        mvCols['${m!.group(1)}_${m.group(2)}'] = i;
      }
    }

    // accumulate
    final chanOrder = <String>[];
    final sums = <String, Map<String, Map<String, List<double>>>>{}; // net -> chan -> targetLabel -> [sum,count]
    final nodeSums = <String, Map<String, Map<String, List<double>>>>{}; // net -> measure -> chan -> [sum,count]
    final nodeVotes = <String, Map<String, Map<int, int>>>{}; // net -> chan -> community votes
    final globSums = <String, Map<String, List<double>>>{};
    final mvSums = <String, List<double>>{};
    String? settingsJson;
    for (var r = 1; r < lines.length; r++) {
      if (lines[r].isEmpty) continue;
      final f = _split(lines[r]);
      if (f.length <= chan) continue;
      final ch = f[chan];
      if (!chanOrder.contains(ch)) chanOrder.add(ch);
      double? v(int i) => i < f.length ? double.tryParse(f[i]) : null;
      matrixCols.forEach((net, cols) {
        final row = sums.putIfAbsent(net, () => {}).putIfAbsent(ch, () => {});
        for (final (i, target) in cols) {
          final x = v(i);
          if (x == null || x.isNaN) continue;
          final acc = row.putIfAbsent(target, () => [0, 0]);
          acc[0] += x;
          acc[1] += 1;
        }
      });
      nodeCols.forEach((net, cols) {
        cols.forEach((measure, i) {
          final x = v(i);
          if (x == null || x.isNaN) return;
          if (measure == 'community') {
            final votes = nodeVotes.putIfAbsent(net, () => {}).putIfAbsent(ch, () => {});
            votes[x.round()] = (votes[x.round()] ?? 0) + 1;
          } else {
            final acc = nodeSums
                .putIfAbsent(net, () => {})
                .putIfAbsent(measure, () => {})
                .putIfAbsent(ch, () => [0, 0]);
            acc[0] += x;
            acc[1] += 1;
          }
        });
      });
      globalCols.forEach((net, cols) {
        cols.forEach((measure, i) {
          final x = v(i);
          if (x == null || x.isNaN) return;
          final acc = globSums.putIfAbsent(net, () => {}).putIfAbsent(measure, () => [0, 0]);
          acc[0] += x;
          acc[1] += 1;
        });
      });
      mvCols.forEach((k, i) {
        final x = v(i);
        if (x == null || x.isNaN) return;
        final acc = mvSums.putIfAbsent(k, () => [0, 0]);
        acc[0] += x;
        acc[1] += 1;
      });
      if (settingsJson == null && settingsIdx >= 0 && settingsIdx < f.length && f[settingsIdx].trim().startsWith('{')) {
        settingsJson = f[settingsIdx];
      }
    }

    final networks = <ConnNetwork>[];
    for (final net in matrixCols.keys) {
      final targets = [for (final c in matrixCols[net]!) c.$2];
      final labels = [for (final c in chanOrder) if (targets.contains(c)) c];
      final extra = [for (final t in targets) if (!labels.contains(t)) t];
      labels.addAll(extra);
      final n = labels.length;
      final matrix = List.generate(n, (_) => List<double>.filled(n, double.nan));
      for (var i = 0; i < n; i++) {
        final row = sums[net]?[labels[i]];
        if (row == null) continue;
        for (var j = 0; j < n; j++) {
          final acc = row[labels[j]];
          if (acc != null && acc[1] > 0 && i != j) matrix[i][j] = acc[0] / acc[1];
        }
      }
      final nodes = <String, List<double>>{};
      nodeSums[net]?.forEach((measure, perChan) {
        nodes[measure] = [
          for (final l in labels)
            perChan[l] == null || perChan[l]![1] == 0 ? double.nan : perChan[l]![0] / perChan[l]![1],
        ];
      });
      final votes = nodeVotes[net];
      if (votes != null) {
        nodes['community'] = [
          for (final l in labels)
            () {
              final v = votes[l];
              if (v == null || v.isEmpty) return double.nan;
              final best = v.entries.reduce((a, b) => a.value >= b.value ? a : b);
              return best.key.toDouble();
            }(),
        ];
      }
      final globals = <String, double>{};
      globSums[net]?.forEach((k, acc) => globals[k] = acc[0] / math.max(1, acc[1]));
      networks.add(ConnNetwork(
        key: net,
        title: _title(net),
        directed: net == 'te_time',
        labels: labels,
        matrix: matrix,
        nodeMeasures: nodes,
        globalMeasures: globals,
      ));
    }
    final mv = <String, double>{for (final e in mvSums.entries) e.key: e.value[0] / math.max(1, e.value[1])};
    RoiDefinition? roi;
    if (settingsJson != null) {
      try {
        final j = jsonDecode(settingsJson) as Map<String, dynamic>;
        final seed = (j['roi_seed'] as List?)?.map((e) => '$e').toList() ?? const <String>[];
        final target = (j['roi_target'] as List?)?.map((e) => '$e').toList() ?? const <String>[];
        if (seed.isNotEmpty && target.isNotEmpty) {
          roi = RoiDefinition('${j['roi_seed_name'] ?? ''}', seed, '${j['roi_target_name'] ?? ''}', target);
        }
      } catch (_) {}
    }
    return ConnectivityData(networks, mv, roi, path);
  }
}
