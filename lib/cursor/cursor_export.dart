import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'kinetic_cursor_controller.dart';
import 'kinetic_cursor_options.dart';

Future<File> exportWithCursor({
  required String ffmpegPath,
  required String source,
  required String target,
  required int width,
  required int height,
  required double fps,
  required double duration,
  required List<CursorSample> samples,
  required KineticCursorOptions options,
}) async {
  if (!options.enabled || samples.isEmpty) {
    await Process.run(ffmpegPath, [
      '-y',
      '-i',
      source,
      '-c:v',
      'libx264',
      '-c:a',
      'aac',
      '-movflags',
      '+faststart',
      target,
    ]);
    return File(target);
  }

  final temp = await getTemporaryDirectory();
  final dir = Directory(
    p.join(
      temp.path,
      'gravadoc_cursor_${DateTime.now().millisecondsSinceEpoch}',
    ),
  );
  await dir.create(recursive: true);

  final frameCount = math.max(1, (duration * fps).ceil());
  CursorSample? previous;
  for (var frame = 0; frame < frameCount; frame++) {
    final timeMs = (frame * 1000 / fps).round();
    CursorSample? sample;
    for (var i = samples.length - 1; i >= 0; i--) {
      if (samples[i].timeMs <= timeMs) {
        sample = samples[i];
        break;
      }
    }
    sample ??= samples.first;

    final image = img.Image(width: width, height: height, numChannels: 4);
    _paintCursor(image, sample, previous, frame, options);
    previous = sample;

    final file = File(
      p.join(dir.path, 'cursor_${frame.toString().padLeft(6, '0')}.png'),
    );
    await file.writeAsBytes(img.encodePng(image));
  }

  final sequence = p.join(dir.path, 'cursor_%06d.png');
  final result = await Process.run(ffmpegPath, [
    '-y',
    '-i',
    source,
    '-framerate',
    fps.toStringAsFixed(3),
    '-i',
    sequence,
    '-filter_complex',
    '[0:v][1:v]overlay=0:0:shortest=1,format=yuv420p[vout]',
    '-map',
    '[vout]',
    '-map',
    '0:a?',
    '-c:v',
    'libx264',
    '-preset',
    'veryfast',
    '-crf',
    '20',
    '-c:a',
    'aac',
    '-b:a',
    '192k',
    '-movflags',
    '+faststart',
    target,
  ]);
  if (result.exitCode != 0) {
    throw StateError('${result.stderr}');
  }
  await dir.delete(recursive: true);
  return File(target);
}

void _paintCursor(
  img.Image image,
  CursorSample sample,
  CursorSample? previous,
  int frame,
  KineticCursorOptions options,
) {
  final x = (sample.x * image.width).round();
  final y = (sample.y * image.height).round();
  final scale = options.scale;

  if (options.motionBlur && previous != null) {
    final px = (previous.x * image.width).round();
    final py = (previous.y * image.height).round();
    img.drawLine(
      image,
      x1: px,
      y1: py,
      x2: x,
      y2: y,
      color: img.ColorRgba8(
        (options.highlightColor.toARGB32() >> 16) & 0xff,
        (options.highlightColor.toARGB32() >> 8) & 0xff,
        options.highlightColor.toARGB32() & 0xff,
        (options.motionBlurIntensity * 1.2).round().clamp(20, 160),
      ),
      thickness: math.max(2, (8 * scale).round()),
    );
  }

  img.fillCircle(
    image,
    x: x,
    y: y,
    radius: math.max(8, (18 * scale).round()),
    color: img.ColorRgba8(
      (options.highlightColor.toARGB32() >> 16) & 0xff,
      (options.highlightColor.toARGB32() >> 8) & 0xff,
      options.highlightColor.toARGB32() & 0xff,
      55,
    ),
  );

  final cursorColor = img.ColorRgba8(255, 255, 255, 255);
  final outline = img.ColorRgba8(20, 20, 20, 255);
  final px = [
    x,
    (x + 7 * scale).round(),
    (x + 13 * scale).round(),
    (x + 20 * scale).round(),
  ];
  final py = [
    y,
    (y + 20 * scale).round(),
    (y + 13 * scale).round(),
    (y + 19 * scale).round(),
  ];
  for (var i = 0; i < px.length; i++) {
    final j = (i + 1) % px.length;
    img.drawLine(
      image,
      x1: px[i],
      y1: py[i],
      x2: px[j],
      y2: py[j],
      color: outline,
      thickness: 3,
    );
  }
  img.drawLine(
    image,
    x1: px[0],
    y1: py[0],
    x2: px[1],
    y2: py[1],
    color: cursorColor,
    thickness: 1,
  );
  img.drawLine(
    image,
    x1: px[1],
    y1: py[1],
    x2: px[2],
    y2: py[2],
    color: cursorColor,
    thickness: 1,
  );
}
