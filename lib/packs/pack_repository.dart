import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../editor/project.dart';
import 'pack_models.dart';

class PackRepository extends ChangeNotifier {
  PackRepository(this.root);

  static const builtInId = 'gravadoc-basico';
  static const maxZipBytes = 100 * 1024 * 1024;
  static const maxUnpackedBytes = 200 * 1024 * 1024;
  static const maxFiles = 600;
  static const _allowedExtras = {'.json', '.txt', '.md'};

  final Directory root;

  Future<List<SoundPack>> list() async {
    if (!await root.exists()) return [];
    final packs = <SoundPack>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory || p.basename(entity.path).startsWith('.')) {
        continue;
      }
      final manifest = File(p.join(entity.path, 'manifest.json'));
      if (!await manifest.exists()) continue;
      try {
        packs.add(parsePackManifest(await manifest.readAsString(), entity.path));
      } on PackFormatException {
        continue;
      }
    }
    packs.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return packs;
  }

  Future<SoundPack> installDirectory(Directory source) async {
    await root.create(recursive: true);
    final staged = await _newStage();
    try {
      var total = 0;
      await for (final e in source.list(recursive: true, followLinks: false)) {
        if (e is! File) continue;
        final rel = p.relative(e.path, from: source.path);
        if (!_isAllowedFile(rel)) continue;
        total += await e.length();
        if (total > maxUnpackedBytes) {
          throw const PackFormatException('Pacote grande demais.');
        }
        final out = File(p.join(staged.path, rel));
        await out.parent.create(recursive: true);
        await e.copy(out.path);
      }
      return await _commit(staged);
    } finally {
      if (await staged.exists()) await staged.delete(recursive: true);
    }
  }

  Future<SoundPack> installZipBytes(Uint8List bytes) async {
    if (bytes.length > maxZipBytes) {
      throw const PackFormatException('Arquivo zip grande demais.');
    }
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } on Object {
      throw const PackFormatException('Arquivo zip invalido.');
    }
    if (archive.length > maxFiles) {
      throw const PackFormatException('Arquivos demais no zip.');
    }
    await root.create(recursive: true);
    final staged = await _newStage();
    try {
      var total = 0;
      for (final entry in archive) {
        if (!entry.isFile) continue;
        final name = entry.name.replaceAll('\\', '/');
        final parts = name.split('/');
        if (name.startsWith('/') ||
            parts.contains('..') ||
            RegExp(r'^[a-zA-Z]:').hasMatch(name)) {
          throw PackFormatException('Caminho perigoso no zip: "$name".');
        }
        if (!_isAllowedFile(name)) continue;
        final data = entry.readBytes() ?? Uint8List(0);
        total += data.length;
        if (total > maxUnpackedBytes) {
          throw const PackFormatException('Pacote descompactado grande demais.');
        }
        final out = File(p.join(staged.path, name));
        if (!p.isWithin(staged.path, out.path)) {
          throw PackFormatException('Caminho perigoso no zip: "$name".');
        }
        await out.parent.create(recursive: true);
        await out.writeAsBytes(data);
      }
      return await _commit(await _findManifestDir(staged));
    } finally {
      if (await staged.exists()) await staged.delete(recursive: true);
    }
  }

  Future<void> remove(String id) async {
    if (!isValidPackId(id)) {
      throw const PackFormatException('id invalido.');
    }
    final dir = Directory(p.join(root.path, id));
    if (await dir.exists()) {
      await dir.delete(recursive: true);
      notifyListeners();
    }
  }

  bool _isAllowedFile(String relative) {
    final ext = p.extension(relative).toLowerCase();
    return kAudioExtensions.contains(ext) || _allowedExtras.contains(ext);
  }

  Future<Directory> _newStage() async {
    final dir = Directory(
        p.join(root.path, '.tmp-${DateTime.now().microsecondsSinceEpoch}'));
    await dir.create(recursive: true);
    return dir;
  }

  // Aceita manifest.json na raiz do zip ou dentro de uma unica pasta.
  Future<Directory> _findManifestDir(Directory staged) async {
    if (await File(p.join(staged.path, 'manifest.json')).exists()) return staged;
    final dirs = await staged.list().where((e) => e is Directory).toList();
    if (dirs.length == 1 &&
        await File(p.join(dirs.first.path, 'manifest.json')).exists()) {
      return Directory(dirs.first.path);
    }
    throw const PackFormatException('manifest.json nao encontrado no pacote.');
  }

  Future<SoundPack> _commit(Directory staged) async {
    final manifest = File(p.join(staged.path, 'manifest.json'));
    if (!await manifest.exists()) {
      throw const PackFormatException('manifest.json nao encontrado.');
    }
    final pack = parsePackManifest(await manifest.readAsString(), staged.path);
    final dest = Directory(p.join(root.path, pack.id));
    if (await dest.exists()) await dest.delete(recursive: true);
    await staged.rename(dest.path);
    notifyListeners();
    return parsePackManifest(
        await File(p.join(dest.path, 'manifest.json')).readAsString(),
        dest.path);
  }

  /// Cria o pacote inicial: todas as transicoes do FFmpeg e efeitos sonoros
  /// sintetizados localmente (sem conteudo de terceiros).
  Future<void> ensureBuiltIn(String ffmpegPath) async {
    final dir = Directory(p.join(root.path, builtInId));
    final manifest = File(p.join(dir.path, 'manifest.json'));
    if (await manifest.exists()) return;

    final stage = await _newStage();
    try {
      final soundsDir = Directory(p.join(stage.path, 'sounds'))..createSync();
      for (final s in _builtInSounds) {
        final r = await Process.run(ffmpegPath, [
          '-y', '-loglevel', 'error', '-f', 'lavfi', '-i', s.expression,
          '-ar', '44100', '-ac', '2', '-c:a', 'pcm_s16le',
          p.join(soundsDir.path, '${s.id}.wav'),
        ]);
        if (r.exitCode != 0) {
          throw StateError('Falha ao gerar "${s.id}": ${r.stderr}');
        }
      }
      final json = {
        'id': builtInId,
        'name': 'gravadoC Basico',
        'version': '1.0.0',
        'author': 'gravadoC',
        'license': 'CC0-1.0 (gerado pelo proprio app)',
        'description': 'Todas as transicoes do FFmpeg e efeitos sinteticos.',
        'sounds': [
          for (final s in _builtInSounds)
            {
              'id': s.id,
              'name': s.name,
              'file': 'sounds/${s.id}.wav',
              'category': s.category,
              'gain': 0.8,
            }
        ],
        'transitions': [
          for (final id in kXfadeTransitions.toList()..sort())
            {
              'id': id,
              'name': _transitionNames[id] ?? id,
              'xfade': id,
              'duration': 0.6,
              if (_transitionSfx[id] != null) 'sfx': _transitionSfx[id],
            }
        ],
      };
      await File(p.join(stage.path, 'manifest.json'))
          .writeAsString(const JsonEncoder.withIndent('  ').convert(json));
      await _commit(stage);
    } finally {
      if (await stage.exists()) await stage.delete(recursive: true);
    }
  }
}

