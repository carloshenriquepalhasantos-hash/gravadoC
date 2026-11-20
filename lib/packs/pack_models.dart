import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../editor/project.dart';

const kAudioExtensions = {'.wav', '.mp3', '.ogg', '.flac', '.m4a', '.aac'};
const kMaxPackItems = 500;
final _idPattern = RegExp(r'^[a-z0-9][a-z0-9_-]{0,39}$');

class PackFormatException implements Exception {
  const PackFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

class PackSound {
  const PackSound({
    required this.id,
    required this.name,
    required this.path,
    this.category = 'geral',
    this.gain = 1,
  });

  final String id;
  final String name;
  final String path;
  final String category;
  final double gain;
}

class PackTransition {
  const PackTransition({
    required this.id,
    required this.name,
    required this.xfade,
    this.duration = 0.5,
    this.sfxPath,
  });

  final String id;
  final String name;
  final String xfade;
  final double duration;
  final String? sfxPath;

  TransitionSpec toSpec() => TransitionSpec(
        xfade: xfade,
        name: name,
        duration: duration,
        sfxPath: sfxPath,
      );
}

class SoundPack {
  const SoundPack({
    required this.id,
    required this.name,
    required this.version,
    required this.directory,
    this.author = '',
    this.license = '',
    this.description = '',
    this.sounds = const [],
    this.transitions = const [],
  });

  final String id;
  final String name;
  final String version;
  final String author;
  final String license;
  final String description;
  final String directory;
  final List<PackSound> sounds;
  final List<PackTransition> transitions;

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'version': version,
        'author': author,
        'license': license,
        'description': description,
        'sounds': sounds.length,
        'transitions': transitions.length,
      };
}

bool isValidPackId(String id) => _idPattern.hasMatch(id);

String _str(Map json, String key, {bool required = false, int max = 200}) {
  final v = json[key];
  if (v == null) {
    if (required) throw PackFormatException('Campo obrigatorio: "$key".');
    return '';
  }
  if (v is! String) throw PackFormatException('"$key" deve ser texto.');
  if (v.length > max) throw PackFormatException('"$key" muito longo.');
  return v.trim();
}

double _num(Object? v, double fallback, double min, double max) {
  if (v == null) return fallback;
  if (v is! num) throw const PackFormatException('Numero invalido.');
  return v.toDouble().clamp(min, max);
}

/// Resolve [relative] dentro de [root], recusando qualquer escape da pasta.
String _safeFile(String root, String relative, {bool audio = true}) {
  if (relative.isEmpty || p.isAbsolute(relative)) {
    throw PackFormatException('Caminho invalido: "$relative".');
  }
  final full = p.normalize(p.join(root, relative));
  if (!p.isWithin(root, full)) {
    throw PackFormatException('Caminho fora do pacote: "$relative".');
  }
  if (audio && !kAudioExtensions.contains(p.extension(full).toLowerCase())) {
    throw PackFormatException('Extensao de audio nao permitida: "$relative".');
  }
  if (!File(full).existsSync()) {
    throw PackFormatException('Arquivo nao encontrado: "$relative".');
  }
  return full;
}

SoundPack parsePackManifest(String jsonText, String directory) {
  final Object? decoded;
  try {
    decoded = jsonDecode(jsonText);
  } on FormatException {
    throw const PackFormatException('manifest.json nao e um JSON valido.');
  }
  if (decoded is! Map) {
    throw const PackFormatException('manifest.json deve ser um objeto.');
  }
  final root = p.normalize(p.absolute(directory));
  final id = _str(decoded, 'id', required: true, max: 40);
  if (!isValidPackId(id)) {
    throw const PackFormatException(
        'id invalido: use a-z, 0-9, "-" ou "_" (ate 40 caracteres).');
  }

  final rawSounds = decoded['sounds'] ?? const [];
  final rawTransitions = decoded['transitions'] ?? const [];
  if (rawSounds is! List || rawTransitions is! List) {
    throw const PackFormatException('"sounds" e "transitions" devem ser listas.');
  }
  if (rawSounds.length + rawTransitions.length > kMaxPackItems) {
    throw const PackFormatException('Itens demais no pacote.');
  }

  final sounds = <PackSound>[];
  final soundPaths = <String, String>{};
  for (final s in rawSounds) {
    if (s is! Map) throw const PackFormatException('Som invalido.');
    final sid = _str(s, 'id', required: true, max: 60);
    final path = _safeFile(root, _str(s, 'file', required: true, max: 300));
    soundPaths[sid] = path;
    sounds.add(PackSound(
      id: sid,
      name: _str(s, 'name').isEmpty ? sid : _str(s, 'name'),
      path: path,
      category: _str(s, 'category').isEmpty ? 'geral' : _str(s, 'category'),
      gain: _num(s['gain'], 1, 0, 4),
    ));
  }

  final transitions = <PackTransition>[];
  for (final t in rawTransitions) {
    if (t is! Map) throw const PackFormatException('Transicao invalida.');
    final xfade = _str(t, 'xfade', required: true, max: 30);
    if (!kXfadeTransitions.contains(xfade)) {
      throw PackFormatException('Transicao desconhecida: "$xfade".');
    }
    final tid = _str(t, 'id', required: true, max: 60);
    final sfxId = _str(t, 'sfx');
    if (sfxId.isNotEmpty && !soundPaths.containsKey(sfxId)) {
      throw PackFormatException('sfx "$sfxId" nao existe em "sounds".');
    }
    transitions.add(PackTransition(
      id: tid,
      name: _str(t, 'name').isEmpty ? tid : _str(t, 'name'),
      xfade: xfade,
      duration: _num(t['duration'], 0.5, 0.1, 3),
      sfxPath: sfxId.isEmpty ? null : soundPaths[sfxId],
    ));
  }

  return SoundPack(
    id: id,
    name: _str(decoded, 'name').isEmpty ? id : _str(decoded, 'name'),
    version: _str(decoded, 'version').isEmpty ? '1.0.0' : _str(decoded, 'version'),
    author: _str(decoded, 'author'),
    license: _str(decoded, 'license'),
    description: _str(decoded, 'description', max: 1000),
    directory: root,
    sounds: sounds,
    transitions: transitions,
  );
}
