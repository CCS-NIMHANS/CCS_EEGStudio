import 'dart:math' as math;

/// Specification for one sequential stage in a multi-stage batch pipeline.
class BatchStageSpec {
  const BatchStageSpec({
    required this.id,
    required this.label,
    required this.fileCount,
    this.priorWeightPerFile = 1.0,
  });

  final String id;
  final String label;
  final int fileCount;

  /// Empirical relative runtime weight per file compared to Preprocessing = 1.0.
  final double priorWeightPerFile;
}

class BatchStageSnapshot {
  const BatchStageSnapshot({
    required this.id,
    required this.label,
    required this.fileCount,
    required this.completedCount,
    required this.skippedCount,
    required this.failedCount,
    required this.isActive,
    required this.isCompleted,
  });

  final String id;
  final String label;
  final int fileCount;
  final int completedCount;
  final int skippedCount;
  final int failedCount;
  final bool isActive;
  final bool isCompleted;
}

class _StageProgressState {
  _StageProgressState(this.spec) : fileCount = spec.fileCount;

  final BatchStageSpec spec;
  int fileCount;
  int completedCount = 0;
  int skippedCount = 0;
  int failedCount = 0;
  bool isCompleted = false;
  String? currentFilePath;
  double currentFileFraction = 0.0;
  DateTime? currentFileStartedAt;
  final List<double> activeDurationsSec = [];

  double? get emaDurationSec {
    if (activeDurationsSec.isEmpty) return null;
    var ema = activeDurationsSec.first;
    for (var i = 1; i < activeDurationsSec.length; i++) {
      ema = 0.55 * ema + 0.45 * activeDurationsSec[i];
    }
    return ema;
  }
}

/// Formats a [Duration] into a concise human-readable string (e.g. `42s`, `3m 18s`, `1h 05m`).
String formatBatchDuration(Duration d) {
  final totalSec = math.max(0, d.inSeconds);
  final hours = totalSec ~/ 3600;
  final mins = (totalSec % 3600) ~/ 60;
  final secs = totalSec % 60;
  if (hours > 0) {
    return '${hours}h ${mins.toString().padLeft(2, '0')}m';
  }
  if (mins > 0) {
    return '${mins}m ${secs.toString().padLeft(2, '0')}s';
  }
  return '${secs}s';
}

