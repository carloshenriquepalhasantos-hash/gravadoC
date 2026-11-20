import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravadoc/editor/editor_controller.dart';
import 'package:gravadoc/editor/editor_page.dart';
import 'package:gravadoc/editor/export_builder.dart';
import 'package:gravadoc/editor/project.dart';
import 'package:gravadoc/ffmpeg_service.dart';
import 'package:gravadoc/packs/pack_repository.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;

late Directory _dir;
late String _ffmpeg;
late String _video;
late String _redPng;
late String _whiteBgPng;

Future<void> _run(List<String> args) async {
  final r = await Process.run(_ffmpeg, ['-y', '-loglevel', 'error', ...args]);
  expect(r.exitCode, 0, reason: '${r.stderr}');
}

Future<EditorController> _controller({bool open = true}) async {
  final c = EditorController(
    ffmpegPath: _ffmpeg,
    repository: PackRepository(Directory(p.join(_dir.path, 'packs'))),
  );
  await c.init();
  if (open) await c.openVideo(_video);
  return c;
}

Future<GlobalKey<EditorPageState>> _show(
    WidgetTester tester, EditorController c) async {
  tester.view.physicalSize = const Size(1500, 950);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final key = GlobalKey<EditorPageState>();
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
    home: Scaffold(body: EditorPage(key: key, controller: c)),
  ));
  await tester.pump(const Duration(seconds: 2));
  return key;
}

double _labelSeconds(WidgetTester tester) {
  final text = tester.widget<Text>(find.byKey(const Key('time-label'))).data!;
  final first = text.split('/').first.trim().split(':');
  return int.parse(first[0]) * 60 + double.parse(first[1]);
}

