import 'package:flutter/scheduler.dart';
import 'package:flutter/foundation.dart';

class CursorSample {
  const CursorSample({
    required this.x,
    required this.y,
    required this.timeMs,
    this.isClick = false,
  });

  final double x;
  final double y;
  final int timeMs;
  final bool isClick;
}

class KineticCursorController extends ChangeNotifier {
  KineticCursorController({required TickerProvider vsync}) {
    _ticker = vsync.createTicker(_tick);
  }

  late final Ticker _ticker;
  final List<CursorSample> samples = [];
  double renderedX = 0.5;
  double renderedY = 0.5;
  double targetX = 0.5;
  double targetY = 0.5;
  double smoothing = 65;
  int lastClickMs = -1000;
  bool _started = false;

  void start() {
    if (_started) return;
    _started = true;
    _ticker.start();
  }

  void stop() {
    if (!_started) return;
    _started = false;
    _ticker.stop();
  }

  void setSmoothing(double value) => smoothing = value;

  void addSample({
    required double x,
    required double y,
    required int timeMs,
    bool isClick = false,
  }) {
    targetX = x.clamp(0, 1).toDouble();
    targetY = y.clamp(0, 1).toDouble();
    renderedX = targetX;
    renderedY = targetY;
    samples.add(
      CursorSample(x: targetX, y: targetY, timeMs: timeMs, isClick: isClick),
    );
    if (isClick) lastClickMs = timeMs;
    if (samples.length > 2000) {
      samples.removeRange(0, samples.length - 2000);
    }
  }

  void clear() {
    samples.clear();
    renderedX = targetX = 0.5;
    renderedY = targetY = 0.5;
    lastClickMs = -1000;
    notifyListeners();
  }

  void _tick(Duration elapsed) {
    final factor = (smoothing.clamp(0, 100).toDouble() / 100 * 0.2 + 0.05)
        .clamp(0.05, 0.25)
        .toDouble();
    renderedX += (targetX - renderedX) * factor;
    renderedY += (targetY - renderedY) * factor;
    notifyListeners();
  }

  CursorSample? sampleAt(int timeMs) {
    if (samples.isEmpty) return null;
    for (var i = samples.length - 1; i >= 0; i--) {
      if (samples[i].timeMs <= timeMs) return samples[i];
    }
    return samples.first;
  }

  @override
  void dispose() {
    stop();
    _ticker.dispose();
    super.dispose();
  }
}
