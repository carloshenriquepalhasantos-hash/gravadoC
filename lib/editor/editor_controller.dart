import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../ffmpeg_service.dart';
import '../packs/pack_models.dart';
import '../packs/pack_repository.dart';
import '../packs/pack_server.dart';
import 'background_removal.dart';
import 'export_builder.dart';
import 'project.dart';

Uint8List _removeBackgroundIsolate(List<Object> args) =>
    removeUniformBackground(args[0] as Uint8List, tolerance: args[1] as double);

class EditorController extends ChangeNotifier {
  EditorController({this.ffmpegPath, PackRepository? repository})
      // ignore: prefer_initializing_formals
      : _repository = repository;

  String? ffmpegPath;
  PackRepository? _repository;
  PackApiServer? _server;
  EditProject? project;
  List<SoundPack> packs = const [];
  int selectedClip = 0;
  String? selectedOverlayId;
  bool ready = false;
  int _counter = 0;

  PackRepository get repository => _repository!;
  PackApiServer get server => _server!;

  OverlayImage? get selectedOverlay {
    final id = selectedOverlayId;
    if (id == null || project == null) return null;
    for (final o in project!.overlays) {
      if (o.id == id) return o;
    }
    return null;
  }

  Future<void> init() async {
    ffmpegPath ??= await locateFfmpeg();
    if (_repository == null) {
      final support = await getApplicationSupportDirectory();
      _repository = PackRepository(Directory(p.join(support.path, 'packs')));
    }
    _server ??= PackApiServer(repository);
    final ffmpeg = ffmpegPath;
    if (ffmpeg != null) await repository.ensureBuiltIn(ffmpeg);
    repository.addListener(refreshPacks);
    await refreshPacks();
    ready = true;
    notifyListeners();
  }

  Future<void> refreshPacks() async {
    packs = await repository.list();
    notifyListeners();
  }

  Future<void> openVideo(String path) async {
    final ffmpeg = ffmpegPath;
    if (ffmpeg == null) {
      throw StateError('FFmpeg nao encontrado.');
    }
    final info = await probeMedia(ffmpeg, path);
    project?.removeListener(notifyListeners);
    project?.dispose();
    project = EditProject(source: path, info: info)..addListener(notifyListeners);
    selectedClip = 0;
    selectedOverlayId = null;
    notifyListeners();
  }

  void selectClip(int i) {
    selectedClip = i;
    notifyListeners();
  }

  void selectOverlay(String? id) {
    selectedOverlayId = id;
    notifyListeners();
  }

  OverlayImage addOverlay(String path) {
    final proj = project!;
    final overlay = OverlayImage(
      id: 'img${++_counter}',
      path: path,
      end: proj.duration,
    );
    proj.overlays.add(overlay);
    selectedOverlayId = overlay.id;
    proj.touch();
    return overlay;
  }

  void removeOverlay(OverlayImage o) {
    project!.overlays.remove(o);
    if (selectedOverlayId == o.id) selectedOverlayId = null;
    project!.touch();
  }

  Future<void> removeOverlayBackground(OverlayImage o, double tolerance) async {
    final original = o.originalPath ?? o.path;
    final bytes = await File(original).readAsBytes();
    final png = await compute(_removeBackgroundIsolate, <Object>[bytes, tolerance]);
    final dir = Directory(p.join((await getTemporaryDirectory()).path, 'gravadoc_overlays'));
    await dir.create(recursive: true);
    final out = File(p.join(
        dir.path, '${o.id}-${DateTime.now().microsecondsSinceEpoch}.png'));
    await out.writeAsBytes(png);
    o.originalPath = original;
    o.path = out.path;
    project!.touch();
  }

  void restoreOverlayOriginal(OverlayImage o) {
    final original = o.originalPath;
    if (original == null) return;
    o.path = original;
    o.originalPath = null;
    project!.touch();
  }

  SoundItem addSound(PackSound sound, double at) {
    final proj = project!;
    final item = SoundItem(
      id: 'snd${++_counter}',
      name: sound.name,
      path: sound.path,
      at: at.clamp(0, proj.duration).toDouble(),
      gain: sound.gain,
      duration: 5,
    );
    proj.sounds.add(item);
    proj.touch();
    return item;
  }

  void removeSound(SoundItem s) {
    project!.sounds.remove(s);
    project!.touch();
  }

  Future<ExportJob> startExport(
    String target, {
    bool preview = false,
    void Function(double)? onProgress,
  }) {
    final ffmpeg = ffmpegPath;
    final proj = project;
    if (ffmpeg == null || proj == null) {
      throw StateError('Nada para exportar.');
    }
    if (p.equals(target, proj.source)) {
      throw StateError('Escolha um destino diferente do video original.');
    }
    return ExportJob.start(
      ffmpeg,
      buildExportPlan(proj, output: target, preview: preview),
      onProgress: onProgress,
    );
  }

  Future<String> previewPath() async {
    final dir = await getTemporaryDirectory();
    return p.join(dir.path, 'gravadoc_preview_${DateTime.now().millisecondsSinceEpoch}.mp4');
  }

  @override
  void dispose() {
    _repository?.removeListener(refreshPacks);
    _server?.stop();
    project?.dispose();
    super.dispose();
  }
}