/// Unified monotonic multi-stage progress and adaptive ETA tracker.
///
/// Guarantees:
/// - Overall progress never resets when transitioning between stages.
/// - Overall progress never decreases and never shows 100.0% until [finish] is called.
/// - Skipped files do not distort active per-file duration estimates.
/// - ETA auto-adjusts after each completed file and continuously from mid-file substep progress.
class BatchProgressTracker {
  BatchProgressTracker({
    required List<BatchStageSpec> stages,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now,
       _stages = [for (final s in stages) _StageProgressState(s)],
       startedAt = (now ?? DateTime.now)();

  final DateTime Function() _now;
  final List<_StageProgressState> _stages;
  final DateTime startedAt;

  int _activeIndex = 0;
  bool _finished = false;
  double _lastOverallProgress = 0.0;

  bool get isFinished => _finished;
  int get activeStageIndex => _activeIndex;
  Duration get elapsed => _now().difference(startedAt);

  BatchStageSnapshot get activeStage => _snapshotOf(_activeIndex);

  List<BatchStageSnapshot> get stageSnapshots => [
    for (var i = 0; i < _stages.length; i++) _snapshotOf(i),
  ];

  BatchStageSnapshot _snapshotOf(int i) {
    if (_stages.isEmpty) {
      return const BatchStageSnapshot(
        id: 'none',
        label: 'Batch',
        fileCount: 0,
        completedCount: 0,
        skippedCount: 0,
        failedCount: 0,
        isActive: false,
        isCompleted: true,
      );
    }
    final st = _stages[i];
    return BatchStageSnapshot(
      id: st.spec.id,
      label: st.spec.label,
      fileCount: st.fileCount,
      completedCount: st.completedCount,
      skippedCount: st.skippedCount,
      failedCount: st.failedCount,
      isActive: !_finished && i == _activeIndex,
      isCompleted: st.isCompleted,
    );
  }

  /// Transitions to stage [stageIndex] without resetting overall progress.
  void startStage(int stageIndex, {int? actualFileCount}) {
    if (_stages.isEmpty) return;
    final target = stageIndex.clamp(0, _stages.length - 1);
    for (var i = 0; i < target; i++) {
      _stages[i].isCompleted = true;
      _stages[i].currentFilePath = null;
      _stages[i].currentFileStartedAt = null;
      _stages[i].currentFileFraction = 0.0;
    }
    _activeIndex = target;
    final st = _stages[target];
    if (actualFileCount != null && actualFileCount >= 0) {
      st.fileCount = actualFileCount;
    }
    st.completedCount = 0;
    st.skippedCount = 0;
    st.failedCount = 0;
    st.isCompleted = false;
    st.currentFilePath = null;
    st.currentFileFraction = 0.0;
    st.currentFileStartedAt = null;
    _updateMonotonicProgress();
  }

  /// Finds stage index by id or returns current index.
  void startStageById(String id, {int? actualFileCount}) {
    final idx = _stages.indexWhere((s) => s.spec.id == id);
    if (idx >= 0) {
      startStage(idx, actualFileCount: actualFileCount);
    }
  }

  void beginFile(String path) {
    if (_stages.isEmpty || _finished) return;
    final st = _stages[_activeIndex];
    st.currentFilePath = path;
    st.currentFileFraction = 0.0;
    st.currentFileStartedAt = _now();
    _updateMonotonicProgress();
  }

  void updateFileProgress(double fraction) {
    if (_stages.isEmpty || _finished) return;
    final st = _stages[_activeIndex];
    // Cap active file progress at 0.99 so overall bar never hits 100% prematurely.
    final clamped = fraction.clamp(0.0, 0.99);
    if (clamped > st.currentFileFraction) {
      st.currentFileFraction = clamped;
    }
    _updateMonotonicProgress();
  }

  void completeFile({bool skipped = false, bool failed = false}) {
    if (_stages.isEmpty || _finished) return;
    final st = _stages[_activeIndex];
    if (skipped) {
      st.skippedCount++;
    } else {
      if (st.currentFileStartedAt != null) {
        final durSec =
            _now().difference(st.currentFileStartedAt!).inMilliseconds / 1000.0;
        if (durSec >= 0.05 && durSec.isFinite) {
          st.activeDurationsSec.add(durSec);
        }
      }
      if (failed) {
        st.failedCount++;
      }
    }
    st.completedCount++;
    st.currentFilePath = null;
    st.currentFileStartedAt = null;
    st.currentFileFraction = 0.0;
    if (st.fileCount > 0 && st.completedCount >= st.fileCount) {
      st.isCompleted = true;
    }
    _updateMonotonicProgress();
  }

  void finish() {
    _finished = true;
    for (final st in _stages) {
      st.isCompleted = true;
      st.currentFilePath = null;
      st.currentFileStartedAt = null;
      st.currentFileFraction = 0.0;
    }
    _lastOverallProgress = 1.0;
  }

  double get activeFileFraction {
    if (_stages.isEmpty) return 0.0;
    return _stages[_activeIndex].currentFileFraction;
  }

  double get overallProgress => _updateMonotonicProgress();

  double _updateMonotonicProgress() {
    if (_finished || _stages.isEmpty) {
      _lastOverallProgress = 1.0;
      return 1.0;
    }

    var totalWeight = 0.0;
    var doneWeight = 0.0;

    for (var i = 0; i < _stages.length; i++) {
      final st = _stages[i];
      final count = math.max(1, st.fileCount);
      final stageWeight = count * math.max(0.05, st.spec.priorWeightPerFile);
      totalWeight += stageWeight;

      if (st.isCompleted || i < _activeIndex) {
        doneWeight += stageWeight;
      } else if (i == _activeIndex) {
        final units =
            (st.completedCount + st.currentFileFraction).clamp(0.0, count.toDouble());
        doneWeight += (units / count) * stageWeight;
      }
    }

    final raw = totalWeight > 0 ? (doneWeight / totalWeight) : 0.0;
    final bounded = raw.clamp(_lastOverallProgress, 0.995);
    _lastOverallProgress = bounded;
    return _lastOverallProgress;
  }

  /// Adaptive estimated remaining duration across the active stage and any
  /// queued subsequent stages, auto-adjusted as files/substeps finish.
  /// Returns `null` during initial warm-up before reliable timing exists.
  ({Duration remaining, bool isPreliminary})? get estimatedRemainingInfo {
    if (_finished) {
      return (remaining: Duration.zero, isPreliminary: false);
    }
    if (_stages.isEmpty) return null;

    final now = _now();
    final active = _stages[_activeIndex];
    final currentElapsedSec = active.currentFileStartedAt != null
        ? math.max(
            0.0,
            now.difference(active.currentFileStartedAt!).inMilliseconds / 1000.0,
          )
        : 0.0;

    // Prior-calibrated unit time from earlier non-skipped completed stages
    double? calibratedBaseUnitSec;
    for (var i = 0; i < _activeIndex; i++) {
      final prev = _stages[i];
      final ema = prev.emaDurationSec;
      if (ema != null) {
        calibratedBaseUnitSec = ema / math.max(0.05, prev.spec.priorWeightPerFile);
      }
    }

    final activeEma = active.emaDurationSec;
    final remainingWholeFiles = math.max(
      0,
      active.fileCount -
          active.completedCount -
          (active.currentFilePath != null ? 1 : 0),
    );

    double? activeRemainingSec;
    double? baseUnitSec;
    var preliminary = false;

    if (activeEma != null) {
      // Blend completed file EMA with live current file substep projection when informative
      double projectedFileSec = activeEma;
      if (active.currentFilePath != null &&
          active.currentFileFraction >= 0.12 &&
          currentElapsedSec >= 2.0) {
        final liveProjection = currentElapsedSec / active.currentFileFraction;
        projectedFileSec = 0.65 * activeEma + 0.35 * liveProjection;
      }
      final currentRem = active.currentFilePath != null
          ? math.max(0.0, projectedFileSec - currentElapsedSec)
          : 0.0;
      activeRemainingSec = currentRem + remainingWholeFiles * activeEma;
      final activeUnit = activeEma / math.max(0.05, active.spec.priorWeightPerFile);
      baseUnitSec = calibratedBaseUnitSec != null
          ? 0.4 * calibratedBaseUnitSec + 0.6 * activeUnit
          : activeUnit;
    } else if (calibratedBaseUnitSec != null) {
      // Starting next stage using calibrated speed from earlier stage
      final priorPerFile =
          calibratedBaseUnitSec * math.max(0.05, active.spec.priorWeightPerFile);
      double projectedFileSec = priorPerFile;
      if (active.currentFilePath != null &&
          active.currentFileFraction >= 0.12 &&
          currentElapsedSec >= 2.0) {
        final liveProjection = currentElapsedSec / active.currentFileFraction;
        projectedFileSec = 0.5 * priorPerFile + 0.5 * liveProjection;
      }
      final currentRem = active.currentFilePath != null
          ? math.max(0.0, projectedFileSec - currentElapsedSec)
          : 0.0;
      activeRemainingSec = currentRem + remainingWholeFiles * projectedFileSec;
      baseUnitSec = calibratedBaseUnitSec;
      preliminary = true;
    } else if (active.currentFilePath != null &&
        active.currentFileFraction >= 0.12 &&
        currentElapsedSec >= 3.0) {
      // Mid-file estimate during very first file
      final estFileSec = currentElapsedSec / active.currentFileFraction;
      final currentRem = math.max(0.0, estFileSec - currentElapsedSec);
      activeRemainingSec = currentRem + remainingWholeFiles * estFileSec;
      baseUnitSec = estFileSec / math.max(0.05, active.spec.priorWeightPerFile);
      preliminary = true;
    } else {
      return null;
    }

    var futureSec = 0.0;
    for (var i = _activeIndex + 1; i < _stages.length; i++) {
      final st = _stages[i];
      if (st.isCompleted) continue;
      futureSec += st.fileCount * math.max(0.05, st.spec.priorWeightPerFile) * baseUnitSec;
    }

    final totalRemSec = math.max(0.0, activeRemainingSec + futureSec);
    return (
      remaining: Duration(milliseconds: (totalRemSec * 1000).round()),
      isPreliminary: preliminary,
    );
  }

  Duration? get estimatedRemaining => estimatedRemainingInfo?.remaining;
}
