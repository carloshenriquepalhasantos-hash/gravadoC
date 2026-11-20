import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gravadoc/ffmpeg_service.dart';

const _sample = '''
[in#0 @ 0000024e8a1bcec0] "DV20 USB CAMERA" (video)
[in#0 @ 0000024e8a1bcec0]   Alternative name "@device_pnp_\\\\?\\usb#vid_4c4a"
[in#0 @ 0000024e8a1bcec0] "Microfone (USB Audio)" (audio)
[in#0 @ 0000024e8a1bcec0]   Alternative name "@device_cm_{33D9A762}\\wave_{2230}"
[in#0 @ 0000024e8a1bcec0] "Mixagem estereo (Realtek)" (audio)
Error opening input file dummy.
''';

void main() {
  group('parseDshowDevices', () {
    test('separa video e audio e ignora alternative names', () {
      final devices = parseDshowDevices(_sample);
      expect(devices.video, ['DV20 USB CAMERA']);
      expect(devices.audio, [
        'Microfone (USB Audio)',
        'Mixagem estereo (Realtek)',
      ]);
    });

    test('distingue microfone de loopback do sistema', () {
      final devices = parseDshowDevices(_sample);
      expect(devices.camera, 'DV20 USB CAMERA');
      expect(devices.microphone, 'Microfone (USB Audio)');
      expect(devices.systemAudio, 'Mixagem estereo (Realtek)');
    });

    test('sem dispositivos retorna tudo nulo', () {
      final devices = parseDshowDevices('Error opening input file dummy.');
      expect(devices.camera, isNull);
      expect(devices.microphone, isNull);
      expect(devices.systemAudio, isNull);
    });
  });

  group('buildRecordArgs', () {
    test('somente tela: sem audio e sem camera', () {
      final args = buildRecordArgs(const RecordingRequest(outputPath: 'a.mp4'));
      expect(args, containsAllInOrder(['-f', 'gdigrab', '-i', 'desktop']));
      expect(args, contains('-an'));
      expect(args, isNot(contains('dshow')));
      expect(args.last, 'a.mp4');
    });

    test('janela usa title= e camera vira overlay PiP', () {
      final args = buildRecordArgs(
        const RecordingRequest(
          outputPath: 'a.mp4',
          windowTitle: 'Bloco de Notas',
          camera: 'DV20 USB CAMERA',
        ),
      );
      expect(args, contains('title=Bloco de Notas'));
      expect(args, contains('video=DV20 USB CAMERA'));
      final filter = args[args.indexOf('-filter_complex') + 1];
      expect(filter, contains("overlay=x='min"));
      expect(filter, contains("y='min"));
    });

    test('microfone + sistema sao mixados em uma unica faixa', () {
      final args = buildRecordArgs(
        const RecordingRequest(
          outputPath: 'a.mp4',
          camera: 'cam',
          microphone: 'mic',
          systemAudio: 'loop',
        ),
      );
      final filter = args[args.indexOf('-filter_complex') + 1];
      expect(filter, contains('[2:a][3:a]amix=inputs=2'));
      expect(args, containsAllInOrder(['-map', '[a]']));
    });

    test('so microfone mapeia o indice certo sem camera', () {
      final args = buildRecordArgs(
        const RecordingRequest(outputPath: 'a.mp4', microphone: 'mic'),
      );
      expect(args, containsAllInOrder(['-map', '1:a']));
    });

    test('pode gravar microfone e sistema em faixas separadas', () {
      final args = buildRecordArgs(
        const RecordingRequest(
          outputPath: 'a.mp4',
          microphone: 'mic',
          systemAudio: 'loop',
          separateTracks: true,
        ),
      );
      expect(args, containsAllInOrder(['-map', '1:a']));
      expect(args, containsAllInOrder(['-map', '2:a']));
      expect(args, isNot(contains('[2:a][3:a]amix=inputs=2')));
    });

    test('camera respeita posicao e tamanho configurados', () {
      final args = buildRecordArgs(
        const RecordingRequest(
          outputPath: 'a.mp4',
          camera: 'cam',
          cameraX: 0.2,
          cameraY: 0.3,
          cameraWidth: 240,
          cameraHeight: 160,
        ),
      );
      final filter = args[args.indexOf('-filter_complex') + 1];
      expect(filter, contains('trunc(iw*'));
      expect(filter, contains("W*0.2000"));
      expect(filter, contains("H*0.3000"));
    });

    test(
      'previa da camera sai como segundo output sem tirar a camera do video',
      () {
        final args = buildRecordArgs(
          const RecordingRequest(
            outputPath: 'a.mp4',
            camera: 'cam',
            previewPath: 'p.jpg',
          ),
        );
        final filter = args[args.indexOf('-filter_complex') + 1];
        expect(filter, contains('[1:v]split=2[camsrc][campv]'));
        expect(filter, contains('[camsrc]scale='));
        expect(filter, contains('[campv]fps=8,scale=480:-2[pv]'));
        expect(args.indexOf('a.mp4'), lessThan(args.indexOf('[pv]')));
        expect(args.last, 'p.jpg');
      },
    );

    test('sem camera nao gera previa', () {
      final args = buildRecordArgs(
        const RecordingRequest(outputPath: 'a.mp4', previewPath: 'p.jpg'),
      );
      expect(args, isNot(contains('[pv]')));
      expect(args.last, 'a.mp4');
    });
  });

  group('exportRecording (FFmpeg real)', () {
    late Directory dir;
    String? ffmpeg;

    setUpAll(() async {
      ffmpeg = await locateFfmpeg();
      dir = await Directory.systemTemp.createTemp('gravadoc_test');
    });

    tearDownAll(() => dir.delete(recursive: true));

    Future<double> duration(String path) async {
      final probe = '${File(ffmpeg!).parent.path}\\ffprobe.exe';
      final out = await Process.run(probe, [
        '-v',
        'error',
        '-show_entries',
        'format=duration',
        '-of',
        'default=nw=1:nk=1',
        path,
      ]);
      return double.parse((out.stdout as String).trim());
    }

    test('corta 2s..5s de um video de 8s', () async {
      if (ffmpeg == null) markTestSkipped('FFmpeg nao instalado');
      final source = '${dir.path}\\origem.mp4';
      final gen = await Process.run(ffmpeg!, [
        '-y',
        '-loglevel',
        'error',
        '-f',
        'lavfi',
        '-i',
        'testsrc=size=320x240:rate=30',
        '-f',
        'lavfi',
        '-i',
        'sine=frequency=440',
        '-t',
        '8',
        '-c:v',
        'libx264',
        '-pix_fmt',
        'yuv420p',
        '-c:a',
        'aac',
        source,
      ]);
      expect(gen.exitCode, 0, reason: '${gen.stderr}');

      final target = '${dir.path}\\corte.mp4';
      final result = await exportRecording(
        source: source,
        target: target,
        startSeconds: 2,
        endSeconds: 5,
        totalSeconds: 8,
        ffmpegPath: ffmpeg,
      );
      expect(result, ExportResult.cut);
      expect(await duration(target), closeTo(3.0, 0.2));
    });

    test('sem corte apenas copia o arquivo', () async {
      if (ffmpeg == null) markTestSkipped('FFmpeg nao instalado');
      final source = '${dir.path}\\origem.mp4';
      final target = '${dir.path}\\copia.mp4';
      final result = await exportRecording(
        source: source,
        target: target,
        startSeconds: 0,
        endSeconds: 8,
        totalSeconds: 8,
        ffmpegPath: ffmpeg,
      );
      expect(result, ExportResult.copied);
      expect(File(target).lengthSync(), File(source).lengthSync());
    });

    test(
      'copia sobrescreve destino ja existente (seletor cria arquivo vazio)',
      () async {
        if (ffmpeg == null) markTestSkipped('FFmpeg nao instalado');
        final source = '${dir.path}\\origem.mp4';
        final target = '${dir.path}\\vazio.mp4';
        File(target).writeAsBytesSync(const []);
        await exportRecording(
          source: source,
          target: target,
          startSeconds: 0,
          endSeconds: 8,
          totalSeconds: 8,
          ffmpegPath: ffmpeg,
        );
        expect(File(target).lengthSync(), greaterThan(0));
      },
    );
  });
}
