import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'pack_downloader.dart';
import 'pack_models.dart';
import 'pack_repository.dart';

/// API REST local para instalar e listar pacotes.
///
/// Protecoes: escuta somente em 127.0.0.1, exige token Bearer, recusa
/// qualquer requisicao com cabecalho Origin (navegadores) e valida o Host
/// contra DNS rebinding. Instalacao por URL usa o downloader estrito.
class PackApiServer {
  PackApiServer(this.repo, {this.downloader = const PackDownloader()});

  final PackRepository repo;
  final PackDownloader downloader;
  HttpServer? _server;
  String _token = '';

  bool get running => _server != null;
  int get port => _server?.port ?? 0;
  String get token => _token;

  Future<void> start({int port = 0}) async {
    if (_server != null) return;
    _token = _randomToken();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _server = server;
    server.listen(_handle);
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    _token = '';
    await server?.close(force: true);
  }

  static String _randomToken() {
    final r = Random.secure();
    return List.generate(32, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'))
        .join();
  }

  bool _tokenMatches(String header) {
    final expected = 'Bearer $_token';
    if (_token.isEmpty || header.length != expected.length) return false;
    var diff = 0;
    for (var i = 0; i < expected.length; i++) {
      diff |= expected.codeUnitAt(i) ^ header.codeUnitAt(i);
    }
    return diff == 0;
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    (int, Object) result;
    try {
      result = await _route(req);
    } on PackFormatException catch (e) {
      result = (400, {'error': e.message});
    } on DownloadException catch (e) {
      result = (502, {'error': e.message});
    } on _TooLarge {
      result = (413, {'error': 'Corpo da requisicao grande demais.'});
    } on Object {
      result = (500, {'error': 'Erro interno.'});
    }
    try {
      res.statusCode = result.$1;
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode(result.$2));
      await res.close();
    } on Object {
      // Cliente desconectou antes da resposta.
    }
  }

  Future<(int, Object)> _route(HttpRequest req) async {
    if (req.headers.value('origin') != null) {
      return (403, {'error': 'Requisicoes de navegador nao sao permitidas.'});
    }
    final host = req.headers.value('host') ?? '';
    if (host != '127.0.0.1:$port' && host != 'localhost:$port') {
      return (403, {'error': 'Host invalido.'});
    }
    if (!_tokenMatches(req.headers.value('authorization') ?? '')) {
      return (401, {'error': 'Token ausente ou invalido.'});
    }

    final seg = req.uri.pathSegments;
    final method = req.method;
    if (seg.length == 1 && seg[0] == 'health' && method == 'GET') {
      return (200, {'status': 'ok'});
    }
    if (seg.isNotEmpty && seg[0] == 'packs') {
      if (seg.length == 1 && method == 'GET') {
        final packs = await repo.list();
        return (200, {'packs': packs.map((e) => e.toJson()).toList()});
      }
      if (seg.length == 1 && method == 'POST') {
        return (201, (await _install(req)).toJson());
      }
      if (seg.length == 2 && method == 'GET') {
        final found = (await repo.list()).where((e) => e.id == seg[1]);
        if (found.isEmpty) return (404, {'error': 'Pacote nao encontrado.'});
        return (200, _detail(found.first));
      }
      if (seg.length == 2 && method == 'DELETE') {
        await repo.remove(seg[1]);
        return (200, {'removed': seg[1]});
      }
    }
    return (404, {'error': 'Rota nao encontrada.'});
  }

  Future<SoundPack> _install(HttpRequest req) async {
    final type = req.headers.contentType?.mimeType;
    final body = await _readBody(req, PackRepository.maxZipBytes);
    if (type == 'application/zip' || type == 'application/octet-stream') {
      return repo.installZipBytes(body);
    }
    if (type == 'application/json') {
      final Object? json;
      try {
        json = jsonDecode(utf8.decode(body));
      } on FormatException {
        throw const PackFormatException('JSON invalido.');
      }
      final url = json is Map ? json['url'] : null;
      if (url is! String) {
        throw const PackFormatException('Informe {"url": "https://..."}.');
      }
      final uri = Uri.tryParse(url);
      if (uri == null) throw const PackFormatException('URL invalida.');
      return repo.installZipBytes(await downloader.fetch(uri));
    }
    throw const PackFormatException(
        'Use Content-Type application/zip ou application/json.');
  }

  Future<Uint8List> _readBody(HttpRequest req, int max) async {
    if (req.contentLength > max) throw const _TooLarge();
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in req) {
      bytes.add(chunk);
      if (bytes.length > max) throw const _TooLarge();
    }
    return bytes.takeBytes();
  }

  Map<String, Object?> _detail(SoundPack pack) => {
        ...pack.toJson(),
        'sounds': [
          for (final s in pack.sounds)
            {'id': s.id, 'name': s.name, 'category': s.category}
        ],
        'transitions': [
          for (final t in pack.transitions)
            {'id': t.id, 'name': t.name, 'xfade': t.xfade, 'duration': t.duration}
        ],
      };
}

class _TooLarge implements Exception {
  const _TooLarge();
}
