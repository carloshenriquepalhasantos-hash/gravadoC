import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravadoc/editor/background_removal.dart';
import 'package:gravadoc/ffmpeg_service.dart';
import 'package:gravadoc/editor/project.dart';
import 'package:gravadoc/packs/pack_downloader.dart';
import 'package:gravadoc/packs/pack_models.dart';
import 'package:gravadoc/packs/pack_repository.dart';
import 'package:gravadoc/packs/pack_server.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

Map<String, Object?> _manifest({
  String id = 'meu-pacote',
  List<Object?>? sounds,
  List<Object?>? transitions,
}) =>
    {
      'id': id,
      'name': 'Meu Pacote',
      'version': '1.2.0',
      'license': 'CC0',
      'sounds': sounds ??
          [
            {'id': 'boom', 'name': 'Boom', 'file': 'sounds/boom.wav'}
          ],
      'transitions': transitions ??
          [
            {'id': 'f', 'name': 'Fade', 'xfade': 'fade', 'sfx': 'boom'}
          ],
    };

Uint8List _zip(Map<String, List<int>> files) {
  final archive = Archive();
  files.forEach((name, data) => archive.addFile(ArchiveFile(name, data.length, data)));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Map<String, List<int>> _packFiles({String id = 'meu-pacote', String prefix = ''}) => {
      '${prefix}manifest.json': utf8.encode(jsonEncode(_manifest(id: id))),
      '${prefix}sounds/boom.wav': List.filled(64, 1),
    };

void main() {
  late Directory tmp;
  late PackRepository repo;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('gravadoc_packs');
    repo = PackRepository(Directory(p.join(tmp.path, 'packs')));
  });

  tearDown(() => tmp.delete(recursive: true));

  Directory makePackDir(Map<String, Object?> manifest, {String name = 'src'}) {
    final dir = Directory(p.join(tmp.path, name))..createSync(recursive: true);
    File(p.join(dir.path, 'manifest.json')).writeAsStringSync(jsonEncode(manifest));
    Directory(p.join(dir.path, 'sounds')).createSync();
    File(p.join(dir.path, 'sounds', 'boom.wav')).writeAsBytesSync([1, 2, 3]);
    return dir;
  }

  group('manifest', () {
    test('valido: resolve sons e sfx da transicao', () {
      final dir = makePackDir(_manifest());
      final pack = parsePackManifest(
          File(p.join(dir.path, 'manifest.json')).readAsStringSync(), dir.path);
      expect(pack.sounds.single.path, endsWith('boom.wav'));
      expect(pack.transitions.single.sfxPath, pack.sounds.single.path);
      expect(pack.license, 'CC0');
    });

    final bad = <String, Map<String, Object?>>{
      'id com caracteres perigosos': _manifest(id: '../hack'),
      'id em maiusculas': _manifest(id: 'MeuPacote'),
      'transicao desconhecida (injecao no filtergraph)': _manifest(
          transitions: [
            {'id': 'x', 'xfade': 'fade[v];movie=a'}
          ]),
      'som fora da pasta': _manifest(sounds: [
        {'id': 'a', 'file': '../fora.wav'}
      ]),
      'caminho absoluto': _manifest(sounds: [
        {'id': 'a', 'file': 'C:\\Windows\\x.wav'}
      ]),
      'extensao nao permitida': _manifest(sounds: [
        {'id': 'a', 'file': 'sounds/boom.exe'}
      ]),
      'arquivo inexistente': _manifest(sounds: [
        {'id': 'a', 'file': 'sounds/nao-existe.wav'}
      ]),
      'sfx inexistente': _manifest(transitions: [
        {'id': 'f', 'xfade': 'fade', 'sfx': 'fantasma'}
      ]),
    };
    bad.forEach((name, manifest) {
      test('recusa: $name', () {
        final dir = makePackDir(manifest, name: 'bad');
        expect(
          () => parsePackManifest(jsonEncode(manifest), dir.path),
          throwsA(isA<PackFormatException>()),
        );
      });
    });

    test('recusa JSON invalido', () {
      expect(() => parsePackManifest('{nao-json', tmp.path),
          throwsA(isA<PackFormatException>()));
    });
  });

  group('PackRepository', () {
    test('instala de pasta, lista e remove', () async {
      final pack = await repo.installDirectory(makePackDir(_manifest()));
      expect(pack.id, 'meu-pacote');
      expect((await repo.list()).map((e) => e.id), ['meu-pacote']);
      await repo.remove('meu-pacote');
      expect(await repo.list(), isEmpty);
    });

    test('reinstalar substitui a versao anterior', () async {
      await repo.installDirectory(makePackDir(_manifest()));
      final m = _manifest()..['version'] = '2.0.0';
      await repo.installDirectory(makePackDir(m, name: 'src2'));
      final list = await repo.list();
      expect(list, hasLength(1));
      expect(list.single.version, '2.0.0');
    });

    test('instala zip com manifest na raiz', () async {
      final pack = await repo.installZipBytes(_zip(_packFiles()));
      expect(pack.sounds, hasLength(1));
    });

    test('instala zip com tudo dentro de uma pasta', () async {
      final pack = await repo.installZipBytes(_zip(_packFiles(prefix: 'pasta/')));
      expect(pack.id, 'meu-pacote');
    });

    test('zip-slip e rejeitado e nada escapa da pasta', () async {
      final evil = _zip({
        ..._packFiles(),
        '../fora.wav': [1, 2, 3],
      });
      await expectLater(
          repo.installZipBytes(evil), throwsA(isA<PackFormatException>()));
      expect(File(p.join(tmp.path, 'fora.wav')).existsSync(), isFalse);
      expect(await repo.list(), isEmpty);
    });

    test('arquivos executaveis do zip sao ignorados', () async {
      final zip = _zip({..._packFiles(), 'sounds/virus.exe': [1, 2, 3]});
      final pack = await repo.installZipBytes(zip);
      expect(File(p.join(pack.directory, 'sounds', 'virus.exe')).existsSync(),
          isFalse);
    });

    test('zip invalido e rejeitado', () async {
      await expectLater(repo.installZipBytes(Uint8List.fromList([1, 2, 3])),
          throwsA(isA<PackFormatException>()));
    });

    test('remover recusa id com caminho', () async {
      await expectLater(
          repo.remove('..\\..'), throwsA(isA<PackFormatException>()));
    });

    test('pacote inicial usa FFmpeg e traz todas as transicoes', () async {
      final ffmpeg = (await locateFfmpeg())!;
      await repo.ensureBuiltIn(ffmpeg);
      final pack =
          (await repo.list()).singleWhere((e) => e.id == PackRepository.builtInId);
      expect(pack.transitions, hasLength(kXfadeTransitions.length));
      expect(pack.sounds, hasLength(7));
      for (final s in pack.sounds) {
        expect(File(s.path).lengthSync(), greaterThan(1000), reason: s.id);
      }
      expect(
          pack.transitions.firstWhere((t) => t.xfade == 'slideleft').sfxPath,
          endsWith('whoosh.wav'));
      await repo.ensureBuiltIn(ffmpeg); // idempotente
      expect(await repo.list(), hasLength(1));
    });
  });

  group('API REST local', () {
    late PackApiServer server;
    late HttpClient client;

    setUp(() async {
      server = PackApiServer(repo);
      await server.start();
      client = HttpClient();
    });

    tearDown(() async {
      client.close(force: true);
      await server.stop();
    });

    Future<(int, Map<String, dynamic>)> call(
      String method,
      String path, {
      String? token,
      Object? body,
      String? contentType,
      Map<String, String> headers = const {},
    }) async {
      final req = await client.openUrl(
          method, Uri.parse('http://127.0.0.1:${server.port}$path'));
      if (token != null) req.headers.set('authorization', 'Bearer $token');
      headers.forEach(req.headers.set);
      if (body != null) {
        req.headers.contentType = ContentType.parse(contentType!);
        req.add(body is List<int> ? body : utf8.encode(jsonEncode(body)));
      }
      final res = await req.close();
      final text = await utf8.decodeStream(res);
      return (res.statusCode, jsonDecode(text) as Map<String, dynamic>);
    }

    test('exige token', () async {
      expect((await call('GET', '/packs')).$1, 401);
      expect((await call('GET', '/packs', token: 'errado')).$1, 401);
      expect((await call('GET', '/packs', token: server.token)).$1, 200);
    });

    test('recusa requisicoes de navegador (Origin)', () async {
      final r = await call('GET', '/packs',
          token: server.token, headers: {'origin': 'https://site-malicioso.com'});
      expect(r.$1, 403);
    });

    test('recusa Host diferente de localhost (DNS rebinding)', () async {
      final r = await call('GET', '/packs',
          token: server.token, headers: {'host': 'evil.example.com'});
      expect(r.$1, 403);
    });

    test('instala zip, detalha, lista e remove', () async {
      final t = server.token;
      final created = await call('POST', '/packs',
          token: t, body: _zip(_packFiles()), contentType: 'application/zip');
      expect(created.$1, 201);
      expect(created.$2['id'], 'meu-pacote');

      final list = await call('GET', '/packs', token: t);
      expect((list.$2['packs'] as List).single['id'], 'meu-pacote');

      final detail = await call('GET', '/packs/meu-pacote', token: t);
      expect((detail.$2['transitions'] as List).single['xfade'], 'fade');
      expect((detail.$2['sounds'] as List).single['id'], 'boom');

      expect((await call('DELETE', '/packs/meu-pacote', token: t)).$1, 200);
      expect((await call('GET', '/packs/meu-pacote', token: t)).$1, 404);
    });

    test('zip malicioso devolve 400', () async {
      final r = await call('POST', '/packs',
          token: server.token,
          body: _zip({..._packFiles(), '../x.wav': [1]}),
          contentType: 'application/zip');
      expect(r.$1, 400);
    });

    test('instalar por URL local e bloqueado (anti-SSRF)', () async {
      final r = await call('POST', '/packs',
          token: server.token,
          body: {'url': 'http://127.0.0.1:1/pack.zip'},
          contentType: 'application/json');
      expect(r.$1, 502);
    });

    test('rota desconhecida devolve 404', () async {
      expect((await call('GET', '/nada', token: server.token)).$1, 404);
    });

    test('parar o servidor invalida o token', () async {
      await server.stop();
      expect(server.running, isFalse);
      expect(server.token, isEmpty);
    });
  });

  group('catalogo remoto', () {
    late HttpServer web;
    late Uint8List zip;
    late String goodSha;
    const lenient = PackDownloader(allowLocal: true);

    setUp(() async {
      zip = _zip(_packFiles());
      goodSha = sha256.convert(zip).toString();
      web = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      web.listen((req) async {
        final res = req.response;
        if (req.uri.path == '/catalog.json') {
          res.write(jsonEncode({
            'packs': [
              {'id': 'meu-pacote', 'name': 'Meu', 'url': 'pack.zip', 'sha256': goodSha},
              {'id': 'adulterado', 'url': 'pack.zip', 'sha256': 'deadbeef'},
              {'id': 'outro-id', 'url': 'pack.zip'},
              {'id': 'ID RUIM', 'url': 'pack.zip'},
            ]
          }));
        } else if (req.uri.path == '/pack.zip') {
          res.add(zip);
        } else if (req.uri.path == '/redir') {
          res.statusCode = 302;
          res.headers.set('location', '/pack.zip');
        } else {
          res.statusCode = 404;
        }
        await res.close();
      });
    });

    tearDown(() => web.close(force: true));

    Uri url(String path) => Uri.parse('http://127.0.0.1:${web.port}$path');

    test('lista entradas validas e ignora id invalido', () async {
      final entries = await const RemoteCatalog(lenient).fetch(url('/catalog.json'));
      expect(entries.map((e) => e.id), ['meu-pacote', 'adulterado', 'outro-id']);
      expect(entries.first.url, url('/pack.zip'));
    });

    test('instala quando o SHA-256 confere', () async {
      const catalog = RemoteCatalog(lenient);
      final entry = (await catalog.fetch(url('/catalog.json'))).first;
      final pack = await catalog.install(repo, entry);
      expect(pack.id, 'meu-pacote');
    });

    test('recusa quando o SHA-256 nao confere', () async {
      const catalog = RemoteCatalog(lenient);
      final entry = (await catalog.fetch(url('/catalog.json')))[1];
      await expectLater(
          catalog.install(repo, entry), throwsA(isA<DownloadException>()));
      expect(await repo.list(), isEmpty);
    });

    test('recusa e remove pacote cujo id difere do catalogo', () async {
      const catalog = RemoteCatalog(lenient);
      final entry = (await catalog.fetch(url('/catalog.json')))[2];
      await expectLater(
          catalog.install(repo, entry), throwsA(isA<DownloadException>()));
      expect(await repo.list(), isEmpty);
    });

    test('segue redirecionamento', () async {
      final bytes = await lenient.fetch(url('/redir'));
      expect(bytes, zip);
    });

    test('modo estrito exige HTTPS e bloqueia loopback', () async {
      const strict = PackDownloader();
      await expectLater(
          strict.fetch(url('/pack.zip')), throwsA(isA<DownloadException>()));
      await expectLater(strict.fetch(Uri.parse('https://127.0.0.1:1/x')),
          throwsA(isA<DownloadException>()));
    });

    test('limite de tamanho interrompe o download', () async {
      await expectLater(lenient.fetch(url('/pack.zip'), maxBytes: 10),
          throwsA(isA<DownloadException>()));
    });
  });

  group('remocao de fundo', () {
    Uint8List sample() {
      final im = img.Image(width: 60, height: 60, numChannels: 4);
      img.fill(im, color: img.ColorRgba8(255, 255, 255, 255));
      // Anel vermelho com um buraco branco que nao toca o fundo.
      img.fillRect(im,
          x1: 15, y1: 15, x2: 45, y2: 45, color: img.ColorRgba8(220, 0, 0, 255));
      img.fillRect(im,
          x1: 27, y1: 27, x2: 33, y2: 33, color: img.ColorRgba8(255, 255, 255, 255));
      return Uint8List.fromList(img.encodePng(im));
    }

    test('fundo uniforme fica transparente e o objeto permanece', () {
      final out = img.decodePng(removeUniformBackground(sample()))!;
      expect(out.getPixel(1, 1).a, 0);
      expect(out.getPixel(58, 58).a, 0);
      expect(out.getPixel(20, 20).a, 255);
      expect(out.getPixel(20, 20).r, 220);
    });

    test('cor igual ao fundo dentro do objeto e preservada', () {
      final out = img.decodePng(removeUniformBackground(sample()))!;
      expect(out.getPixel(30, 30).a, 255);
    });

    test('imagem invalida lanca FormatException', () {
      expect(() => removeUniformBackground(Uint8List.fromList([1, 2, 3])),
          throwsFormatException);
    });
  });
}