Future<void> _tapTimeline(WidgetTester tester, EditProject p, double t) async {
  final box = find.byKey(const Key('timeline'));
  final pps = (tester.getSize(box).width - 24) / p.duration;
  await tester.tapAt(tester.getTopLeft(box) + Offset(12 + t * pps, 8));
  await tester.pump(const Duration(milliseconds: 600));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    MediaKit.ensureInitialized();
    _ffmpeg = (await locateFfmpeg())!;
    _dir = await Directory.systemTemp.createTemp('gravadoc_editor');
    _video = p.join(_dir.path, 'origem.mp4');
    _redPng = p.join(_dir.path, 'red.png');
    _whiteBgPng = p.join(_dir.path, 'whitebg.png');
    await _run([
      '-f', 'lavfi', '-i', 'testsrc2=size=640x360:rate=30',
      '-f', 'lavfi', '-i', 'sine=frequency=440', '-t', '10',
      '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac', _video,
    ]);
    final red = img.Image(width: 80, height: 80, numChannels: 4);
    img.fill(red, color: img.ColorRgba8(255, 0, 0, 255));
    File(_redPng).writeAsBytesSync(img.encodePng(red));
    final logo = img.Image(width: 80, height: 80, numChannels: 4);
    img.fill(logo, color: img.ColorRgba8(255, 255, 255, 255));
    img.fillCircle(logo,
        x: 40, y: 40, radius: 25, color: img.ColorRgba8(0, 120, 255, 255));
    File(_whiteBgPng).writeAsBytesSync(img.encodePng(logo));
  });

  tearDownAll(() => _dir.delete(recursive: true));

  testWidgets('1. sem video mostra o estado vazio com botao de abrir',
      (tester) async {
    final c = await _controller(open: false);
    await _show(tester, c);
    expect(find.byKey(const Key('open-video')), findsOneWidget);
    expect(find.text('Imagem'), findsOneWidget);
    expect(find.text('Transicoes'), findsOneWidget);
    expect(find.text('Sons'), findsOneWidget);
    expect(find.text('Pacotes'), findsOneWidget);
  });

  testWidgets('2. carrega o video e reproduz avancando o cursor',
      (tester) async {
    final c = await _controller();
    await _show(tester, c);
    expect(find.byKey(const ValueKey('clip-0')), findsOneWidget);
    expect(find.textContaining('/ 00:10.0'), findsOneWidget);
    expect(_labelSeconds(tester), 0);

    await tester.tap(find.byKey(const Key('play')));
    await tester.pump(const Duration(seconds: 3));
    final t = _labelSeconds(tester);
    expect(t, greaterThan(1.5), reason: 'cursor deveria avancar ao reproduzir');

    await tester.tap(find.byKey(const Key('play')));
    await tester.pump(const Duration(milliseconds: 500));
    final stopped = _labelSeconds(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(_labelSeconds(tester), closeTo(stopped, 0.3),
        reason: 'pausado nao pode avancar');
  });

  testWidgets('3. clicar na linha do tempo move o cursor', (tester) async {
    final c = await _controller();
    await _show(tester, c);
    await _tapTimeline(tester, c.project!, 5);
    expect(_labelSeconds(tester), closeTo(5, 0.6));
  });

  testWidgets('4. dividir, excluir e reordenar clipes', (tester) async {
    final c = await _controller();
    await _show(tester, c);
    await _tapTimeline(tester, c.project!, 4);
    await tester.tap(find.byKey(const Key('split')));
    await tester.pump(const Duration(milliseconds: 500));
    expect(c.project!.clips, hasLength(2));
    expect(find.byKey(const ValueKey('clip-1')), findsOneWidget);
    expect(c.project!.duration, closeTo(10, 0.01));

    await tester.tap(find.byKey(const ValueKey('clip-1')));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byKey(const Key('move-left')));
    await tester.pump(const Duration(milliseconds: 500));
    expect(c.project!.clips.first.start, greaterThan(3),
        reason: 'clipe 2 deveria ter ido para o inicio');

    await tester.tap(find.byKey(const Key('delete-clip')));
    await tester.pump(const Duration(milliseconds: 500));
    expect(c.project!.clips, hasLength(1));
    expect(c.project!.duration, closeTo(4, 0.5));
    expect(find.byKey(const Key('delete-clip')).evaluate().isNotEmpty, isTrue);
    expect(
        tester
            .widget<IconButton>(find.byKey(const Key('delete-clip')))
            .onPressed,
        isNull,
        reason: 'nao pode excluir o ultimo clipe');
  });

  testWidgets('5. reproducao pula o trecho removido do meio', (tester) async {
    final c = await _controller();
    final key = await _show(tester, c);
    final proj = c.project!;
    proj.splitAt(3);
    proj.splitAt(6);
    proj.removeClip(1); // remove 3s..6s
    await tester.pump(const Duration(seconds: 1));
    expect(proj.duration, closeTo(7, 0.05));

    await _tapTimeline(tester, proj, 2);
    await tester.tap(find.byKey(const Key('play')));
    await tester.pump(const Duration(seconds: 3));

    // ~5s na linha do tempo = ja no 2o clipe, com origem a partir de 6s.
    final timeline = _labelSeconds(tester);
    final source = key.currentState!.sourcePosition.inMilliseconds / 1000;
    expect(timeline, greaterThan(3.3));
    expect(source, greaterThan(6.0),
        reason: 'player deveria ter pulado de 3s para 6s (origem=$source)');
    await tester.tap(find.byKey(const Key('play')));
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('6. aplicar transicao com som pelo painel', (tester) async {
    final c = await _controller();
    await _show(tester, c);
    c.project!.splitAt(5);
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.byKey(const ValueKey('clip-1')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('transition-1')));
    await tester.pump(const Duration(milliseconds: 600));

    final search = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == 'Buscar transicao');
    await tester.enterText(search, 'slideleft');
    await tester.pump(const Duration(milliseconds: 500));

    final tile = find.byKey(const ValueKey('tr-gravadoc-basico-slideleft'));
    expect(tile, findsOneWidget);
    expect(find.byKey(const ValueKey('tr-gravadoc-basico-fade')), findsNothing,
        reason: 'a busca deve filtrar as outras transicoes');
    await tester.tap(tile);
    await tester.pump(const Duration(milliseconds: 500));

    final transition = c.project!.clips[1].transition!;
    expect(transition.xfade, 'slideleft');
    expect(transition.sfxPath, endsWith('whoosh.wav'),
        reason: 'slideleft do pacote inicial leva o som whoosh');
    expect(find.byKey(const Key('current-transition')), findsOneWidget);
    expect(c.project!.duration, lessThan(10));

    await tester.tap(find.byKey(const Key('remove-transition')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(c.project!.clips[1].transition, isNull);
    expect(c.project!.duration, closeTo(10, 0.01));
  });

  testWidgets('7. imagem: aparece no preview, arrasta e ajusta transparencia',
      (tester) async {
    final c = await _controller();
    await _show(tester, c);
    final o = c.addOverlay(_redPng);
    await tester.pump(const Duration(milliseconds: 600));

    final widget = find.byKey(ValueKey('overlay-${o.id}'));
    expect(widget, findsOneWidget);
    expect(find.byKey(ValueKey('overlay-bar-${o.id}')), findsOneWidget);

    final x0 = o.x;
    await tester.drag(widget, const Offset(120, 0));
    await tester.pump(const Duration(milliseconds: 300));
    expect(o.x, greaterThan(x0), reason: 'arrastar deve mover a imagem');

    o.opacity = 0.4;
    o.rotation = 25;
    o.scale = 0.4;
    c.project!.touch();
    await tester.pump(const Duration(milliseconds: 300));
    final opacity = tester.widget<Opacity>(find.descendant(
        of: widget, matching: find.byType(Opacity)));
    expect(opacity.opacity, closeTo(0.4, 0.01));

    c.removeOverlay(o);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(ValueKey('overlay-${o.id}')), findsNothing);
  });

  testWidgets('8. remover fundo gera PNG transparente e restaura o original',
      (tester) async {
    final c = await _controller();
    await _show(tester, c);
    final o = c.addOverlay(_whiteBgPng);
    await c.removeOverlayBackground(o, 40);
    expect(o.path, isNot(_whiteBgPng));
    expect(o.originalPath, _whiteBgPng);
    final out = img.decodePng(File(o.path).readAsBytesSync())!;
    expect(out.getPixel(1, 1).a, 0, reason: 'canto (fundo) transparente');
    expect(out.getPixel(40, 40).a, 255, reason: 'circulo azul preservado');
    c.restoreOverlayOriginal(o);
    expect(o.path, _whiteBgPng);
  });

  testWidgets('9. inserir som no cursor pelo painel Sons', (tester) async {
    final c = await _controller();
    await _show(tester, c);
    await _tapTimeline(tester, c.project!, 3);
    await tester.tap(find.text('Sons'));
    await tester.pump(const Duration(milliseconds: 600));
    final add = find.byKey(const ValueKey('insert-gravadoc-basico-click'));
    expect(add, findsOneWidget);
    await tester.tap(add);
    await tester.pump(const Duration(milliseconds: 500));
    expect(c.project!.sounds, hasLength(1));
    expect(c.project!.sounds.single.at, closeTo(3, 0.6));
    expect(find.byKey(ValueKey('placed-${c.project!.sounds.single.id}')),
        findsOneWidget);
  });

  testWidgets('10. previa renderizada com transicao, imagem e som',
      (tester) async {
    final c = await _controller();
    await _show(tester, c);
    final proj = c.project!;
    proj.splitAt(5);
    proj.setTransition(
        1, const TransitionSpec(xfade: 'fade', name: 'Fade', duration: 1));
    c.addOverlay(_redPng).opacity = 0.6;
    final sound = c.packs
        .expand((pk) => pk.sounds)
        .firstWhere((s) => s.id == 'click');
    c.addSound(sound, 2);
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.byKey(const Key('preview-render')));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(seconds: 1));
      if (find.textContaining('Previa renderizada').evaluate().isNotEmpty) break;
    }
    expect(find.textContaining('Previa renderizada'), findsOneWidget);
    await tester.tap(find.text('Fechar'));
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('11. exportar edicao completa gera mp4 com a duracao certa',
      (tester) async {
    final c = await _controller();
    final proj = c.project!;
    proj.splitAt(4);
    proj.splitAt(7);
    proj.removeClip(1); // 3s removidos
    proj.setTransition(
        1, const TransitionSpec(xfade: 'wipeleft', name: 'W', duration: 0.8));
    c.addOverlay(_whiteBgPng);
    await c.removeOverlayBackground(c.selectedOverlay!, 40);
    c.addSound(
        c.packs.expand((pk) => pk.sounds).firstWhere((s) => s.id == 'ding'), 1);

    final out = p.join(_dir.path, 'final.mp4');
    final progress = <double>[];
    final job = await c.startExport(out, onProgress: progress.add);
    await job.done;
    final info = await probeMedia(_ffmpeg, out);
    expect(info.duration, closeTo(proj.duration, 0.3));
    expect(info.duration, closeTo(6.2, 0.3));
    expect(info.hasAudio, isTrue);
    expect(progress.last, 1);
  });

  testWidgets('12. API REST local pelo painel Pacotes', (tester) async {
    final c = await _controller();
    await _show(tester, c);
    await tester.tap(find.text('Pacotes'));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byKey(const ValueKey('pack-gravadoc-basico')), findsOneWidget);

    await tester.tap(find.byKey(const Key('api-switch')));
    await tester.pump(const Duration(seconds: 1));
    expect(c.server.running, isTrue);

    final client = HttpClient();
    final req = await client.getUrl(
        Uri.parse('http://127.0.0.1:${c.server.port}/packs'));
    req.headers.set('authorization', 'Bearer ${c.server.token}');
    final res = await req.close();
    final body = jsonDecode(await utf8.decodeStream(res)) as Map;
    client.close();
    expect(res.statusCode, 200);
    expect((body['packs'] as List).map((e) => e['id']),
        contains('gravadoc-basico'));

    await tester.tap(find.byKey(const Key('api-switch')));
    await tester.pump(const Duration(seconds: 1));
    expect(c.server.running, isFalse);
  });
}
