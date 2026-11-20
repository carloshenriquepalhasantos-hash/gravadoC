import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Remove um fundo de cor uniforme (ex.: fundo branco ou verde), nao uma
/// segmentacao por IA. A cor do fundo e estimada pelas bordas e o
/// preenchimento parte das bordas, entao cores iguais *dentro* do objeto
/// so somem se conectadas ao fundo.
///
/// [tolerance] e a distancia maxima de cor (0..441) considerada fundo.
Uint8List removeUniformBackground(Uint8List bytes, {double tolerance = 40}) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) throw const FormatException('Imagem invalida.');
  final image = decoded.convert(numChannels: 4);
  final w = image.width;
  final h = image.height;
  final px = Uint8List.fromList(image.getBytes(order: img.ChannelOrder.rgba));

  final bg = _estimateBackground(px, w, h);
  double dist(int i) {
    if (px[i * 4 + 3] == 0) return 0;
    final dr = px[i * 4] - bg[0];
    final dg = px[i * 4 + 1] - bg[1];
    final db = px[i * 4 + 2] - bg[2];
    return math.sqrt(dr * dr + dg * dg + db * db);
  }

  final isBg = Uint8List(w * h);
  final queue = Queue<int>();
  void push(int x, int y) {
    final i = y * w + x;
    if (isBg[i] == 0 && dist(i) <= tolerance) {
      isBg[i] = 1;
      queue.add(i);
    }
  }

  for (var x = 0; x < w; x++) {
    push(x, 0);
    push(x, h - 1);
  }
  for (var y = 0; y < h; y++) {
    push(0, y);
    push(w - 1, y);
  }
  while (queue.isNotEmpty) {
    final i = queue.removeFirst();
    final x = i % w;
    final y = i ~/ w;
    if (x > 0) push(x - 1, y);
    if (x < w - 1) push(x + 1, y);
    if (y > 0) push(x, y - 1);
    if (y < h - 1) push(x, y + 1);
  }

  // Suaviza a borda: pixels vizinhos do fundo e quase da cor dele ficam
  // parcialmente transparentes, evitando halo serrilhado.
  final soft = tolerance * 0.6;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = y * w + x;
      if (isBg[i] == 1) {
        px[i * 4 + 3] = 0;
        continue;
      }
      final touchesBg = (x > 0 && isBg[i - 1] == 1) ||
          (x < w - 1 && isBg[i + 1] == 1) ||
          (y > 0 && isBg[i - w] == 1) ||
          (y < h - 1 && isBg[i + w] == 1);
      if (!touchesBg || soft <= 0) continue;
      final d = dist(i);
      if (d < tolerance + soft) {
        final a = ((d - tolerance) / soft).clamp(0, 1);
        px[i * 4 + 3] = (px[i * 4 + 3] * a).round();
      }
    }
  }

  final out = img.Image.fromBytes(
    width: w,
    height: h,
    bytes: px.buffer,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
  return Uint8List.fromList(img.encodePng(out));
}

List<double> _estimateBackground(Uint8List px, int w, int h) {
  // Cor mais comum na borda, agrupada em baldes de 16 niveis por canal.
  final buckets = <int, List<double>>{};
  void sample(int x, int y) {
    final i = (y * w + x) * 4;
    final key = (px[i] >> 4) << 8 | (px[i + 1] >> 4) << 4 | (px[i + 2] >> 4);
    final b = buckets.putIfAbsent(key, () => [0, 0, 0, 0]);
    b[0] += px[i];
    b[1] += px[i + 1];
    b[2] += px[i + 2];
    b[3] += 1;
  }

  for (var x = 0; x < w; x++) {
    sample(x, 0);
    sample(x, h - 1);
  }
  for (var y = 1; y < h - 1; y++) {
    sample(0, y);
    sample(w - 1, y);
  }
  final best = buckets.values.reduce((a, b) => a[3] >= b[3] ? a : b);
  return [best[0] / best[3], best[1] / best[3], best[2] / best[3]];
}
