// Gera windows/runner/resources/app_icon.ico (varios tamanhos).
// Uso: dart run tool/make_icon.dart
import 'dart:io';

import 'package:image/image.dart' as img;

img.Image _draw(int size) {
  final base = img.Image(width: 256, height: 256, numChannels: 4);
  img.fill(base, color: img.ColorRgba8(0, 0, 0, 0));
  img.fillRect(base,
      x1: 8, y1: 8, x2: 247, y2: 247, radius: 52,
      color: img.ColorRgba8(16, 20, 29, 255));
  const green = [182, 255, 74];
  img.fillCircle(base,
      x: 128, y: 128, radius: 88,
      color: img.ColorRgba8(green[0], green[1], green[2], 255));
  img.fillCircle(base,
      x: 128, y: 128, radius: 70, color: img.ColorRgba8(16, 20, 29, 255));
  img.fillCircle(base,
      x: 128, y: 128, radius: 50,
      color: img.ColorRgba8(green[0], green[1], green[2], 255));
  if (size == 256) return base;
  return img.copyResize(base,
      width: size, height: size, interpolation: img.Interpolation.average);
}

void main() {
  final sizes = [16, 24, 32, 48, 64, 128, 256];
  final bytes = img.IcoEncoder().encodeImages([for (final s in sizes) _draw(s)]);
  final out = File('windows/runner/resources/app_icon.ico');
  out.writeAsBytesSync(bytes);
  stdout.writeln('Icone gerado: ${out.path} (${bytes.length} bytes)');
}
