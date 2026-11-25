import 'package:flutter_test/flutter_test.dart';
import 'package:sweep_app/tracking/signal_tracker.dart';

void main() {
  final base = DateTime(2026, 1, 1, 12);
  late DateTime now;
  late SignalTracker t;

  setUp(() {
    now = base;
    t = SignalTracker(clock: () => now);
  });

  // Moves the fake clock to base + ms and feeds one new reading.
  void feedAt(int ms, int rssi) {
    now = base.add(Duration(milliseconds: ms));
    t.update(rssi, now);
  }

  test('ignores a reading that was already used', () {
    final stamp = now;
    expect(t.update(-60, stamp), isTrue);
    expect(t.update(-90, stamp), isFalse); // same timestamp: a repeat
    expect(t.update(-90, stamp.subtract(const Duration(seconds: 1))), isFalse); // older
    expect(t.ema, closeTo(-60, 0.001));
  });

  test('a repeated result does not make the device look freshly seen', () {
    final stamp = now;
    t.update(-60, stamp);
    expect(t.isFresh(), isTrue);
    now = now.add(const Duration(seconds: 10));
    t.update(-60, stamp); // repeat of the same result
    expect(t.isFresh(), isFalse);
  });

  test('a single spike barely moves the value', () {
    feedAt(0, -60);
    feedAt(200, -60);
    feedAt(400, -60);
    feedAt(600, -95); // one bad reading
    expect(t.ema!, greaterThan(-70));
  });

  test('a sustained change is followed quickly', () {
    feedAt(0, -60);
    feedAt(200, -60);
    feedAt(400, -60);
    feedAt(600, -45);
    feedAt(800, -45);
    feedAt(1000, -45);
    expect(t.ema!, greaterThan(-50));
  });

  test('trend is unknown with too few readings', () {
    feedAt(0, -60);
    expect(t.trend, Trend.unknown);
  });

  test('trend is warmer when the signal gets stronger', () {
    feedAt(0, -80);
    feedAt(500, -80);
    feedAt(3000, -60);
    feedAt(3500, -60);
    expect(t.trend, Trend.warmer);
  });

  test('trend is colder when the signal gets weaker', () {
    feedAt(0, -60);
    feedAt(500, -60);
    feedAt(3000, -80);
    feedAt(3500, -80);
    expect(t.trend, Trend.colder);
  });

  test('trend is steady when the signal stays about the same', () {
    feedAt(0, -65);
    feedAt(500, -66);
    feedAt(3000, -65);
    feedAt(3500, -66);
    expect(t.trend, Trend.steady);
  });

  test('weak signals show as 20+ m, strong ones as a short distance', () {
    t.update(-95, now);
    expect(t.distanceText, '20+ m');

    final strong = SignalTracker(clock: () => now);
    strong.update(-50, now);
    expect(strong.distanceText, '~0.4 m');
  });

  test('heat is 0 with no reading and clamps at 1', () {
    expect(t.heat, closeTo(0, 0.001));
    t.update(-30, now);
    expect(t.heat, closeTo(1, 0.001));
  });
}