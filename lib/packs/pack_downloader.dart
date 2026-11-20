import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'pack_models.dart';
import 'pack_repository.dart';

class DownloadException implements Exception {
  const DownloadException(this.message);

  final String message;

  @override
  String toString() => message;
}

bool _isPrivate(InternetAddress a) {
  if (a.isLoopback || a.isLinkLocal || a.isMulticast) return true;
  final b = a.rawAddress;
  if (a.type == InternetAddressType.IPv4) {
    return b[0] == 0 ||
        b[0] == 10 ||
        (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
        (b[0] == 192 && b[1] == 168);
  }
  return (b[0] & 0xfe) == 0xfc;
}

class PackDownloader {
  /// [allowLocal] libera HTTP e enderecos locais (uso manual na interface e
  /// testes). O servidor da API usa o modo estrito para evitar SSRF.
  const PackDownloader({this.allowLocal = false});

  final bool allowLocal;

  Future<Uint8List> fetch(
    Uri uri, {
    int maxBytes = PackRepository.maxZipBytes,
    int redirects = 3,
  }) async {
    var current = uri;
    for (var hop = 0; hop <= redirects; hop++) {
      await _validate(current);
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10);
      try {
        final request = await client.getUrl(current);
        request.followRedirects = false;
        final response =
            await request.close().timeout(const Duration(seconds: 30));
        if (response.isRedirect) {
          final location = response.headers.value('location');
          await response.drain<void>();
          if (location == null) throw const DownloadException('Redirecionamento invalido.');
          current = current.resolve(location);
          continue;
        }
        if (response.statusCode != 200) {
          await response.drain<void>();
          throw DownloadException('Servidor respondeu ${response.statusCode}.');
        }
        if (response.contentLength > maxBytes) {
          throw const DownloadException('Arquivo grande demais.');
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response) {
          bytes.add(chunk);
          if (bytes.length > maxBytes) {
            throw const DownloadException('Arquivo grande demais.');
          }
        }
        return bytes.takeBytes();
      } on SocketException catch (e) {
        throw DownloadException('Falha de rede: ${e.message}');
      } on TimeoutException {
        throw const DownloadException('Tempo esgotado.');
      } finally {
        client.close(force: true);
      }
    }
    throw const DownloadException('Redirecionamentos demais.');
  }

  Future<void> _validate(Uri uri) async {
    final secure = uri.scheme == 'https';
    if (!secure && !(allowLocal && uri.scheme == 'http')) {
      throw const DownloadException('Somente URLs HTTPS sao permitidas.');
    }
    if (uri.host.isEmpty) throw const DownloadException('URL invalida.');
    if (!allowLocal) {
      final addresses = await InternetAddress.lookup(uri.host);
      if (addresses.any(_isPrivate)) {
        throw const DownloadException('Enderecos locais sao bloqueados.');
      }
    }
  }
}

class CatalogEntry {
  const CatalogEntry({
    required this.id,
    required this.name,
    required this.version,
    required this.url,
    this.description = '',
    this.license = '',
    this.sha256,
  });

  final String id;
  final String name;
  final String version;
  final Uri url;
  final String description;
  final String license;
  final String? sha256;
}

/// Catalogo remoto: `{ "packs": [ { id, name, version, url, sha256?, ... } ] }`.
class RemoteCatalog {
  const RemoteCatalog(this.downloader);

  final PackDownloader downloader;

  Future<List<CatalogEntry>> fetch(Uri catalogUrl) async {
    final bytes = await downloader.fetch(catalogUrl, maxBytes: 1024 * 1024);
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw const DownloadException('Catalogo nao e um JSON valido.');
    }
    final list = json is Map ? json['packs'] : null;
    if (list is! List) {
      throw const DownloadException('Catalogo sem a lista "packs".');
    }
    final entries = <CatalogEntry>[];
    for (final item in list.take(kMaxPackItems)) {
      if (item is! Map) continue;
      final id = item['id'];
      final url = item['url'];
      if (id is! String || !isValidPackId(id) || url is! String) continue;
      final sha = item['sha256'];
      entries.add(CatalogEntry(
        id: id,
        name: '${item['name'] ?? id}',
        version: '${item['version'] ?? '1.0.0'}',
        description: '${item['description'] ?? ''}',
        license: '${item['license'] ?? ''}',
        url: catalogUrl.resolve(url),
        sha256: sha is String && sha.isNotEmpty ? sha.toLowerCase() : null,
      ));
    }
    return entries;
  }

  Future<SoundPack> install(PackRepository repo, CatalogEntry entry) async {
    final bytes = await downloader.fetch(entry.url);
    final expected = entry.sha256;
    if (expected != null && sha256.convert(bytes).toString() != expected) {
      throw const DownloadException(
          'SHA-256 diferente do catalogo: download recusado.');
    }
    final pack = await repo.installZipBytes(bytes);
    if (pack.id != entry.id) {
      await repo.remove(pack.id);
      throw DownloadException(
          'O pacote baixado ("${pack.id}") nao corresponde ao catalogo ("${entry.id}").');
    }
    return pack;
  }
}
