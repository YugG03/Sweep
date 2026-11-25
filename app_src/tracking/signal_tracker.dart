import 'dart:math';

enum Trend { warmer, colder, steady, unknown }

class _Sample {
  final DateTime time;
  final int rssi;
  const _Sample(this.time, this.rssi);
}

/// Turns raw signal readings (RSSI) into a smoothed value, a warmer/colder
/// trend and a rough distance. Pure Dart, so it can be unit-tested; [clock]
/// can be replaced in tests.
class SignalTracker {
  SignalTracker({DateTime Function()? clock})
      : _clock = clock ?? DateTime.now,
        lastSeen = (clock ?? DateTime.now)();

  final DateTime Function() _clock;

  double? ema; // smoothed RSSI
  int peak = -127;
  DateTime lastSeen;
  DateTime? _lastStamp; // timestamp of the newest scan result already used
  final List<_Sample> _samples = []; // last few seconds of raw readings

  /// Feed one reading. [stamp] is the scan result's own timestamp: the plugin
  /// re-delivers old results with every batch, so repeats are ignored.
  /// Returns true when the reading was new and used.
  bool update(int rssi, DateTime stamp) {
    final prevStamp = _lastStamp;
    if (prevStamp != null && !stamp.isAfter(prevStamp)) return false;
    _lastStamp = stamp;

    final now = _clock();
    lastSeen = now;
    _samples.add(_Sample(now, rssi));
    _samples.removeWhere((s) => now.difference(s.time).inMilliseconds > 5000);

    // Median of the last 3 readings removes single-reading spikes; a fast
    // smoother then keeps the value responsive while walking.
    final int recent;
    if (_samples.length >= 3) {
      final last3 = _samples.sublist(_samples.length - 3).map((s) => s.rssi).toList()
        ..sort();
      recent = last3[1];
    } else {
      recent = rssi;
    }
    final prev = ema;
    ema = prev == null ? recent.toDouble() : 0.5 * recent + 0.5 * prev;
    if (rssi > peak) peak = rssi;
    return true;
  }

  /// True when a new reading arrived within [maxAge].
  bool isFresh([Duration maxAge = const Duration(seconds: 3)]) =>
      _clock().difference(lastSeen) <= maxAge;

  /// Warmer / colder: last ~1.5 s compared with the ~3 s before that.
  Trend get trend {
    final now = _clock();
    int age(_Sample s) => now.difference(s.time).inMilliseconds;
    final newer = _samples.where((s) => age(s) <= 1500).toList();
    final older = _samples.where((s) {
      final a = age(s);
      return a > 1500 && a <= 4500;
    }).toList();
    if (newer.length < 2 || older.length < 2) return Trend.unknown;

    double avg(List<_Sample> l) =>
        l.map((s) => s.rssi).reduce((a, b) => a + b) / l.length;
    final d = avg(newer) - avg(older);
    if (d >= 3) return Trend.warmer;
    if (d <= -3) return Trend.colder;
    return Trend.steady;
  }

  // Very rough: fixed 1 m reference of -59 dBm. Treat as "about", never exact.
  double get meters {
    const n = 2.5;
    return pow(10, (-59 - (ema ?? -100)) / (10 * n)).toDouble();
  }

  String get distanceText =>
      meters > 20 ? '20+ m' : '~${meters.toStringAsFixed(1)} m';

  // 0.0 (cold) .. 1.0 (hot)
  double get heat => (((ema ?? -100) + 100) / 60).clamp(0.0, 1.0);
}