class _Builtin {
  const _Builtin(this.id, this.name, this.category, this.expression);

  final String id;
  final String name;
  final String category;
  final String expression;
}

const _builtInSounds = [
  _Builtin('whoosh', 'Whoosh', 'transicao',
      'anoisesrc=d=0.7:c=pink:a=0.6,highpass=f=200,lowpass=f=5000,'
          'afade=t=in:d=0.25,afade=t=out:st=0.35:d=0.35'),
  _Builtin('swoosh', 'Swoosh', 'transicao',
      'anoisesrc=d=0.5:c=white:a=0.5,bandpass=f=2500:width_type=h:w=3000,'
          'afade=t=in:d=0.15,afade=t=out:st=0.2:d=0.3'),
  _Builtin('click', 'Click', 'interface',
      'sine=f=1500:d=0.06,afade=t=out:d=0.06'),
  _Builtin('pop', 'Pop', 'interface',
      "aevalsrc='0.8*sin(2*PI*(800-3000*t)*t)*exp(-12*t)':d=0.15:s=44100"),
  _Builtin('riser', 'Subida', 'efeito',
      "aevalsrc='0.4*sin(2*PI*(200+900*t)*t)':d=1.2:s=44100,"
          'afade=t=out:st=1.0:d=0.2'),
  _Builtin('ding', 'Ding', 'interface',
      "aevalsrc='0.7*sin(2*PI*1318*t)*exp(-4*t)':d=1.2:s=44100"),
  _Builtin('hit', 'Impacto', 'efeito',
      "aevalsrc='0.9*sin(2*PI*60*t)*exp(-10*t)':d=0.6:s=44100"),
];

const _transitionNames = {
  'fade': 'Fade',
  'fadeblack': 'Fade para preto',
  'fadewhite': 'Fade para branco',
  'dissolve': 'Dissolver',
  'wipeleft': 'Cortina esquerda',
  'wiperight': 'Cortina direita',
  'wipeup': 'Cortina para cima',
  'wipedown': 'Cortina para baixo',
  'slideleft': 'Deslizar esquerda',
  'slideright': 'Deslizar direita',
  'slideup': 'Deslizar para cima',
  'slidedown': 'Deslizar para baixo',
  'circleopen': 'Circulo abre',
  'circleclose': 'Circulo fecha',
  'pixelize': 'Pixelizar',
  'radial': 'Radial',
  'zoomin': 'Zoom',
  'hblur': 'Desfoque horizontal',
  'squeezeh': 'Espremer horizontal',
  'squeezev': 'Espremer vertical',
  'horzopen': 'Abrir horizontal',
  'vertopen': 'Abrir vertical',
  'distance': 'Distancia',
};

const _transitionSfx = {
  'wipeleft': 'swoosh',
  'wiperight': 'swoosh',
  'wipeup': 'swoosh',
  'wipedown': 'swoosh',
  'slideleft': 'whoosh',
  'slideright': 'whoosh',
  'slideup': 'whoosh',
  'slidedown': 'whoosh',
  'circleopen': 'pop',
  'circleclose': 'pop',
  'pixelize': 'click',
  'zoomin': 'riser',
  'radial': 'ding',
  'fadewhite': 'hit',
};
