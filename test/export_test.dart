import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gravadoc/editor/export_builder.dart';
import 'package:gravadoc/editor/project.dart';
import 'package:gravadoc/ffmpeg_service.dart';
import 'package:image/image.dart' as img;

EditProject _project({double duration = 10, bool audio = true}) => EditProject(
  source: 'x.mp4',
  info: MediaInfo(
    width: 320,
    height: 240,
    fps: 30,
    duration: duration,
    hasAudio: audio,
  ),
);

const _fade = TransitionSpec(xfade: 'fade', name: 'Fade', duration: 1);

void main() {
  group('EditProject', () {
    test('dividir cria dois clipes e preserva a duracao', () {
      final p = _project();
      expect(p.splitAt(4), isTrue);
      expect(p.clips.map((c) => [c.start, c.end]), [
        [0.0, 4.0],
        [4.0, 10.0],
      ]);
      expect(p.duration, 10);
    });

    test('nao divide perto demais da borda', () {
      final p = _project();
      expect(p.splitAt(0.05), isFalse);
      expect(p.splitAt(9.95), isFalse);
      expect(p.clips, hasLength(1));
    });

    test('remover trecho do meio encurta a linha do tempo', () {
      final p = _project()
        ..splitAt(3)
        ..splitAt(6);
      expect(p.removeClip(1), isTrue);
      expect(p.duration, closeTo(7, 1e-9));
      expect(
        p.removeClip(0) && p.removeClip(0),
        isFalse,
        reason: 'o ultimo clipe nunca pode ser removido',
      );
    });

    test('reordenar troca os clipes', () {
      final p = _project()..splitAt(4);
      expect(p.moveClip(0, 1), isTrue);
      expect(p.clips.first.start, 4);
      expect(p.moveClip(0, -1), isFalse);
    });

    test('transicao sobrepoe clipes e encurta a saida', () {
      final p = _project()..splitAt(5);
      p.setTransition(1, _fade);
      expect(p.transitionInto(1), 1);
      expect(p.duration, closeTo(9, 1e-9));
      expect(p.clipStart(1), closeTo(4, 1e-9));
    });

    test('transicao e limitada a 45% do clipe vizinho', () {
      final p = _project(duration: 4)..splitAt(2);
      p.setTransition(1, _fade.copyWith(duration: 3));
      expect(p.transitionInto(1), closeTo(0.9, 1e-9));
    });

    test('locate mapeia tempo de saida para tempo de origem', () {
      final p = _project()
        ..splitAt(3)
        ..splitAt(6)
        ..removeClip(1);
      expect(p.locate(2).index, 0);
      final at = p.locate(4);
      expect(at.index, 1);
      expect(at.source, closeTo(7, 1e-9));
    });
  });

  group('parseProbe', () {
    test('le dimensoes, fps, duracao e audio', () {
      final info = parseProbe('''
{"streams":[{"codec_type":"video","width":1440,"height":900,
"avg_frame_rate":"30000/1001"},{"codec_type":"audio"}],
"format":{"duration":"12.5"}}''');
      expect(info.width, 1440);
      expect(info.fps, closeTo(29.97, 0.01));
      expect(info.duration, 12.5);
      expect(info.hasAudio, isTrue);
    });

    test('fps invalido cai para 30', () {
      final info = parseProbe(
        '{"streams":[{"codec_type":"video","width":2,"height":2,'
        '"avg_frame_rate":"0/0"}],"format":{"duration":"1"}}',
      );
      expect(info.fps, 30);
      expect(info.hasAudio, isFalse);
    });
  });

  group('buildExportPlan', () {
    test('usa xfade e acrossfade quando ha transicao', () {
      final p = _project()..splitAt(5);
      p.setTransition(1, _fade);
      final graph =
          buildExportPlan(p, output: 'o.mp4').args[buildExportPlan(
                p,
                output: 'o.mp4',
              ).args.indexOf('-filter_complex') +
              1];
      expect(
        graph,
        contains('xfade=transition=fade:duration=1.000:offset=4.000'),
      );
      expect(graph, contains('acrossfade=d=1.000'));
    });

    test('sem transicao usa concat', () {
      final p = _project()..splitAt(5);
      final args = buildExportPlan(p, output: 'o.mp4').args;
      expect(args[args.indexOf('-filter_complex') + 1], contains('concat=n=2'));
    });

    test('ajustes de voz e ruido entram no filtergraph', () {
      final p = _project()
        ..noiseReduction = true
        ..voiceEnhancement = true
        ..originalAudioGain = 1.5;
      final graph =
          buildExportPlan(p, output: 'o.mp4').args[buildExportPlan(
                p,
                output: 'o.mp4',
              ).args.indexOf('-filter_complex') +
              1];
      expect(graph, contains('afftdn=nf=-25'));
      expect(graph, contains('acompressor=threshold=-18dB'));
      expect(graph, contains('volume=1.500'));
    });
  });

  group('exportacao real (FFmpeg)', () {
    late String ffmpeg;
    late Directory dir;
    late String video;
    late String silent;
    late String beep;
    late String png;

    Future<void> run(List<String> args) async {
      final r = await Process.run(ffmpeg, [
        '-y',
        '-loglevel',
        'error',
        ...args,
      ]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
    }

    Future<EditProject> load(String path) async =>
        EditProject(source: path, info: await probeMedia(ffmpeg, path));

    Future<void> export(
      EditProject p,
      String out, {
      bool preview = false,
    }) async {
      final job = await ExportJob.start(
        ffmpeg,
        buildExportPlan(p, output: out, preview: preview),
      );
      await job.done;
    }

    Future<MediaInfo> info(String path) => probeMedia(ffmpeg, path);

    Future<img.Image> frameAt(String path, double t) async {
      final out = '${dir.path}\\frame_${t}_${path.hashCode}.png';
      await run(['-ss', '$t', '-i', path, '-frames:v', '1', out]);
      return img.decodePng(File(out).readAsBytesSync())!;
    }

    setUpAll(() async {
      ffmpeg = (await locateFfmpeg())!;
      dir = await Directory.systemTemp.createTemp('gravadoc_export');
      video = '${dir.path}\\video.mp4';
      silent = '${dir.path}\\silent.mp4';
      beep = '${dir.path}\\beep.wav';
      png = '${dir.path}\\red.png';
      await run([
        '-f',
        'lavfi',
        '-i',
        'color=c=blue:s=320x240:r=30',
        '-f',
        'lavfi',
        '-i',
        'sine=frequency=300',
        '-t',
        '8',
        '-c:v',
        'libx264',
        '-pix_fmt',
        'yuv420p',
        '-c:a',
        'aac',
        video,
      ]);
      await run([
        '-f',
        'lavfi',
        '-i',
        'color=c=blue:s=320x240:r=30',
        '-t',
        '4',
        '-c:v',
        'libx264',
        '-pix_fmt',
        'yuv420p',
        silent,
      ]);
      await run(['-f', 'lavfi', '-i', 'sine=frequency=880:d=0.5', beep]);
      final red = img.Image(width: 100, height: 100, numChannels: 4);
      img.fill(red, color: img.ColorRgba8(255, 0, 0, 255));
      File(png).writeAsBytesSync(img.encodePng(red));
    });

    tearDownAll(() => dir.delete(recursive: true));

    test('todas as transicoes do app existem neste FFmpeg', () async {
      final r = await Process.run(ffmpeg, [
        '-hide_banner',
        '-h',
        'filter=xfade',
      ]);
      final text = '${r.stdout}';
      for (final name in kXfadeTransitions) {
        expect(text, contains(RegExp('\\b$name\\b')), reason: name);
      }
    });

    test('corte com transicao: duracao = soma - sobreposicao', () async {
      final p = await load(video);
      p.splitAt(4);
      p.setTransition(1, _fade);
      final out = '${dir.path}\\trans.mp4';
      await export(p, out);
      final i = await info(out);
      expect(i.duration, closeTo(7, 0.2));
      expect(i.hasAudio, isTrue);
    });

    test('remover trecho do meio e reordenar', () async {
      final p = await load(video);
      p
        ..splitAt(2)
        ..splitAt(5)
        ..removeClip(1)
        ..moveClip(0, 1);
      final out = '${dir.path}\\cut.mp4';
      await export(p, out);
      expect((await info(out)).duration, closeTo(5, 0.2));
    });

    test('imagem semitransparente aparece so no intervalo', () async {
      final p = await load(video);
      p.overlays.add(
        OverlayImage(
          id: 'a',
          path: png,
          end: 4,
          start: 1,
          scale: 0.5,
          opacity: 0.5,
          rotation: 30,
        ),
      );
      final out = '${dir.path}\\overlay.mp4';
      await export(p, out);

      final inside = await frameAt(out, 2);
      final outside = await frameAt(out, 6);
      final c = inside.getPixel(160, 120);
      final o = outside.getPixel(160, 120);
      // Fundo azul; vermelho a 50% deixa canal vermelho ~ metade e azul ~ metade.
      expect(c.r, greaterThan(70), reason: 'imagem deveria tingir de vermelho');
      expect(c.r, lessThan(200), reason: 'opacidade 50% nao pode ser total');
      expect(o.r, lessThan(40), reason: 'fora do intervalo nao ha imagem');
    });

    test('opacidade total cobre o fundo e posicao x/y move a imagem', () async {
      final p = await load(video);
      p.overlays.add(
        OverlayImage(id: 'a', path: png, end: 8, scale: 0.25, x: 0.2, y: 0.2),
      );
      final out = '${dir.path}\\pos.mp4';
      await export(p, out);
      final f = await frameAt(out, 1);
      expect(f.getPixel(64, 48).r, greaterThan(200), reason: 'no canto 20%');
      expect(f.getPixel(250, 200).r, lessThan(40), reason: 'longe da imagem');
    });

    test('som inserido e mixado ao audio original', () async {
      final p = await load(video);
      p.sounds.add(SoundItem(id: 's', name: 'beep', path: beep, at: 2));
      final out = '${dir.path}\\sfx.mp4';
      await export(p, out);
      final i = await info(out);
      expect(i.hasAudio, isTrue);
      expect(i.duration, closeTo(8, 0.2));
    });

    test('video sem audio ganha faixa quando ha som', () async {
      final p = await load(silent);
      expect(p.hasAudio, isFalse);
      p.sounds.add(SoundItem(id: 's', name: 'beep', path: beep, at: 1));
      final out = '${dir.path}\\silent_sfx.mp4';
      await export(p, out);
      expect((await info(out)).hasAudio, isTrue);
    });

    test('som da transicao entra no ponto da transicao', () async {
      final p = await load(video);
      p.splitAt(4);
      p.setTransition(1, _fade.copyWith(sfxPath: beep));
      final out = '${dir.path}\\trans_sfx.mp4';
      await export(p, out);
      expect((await info(out)).hasAudio, isTrue);
    });

    test('video sem audio e sem sons exporta sem faixa de audio', () async {
      final p = await load(silent);
      final out = '${dir.path}\\silent_out.mp4';
      await export(p, out);
      expect((await info(out)).hasAudio, isFalse);
    });

    test('preview reduz para 360p', () async {
      final p = await load(video);
      final out = '${dir.path}\\prev.mp4';
      await export(p, out, preview: true);
      expect((await info(out)).height, 360);
    });

    test('progresso chega a 100% e cancelar interrompe', () async {
      final p = await load(video);
      final values = <double>[];
      final job = await ExportJob.start(
        ffmpeg,
        buildExportPlan(p, output: '${dir.path}\\prog.mp4'),
        onProgress: values.add,
      );
      await job.done;
      expect(values.last, 1);

      final slow = await ExportJob.start(
        ffmpeg,
        buildExportPlan(p, output: '${dir.path}\\cancel.mp4'),
      );
      slow.cancel();
      await expectLater(slow.done, throwsA(anything));
    });
  });
}

// Evita aviso de import nao usado em plataformas sem Uint8List diretamente.
// ignore: unused_element
Uint8List _unused() => Uint8List(0);
