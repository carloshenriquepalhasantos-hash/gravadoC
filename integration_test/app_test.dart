import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravadoc/ffmpeg_service.dart';
import 'package:gravadoc/main.dart';
import 'package:integration_test/integration_test.dart';

Future<void> _boot(WidgetTester tester) async {
  await tester.pumpWidget(const GravadocApp());
  // Da tempo de carregar renderers e listar dispositivos via FFmpeg.
  await tester.pump(const Duration(seconds: 3));
}

Finder get _sourceTiles => find.descendant(
      of: find.byType(GridView),
      matching: find.byType(InkWell),
    );

Directory get _outputDir => Directory(
    '${Platform.environment['USERPROFILE']}\\Documents\\gravadoC');

Set<String> _mp4s() => _outputDir.existsSync()
    ? _outputDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.mp4'))
        .map((f) => f.path)
        .toSet()
    : <String>{};

Future<String> _ffprobe() async {
  final ffmpeg = (await locateFfmpeg())!;
  return '${File(ffmpeg).parent.path}\\ffprobe.exe';
}

Future<List<String>> _streamTypes(String path) async {
  final out = await Process.run(await _ffprobe(), [
    '-v', 'error', '-show_entries', 'stream=codec_type',
    '-of', 'csv=p=0', path,
  ]);
  return (out.stdout as String)
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();
}

Future<double> _duration(String path) async {
  final out = await Process.run(await _ffprobe(), [
    '-v', 'error', '-show_entries', 'format=duration',
    '-of', 'default=nw=1:nk=1', path,
  ]);
  return double.parse((out.stdout as String).trim());
}

