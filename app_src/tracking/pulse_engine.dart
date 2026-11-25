import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum PulseOutput { sound, vibrate, off }

/// Emits a "pulse" at a rate that follows how close the tracked device is
/// (like a car parking sensor). Each pulse also plays a beep or a vibration,
/// depending on [output]. The screen listens to [pulses] to draw ripples.
class PulseEngine {
  PulseEngine({required this.heat});

  /// 0.0 (far) .. 1.0 (very close), or null when there is no fresh signal.
  final double? Function() heat;

  final ValueNotifier<int> pulses = ValueNotifier<int>(0);
  PulseOutput output = PulseOutput.sound;

  final AudioPlayer _player = AudioPlayer();
  final Map<int, Uint8List> _tones = {};
  bool _running = false;

  void start() {
    if (_running) return;
    _running = true;
    _loop();
  }

  void stop() {
    _running = false;
    try {
      _player.stop();
    } catch (_) {}
  }

  void dispose() {
    _running = false;
    _player.dispose();
    pulses.dispose();
  }

  Future<void> _loop() async {
    while (_running) {
      final h = heat();
      if (h == null) {
        await Future.delayed(const Duration(milliseconds: 300));
        continue;
      }
      pulses.value++;
      if (h >= 0.12) _emit(h); // stay quiet for very weak signals
      // 1100 ms when far, down to 120 ms when very close.
      final ms = (1100 - 980 * pow(h, 1.5)).round();
      await Future.delayed(Duration(milliseconds: ms));
    }
  }

  void _emit(double h) {
    switch (output) {
      case PulseOutput.sound:
        try {
          unawaited(_player.play(BytesSource(_tone(h)), volume: 1.0));
        } catch (_) {}
      case PulseOutput.vibrate:
        HapticFeedback.mediumImpact();
      case PulseOutput.off:
        break;
    }
  }

  // Pitch rises with proximity: five steps from low to high.
  Uint8List _tone(double h) {
    final level = (h * 5).floor().clamp(0, 4);
    const freqs = [600.0, 800.0, 1000.0, 1300.0, 1600.0];
    return _tones.putIfAbsent(level, () => _wav(freqs[level], 90));
  }

  // Builds a short 16-bit mono WAV sine beep in memory (no asset files).
  static Uint8List _wav(double freq, int ms) {
    const rate = 22050;
    final n = rate * ms ~/ 1000;
    final data = ByteData(44 + n * 2);
    void tag(int offset, String text) {
      for (var i = 0; i < text.length; i++) {
        data.setUint8(offset + i, text.codeUnitAt(i));
      }
    }

    tag(0, 'RIFF');
    data.setUint32(4, 36 + n * 2, Endian.little);
    tag(8, 'WAVE');
    tag(12, 'fmt ');
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little); // PCM
    data.setUint16(22, 1, Endian.little); // mono
    data.setUint32(24, rate, Endian.little);
    data.setUint32(28, rate * 2, Endian.little);
    data.setUint16(32, 2, Endian.little);
    data.setUint16(34, 16, Endian.little);
    tag(36, 'data');
    data.setUint32(40, n * 2, Endian.little);

    for (var i = 0; i < n; i++) {
      final edge = min(i, n - i) / (rate * 0.008); // 8 ms fade in/out, no clicks
      final fade = edge > 1 ? 1.0 : edge;
      final v = (sin(2 * pi * freq * i / rate) * 0.6 * fade * 32767).round();
      data.setInt16(44 + i * 2, v, Endian.little);
    }
    return data.buffer.asUint8List();
  }
}