// Grava por [seconds] e devolve o caminho do novo mp4.
Future<String> _record(WidgetTester tester, {int seconds = 4}) async {
  final before = _mp4s();
  await tester.tap(find.text('Gravar'));
  await tester.pump(const Duration(seconds: 3));
  if (_sourceTiles.evaluate().isNotEmpty) {
    await tester.tap(_sourceTiles.first);
    await tester.pump(const Duration(seconds: 4));
  }
  final erro = find.textContaining('Nao foi possivel iniciar');
  expect(find.text('Parar').evaluate().isNotEmpty, isTrue,
      reason: 'nao entrou em modo gravando; erro na tela: '
          '${erro.evaluate().isNotEmpty}');
  await tester.pump(Duration(seconds: seconds));
  await tester.tap(find.text('Parar'));
  await tester.pump(const Duration(seconds: 3));
  final novos = _mp4s().difference(before);
  expect(novos, hasLength(1), reason: 'esperava 1 mp4 novo');
  return novos.first;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('1. layout inicial mostra todas as areas', (tester) async {
    await _boot(tester);
    for (final text in [
      'gravadoC', 'FONTES', 'Tela', 'Camera', 'AUDIO', 'Microfone',
      'Sistema', 'Abrir pasta', 'Nova gravacao', 'Gravar', 'Exportar',
      'Linha do tempo', 'Entrada', 'Saida',
      'Selecione uma tela ou janela', '00:00',
    ]) {
      expect(find.text(text), findsOneWidget, reason: 'faltou "$text"');
    }
  });

  testWidgets('2. switches de audio respeitam os dispositivos', (tester) async {
    await _boot(tester);
    final devices = await listCaptureDevices((await locateFfmpeg())!);
    final mic = find.widgetWithText(SwitchListTile, 'Microfone');
    final sys = find.widgetWithText(SwitchListTile, 'Sistema');

    expect(tester.widget<SwitchListTile>(sys).onChanged == null,
        devices.systemAudio == null,
        reason: 'Sistema deve ficar desabilitado sem loopback');
    expect(tester.widget<SwitchListTile>(mic).onChanged == null,
        devices.microphone == null);

    if (devices.microphone != null) {
      expect(tester.widget<SwitchListTile>(mic).value, isTrue);
      await tester.tap(mic);
      await tester.pump();
      expect(tester.widget<SwitchListTile>(mic).value, isFalse);
    }
  });

  testWidgets('3. seletor de fonte lista telas/janelas reais', (tester) async {
    await _boot(tester);
    await tester.tap(find.text('Tela'));
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Escolha o que gravar'), findsOneWidget);
    expect(_sourceTiles, findsWidgets);
    debugPrint('FONTES: ${_sourceTiles.evaluate().length}');
  });

  testWidgets('4. escolher fonte mostra preview e nome na lateral',
      (tester) async {
    await _boot(tester);
    await tester.tap(find.text('Tela'));
    await tester.pump(const Duration(seconds: 3));
    await tester.tap(_sourceTiles.first);
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Selecione uma tela ou janela'), findsNothing);
    expect(find.text('Tela'), findsNothing,
        reason: 'botao deve passar a mostrar o nome da fonte');
  });

  testWidgets('5. camera liga e desliga', (tester) async {
    await _boot(tester);
    await tester.tap(find.text('Camera'));
    await tester.pump(const Duration(seconds: 3));
    expect(find.textContaining('Nao foi possivel acessar a camera'),
        findsNothing);
    expect(find.text('Ligando camera...'), findsNothing);
    await tester.tap(find.text('Camera'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Ligando camera...'), findsNothing);
  });

  testWidgets('6. gravar tela + microfone gera mp4 com video e audio',
      (tester) async {
    await _boot(tester);
    final path = await _record(tester);
    expect(File(path).lengthSync(), greaterThan(10 * 1024));
    expect(await _streamTypes(path), containsAll(['video', 'audio']));
    expect(await _duration(path), greaterThan(3));

    // Linha do tempo passa a refletir a gravacao.
    final slider = tester.widget<RangeSlider>(find.byType(RangeSlider));
    expect(slider.max, greaterThan(3));
    expect(slider.values.end, closeTo(slider.max, 0.5));
    await tester.drag(find.byType(RangeSlider), const Offset(-200, 0));
    await tester.pump();
    final moved = tester.widget<RangeSlider>(find.byType(RangeSlider));
    expect(moved.values.start > 0 || moved.values.end < slider.max, isTrue,
        reason: 'arrastar deve mexer em entrada ou saida');
  });

  testWidgets('7. gravar com camera (PiP) funciona e devolve a camera',
      (tester) async {
    await _boot(tester);
    await tester.tap(find.text('Camera'));
    await tester.pump(const Duration(seconds: 3));
    final path = await _record(tester);
    expect(find.text('Camera sendo gravada'), findsNothing,
        reason: 'apos parar, a camera deve voltar ao preview');
    expect(find.textContaining('Nao foi possivel acessar a camera'),
        findsNothing);
    expect(await _streamTypes(path), containsAll(['video', 'audio']));
    expect(await _duration(path), greaterThan(3));
  });

  testWidgets('8. gravar uma janela (nao a tela inteira) gera mp4 menor',
      (tester) async {
    await _boot(tester);
    final before = _mp4s();
    await tester.tap(find.text('Tela'));
    await tester.pump(const Duration(seconds: 3));
    final janela = find.descendant(
      of: find.byType(GridView),
      matching: find.text('gravadoC'),
    );
    expect(janela, findsOneWidget, reason: 'janela do proprio app na lista');
    await tester.tap(janela);
    await tester.pump(const Duration(seconds: 3));

    await tester.tap(find.text('Gravar'));
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('Parar').evaluate().isNotEmpty, isTrue,
        reason: 'gravacao de janela nao iniciou');
    await tester.pump(const Duration(seconds: 3));
    await tester.tap(find.text('Parar'));
    await tester.pump(const Duration(seconds: 3));

    final novos = _mp4s().difference(before);
    expect(novos, hasLength(1));
    final out = await Process.run(await _ffprobe(), [
      '-v', 'error', '-show_entries', 'stream=width,height',
      '-of', 'csv=p=0', novos.first,
    ]);
    final dims = (out.stdout as String).trim().split(',');
    expect(int.parse(dims[0]) * int.parse(dims[1]),
        lessThan(1440 * 900 - 1), reason: 'deveria ser menor que a tela');
    expect(int.parse(dims[0]).isEven && int.parse(dims[1]).isEven, isTrue);
  });

  testWidgets('9. exportar sem gravacao avisa o usuario', (tester) async {
    await _boot(tester);
    await tester.tap(find.text('Exportar'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Grave um video antes de exportar.'), findsOneWidget);
  });

  testWidgets('10. gravar e abrir a gravacao direto no editor', (tester) async {
    await _boot(tester);
    expect(
        tester.widget<FilledButton>(find.byKey(const Key('open-editor'))).onPressed,
        isNull,
        reason: 'sem gravacao o botao Editar fica desabilitado');
    await _record(tester);
    await tester.tap(find.byKey(const Key('open-editor')));
    await tester.pump(const Duration(seconds: 6));
    expect(find.byKey(const ValueKey('clip-0')), findsOneWidget);
    expect(find.byKey(const Key('split')), findsOneWidget);
    expect(find.byKey(const Key('play')), findsOneWidget);
    expect(find.textContaining('Edicao •'), findsOneWidget);
  });
}
