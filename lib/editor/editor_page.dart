import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../cursor/kinetic_cursor_controller.dart';
import '../cursor/kinetic_cursor_options.dart';
import '../cursor/kinetic_cursor_painter.dart';
import '../cursor/cursor_export.dart';
import 'editor_controller.dart';
import 'export_builder.dart';
import 'project.dart';
import 'side_panels.dart';
import 'timeline_view.dart';

const _accent = Color(0xFFB6FF4A);

class EditorPage extends StatefulWidget {
  const EditorPage({super.key, this.videoPath, this.controller});

  final String? videoPath;
  final EditorController? controller;

  @override
  State<EditorPage> createState() => EditorPageState();
}

class EditorPageState extends State<EditorPage> with TickerProviderStateMixin {
  late final EditorController c;
  late final bool _ownsController;
  late final Player _player;
  late final VideoController _video;
  late final Player _sfx;
  late final TabController _tabs;
  late final KineticCursorController _kineticCursor;
  final _subs = <StreamSubscription<Object?>>[];

  double _playhead = 0;
  int _cur = 0;
  bool _seeking = false;
  bool _playing = false;
  bool _loading = false;
  DateTime _seekGuard = DateTime.fromMillisecondsSinceEpoch(0);
  String? _openedSource;
  List<EditClip>? _knownClips;

  double get playhead => _playhead;
  bool get playing => _playing;
  Duration get sourcePosition => _player.state.position;

  @override
  void initState() {
    super.initState();
    try {
      MediaKit.ensureInitialized();
    } on Object catch (_) {
      // O player sera aberto somente depois que um video estiver disponivel.
    }
    _ownsController = widget.controller == null;
    c = widget.controller ?? EditorController();
    _tabs = TabController(length: 5, vsync: this);
    _player = Player();
    _video = VideoController(_player);
    _sfx = Player();
    _kineticCursor = KineticCursorController(vsync: this);
    _kineticCursor.start();
    _subs.add(_player.stream.position.listen(_onPosition));
    _subs.add(
      _player.stream.playing.listen((v) {
        if (mounted) setState(() => _playing = v);
      }),
    );
    _subs.add(
      _player.stream.completed.listen((done) {
        if (done) _advance();
      }),
    );
    c.addListener(_onControllerChanged);
    _boot();
  }

  Future<void> _boot() async {
    if (_ownsController) {
      try {
        await c.init();
      } on Object catch (e) {
        _message('Nao foi possivel iniciar o editor: $e');
      }
    }
    final path = widget.videoPath;
    if (path != null && c.project?.source != path) {
      await _load(path);
    } else {
      await _syncSource();
    }
  }

  @override
  void didUpdateWidget(EditorPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final path = widget.videoPath;
    if (path != null &&
        path != oldWidget.videoPath &&
        c.project?.source != path) {
      _load(path);
    }
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    c.removeListener(_onControllerChanged);
    _tabs.dispose();
    _player.dispose();
    _sfx.dispose();
    _kineticCursor.dispose();
    if (_ownsController) c.dispose();
    super.dispose();
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _load(String path) async {
    setState(() => _loading = true);
    try {
      await c.openVideo(path);
      await _syncSource();
    } on Object catch (e) {
      _message('Nao foi possivel abrir o video: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _syncSource() async {
    final proj = c.project;
    if (proj == null || proj.source == _openedSource) return;
    _openedSource = proj.source;
    _knownClips = proj.clips;
    _cur = 0;
    _playhead = 0;
    await _player.open(Media(proj.source), play: false);
    if (mounted) setState(() {});
  }

  // Estrutura mudou (dividir, remover, mover, transicao): recoloca o player.
  void _onControllerChanged() {
    final proj = c.project;
    if (proj == null) return;
    if (proj.source != _openedSource) {
      _syncSource();
      return;
    }
    if (!identical(proj.clips, _knownClips)) {
      _knownClips = proj.clips;
      _seekTimeline(math.min(_playhead, proj.duration));
    }
  }

  Future<void> _seekTimeline(double t) async {
    final proj = c.project;
    if (proj == null) return;
    final time = t.clamp(0, proj.duration).toDouble();
    final at = proj.locate(time);
    _cur = at.index;
    _seeking = true;
    if (mounted) setState(() => _playhead = time);
    try {
      await _player.seek(Duration(milliseconds: (at.source * 1000).round()));
    } finally {
      _seeking = false;
      _seekGuard = DateTime.now().add(const Duration(milliseconds: 150));
    }
  }

  void _onPosition(Duration position) {
    final proj = c.project;
    if (proj == null || _seeking || _cur >= proj.clips.length) return;
    if (DateTime.now().isBefore(_seekGuard)) return;
    final s = position.inMilliseconds / 1000;
    final clip = proj.clips[_cur];
    final overlap = _cur + 1 < proj.clips.length
        ? proj.transitionInto(_cur + 1)
        : 0;
    final handover = math.max(clip.end - overlap, clip.start + 0.05);
    if (s >= handover - 0.03) {
      _advance();
      return;
    }
    final t = proj.clipStart(_cur) + (s - clip.start).clamp(0, clip.duration);
    if (_playing) _triggerSounds(_playhead, t);
    if (mounted) setState(() => _playhead = t);
  }

  // Pula para o proximo clipe (ignorando o trecho removido) ou para no fim.
  Future<void> _advance() async {
    final proj = c.project;
    if (proj == null || _seeking) return;
    _seeking = true;
    try {
      if (_cur + 1 < proj.clips.length) {
        _cur += 1;
        _playhead = proj.clipStart(_cur);
        await _player.seek(
          Duration(milliseconds: (proj.clips[_cur].start * 1000).round()),
        );
        if (_playing) _triggerSounds(_playhead - 0.001, _playhead);
      } else {
        await _player.pause();
        _playhead = proj.duration;
      }
    } finally {
      _seeking = false;
      _seekGuard = DateTime.now().add(const Duration(milliseconds: 150));
      if (mounted) setState(() {});
    }
  }

  void _triggerSounds(double from, double to) {
    final proj = c.project;
    if (proj == null || to <= from || to - from > 0.5) return;
    String? path;
    double gain = 1;
    for (final s in proj.sounds) {
      if (s.at > from && s.at <= to) {
        path = s.path;
        gain = s.gain;
      }
    }
    for (var i = 1; i < proj.clips.length; i++) {
      final sfx = proj.clips[i].transition?.sfxPath;
      final at = proj.clipStart(i);
      if (sfx != null && at > from && at <= to) {
        path = sfx;
        gain = proj.clips[i].transition!.sfxGain;
      }
    }
    if (path != null) _playSound(path, gain);
  }

  Future<void> _playSound(String path, [double gain = 1]) async {
    await _sfx.setVolume((gain * 100).clamp(0, 100).toDouble());
    await _sfx.open(Media(path));
  }

  Future<void> _togglePlay() async {
    final proj = c.project;
    if (proj == null) return;
    if (_playhead >= proj.duration - 0.05) await _seekTimeline(0);
    await _player.playOrPause();
  }

  Future<void> _pickVideo() async {
    final file = await FilePicker.pickFile(
      dialogTitle: 'Abrir video',
      type: FileType.custom,
      allowedExtensions: const ['mp4', 'mov', 'mkv', 'avi', 'webm', 'm4v'],
    );
    final path = file?.path;
    if (path != null) await _load(path);
  }

  void _split() {
    final proj = c.project;
    if (proj == null) return;
    if (!proj.splitAt(_playhead)) {
      _message(
        'Mova o cursor para dentro de um clipe (longe das bordas) para dividir.',
      );
      return;
    }
    c.selectClip(proj.locate(_playhead).index);
  }

  Future<void> _splitAt(double time) async {
    await _seekTimeline(time);
    _split();
  }

  void _deleteClip() {
    final proj = c.project;
    if (proj == null) return;
    final i = c.selectedClip;
    if (!proj.removeClip(i)) {
      _message('O video precisa ter ao menos um clipe.');
      return;
    }
    final next = math.min(i, proj.clips.length - 1);
    c.selectClip(next);
    _seekTimeline(proj.clipStart(next));
  }

  void _moveClip(int delta) {
    final proj = c.project;
    if (proj == null) return;
    final i = c.selectedClip;
    if (proj.moveClip(i, delta)) {
      c.selectClip(i + delta);
      _seekTimeline(proj.clipStart(i + delta));
    }
  }

  Future<bool> _runWithProgress(
    String title,
    String target, {
    bool preview = false,
  }) async {
    final progress = ValueNotifier<double>(0);
    ExportJob? job;
    var cancelled = false;
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: ValueListenableBuilder<double>(
            valueListenable: progress,
            builder: (context, v, _) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(
                  key: const Key('export-progress'),
                  value: v,
                ),
                const SizedBox(height: 8),
                Text('${(v * 100).round()}%'),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                cancelled = true;
                job?.cancel();
              },
              child: const Text('Cancelar'),
            ),
          ],
        ),
      ),
    );
    try {
      job = await c.startExport(
        target,
        preview: preview,
        onProgress: (v) => progress.value = v,
      );
      await job.done;
      return true;
    } on Object catch (e) {
      if (!cancelled) _message('Falha: $e');
      return false;
    } finally {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      progress.dispose();
    }
  }

  Future<void> _export() async {
    final proj = c.project;
    if (proj == null) return;
    final dest = await FilePicker.saveFile(
      dialogTitle: 'Exportar video editado',
      fileName: 'gravadoC-editado-${DateTime.now().millisecondsSinceEpoch}.mp4',
      bytes: Uint8List(0),
      mimeType: 'video/mp4',
    );
    if (dest == null || !mounted) return;
    final target = dest.toFilePath();
    if (await _runWithProgress('Exportando...', target)) {
      final clip = proj.clips[c.selectedClip];
      final options = clip.kineticCursor;
      if (options?.enabled == true &&
          _kineticCursor.samples.isNotEmpty &&
          c.ffmpegPath != null) {
        final tempDir = await getTemporaryDirectory();
        final cursorTarget = p.join(
          tempDir.path,
          'gravadoc_cursor_export_${DateTime.now().millisecondsSinceEpoch}.mp4',
        );
        await exportWithCursor(
          ffmpegPath: c.ffmpegPath!,
          source: target,
          target: cursorTarget,
          width: proj.width,
          height: proj.height,
          fps: proj.fps,
          duration: proj.duration,
          samples: _kineticCursor.samples,
          options: options!,
        );
        await File(cursorTarget).copy(target);
        try {
          await File(cursorTarget).delete();
        } on FileSystemException {}
      }
      _message('Video exportado em $target');
    }
  }

  Future<void> _previewRender() async {
    if (c.project == null) return;
    await _player.pause();
    final target = await c.previewPath();
    if (!mounted) return;
    if (!await _runWithProgress(
      'Renderizando previa...',
      target,
      preview: true,
    ))
      return;
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _PreviewDialog(path: target),
    );
    try {
      await File(target).delete();
    } on FileSystemException {
      // Arquivo temporario ainda em uso: sera limpo pelo sistema.
    }
  }

  KineticCursorOptions _kineticOptions(EditProject proj) {
    final clip = proj.clips[c.selectedClip];
    return clip.kineticCursor ??= KineticCursorOptions();
  }

  void _toggleKineticCursor(EditProject proj) {
    final options = _kineticOptions(proj);
    options.enabled = !options.enabled;
    _kineticCursor.setSmoothing(options.smoothing);
    proj.touch();
  }

  Future<void> _showKineticCursorSettings(EditProject proj) async {
    final options = _kineticOptions(proj);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF10141D),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Kinetic Cursor',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 16),
                    _editorSlider(
                      label: 'Suavizacao',
                      value: options.smoothing,
                      min: 0,
                      max: 100,
                      text: '${options.smoothing.round()}%',
                      onChanged: (value) {
                        setSheetState(() => options.smoothing = value);
                        _kineticCursor.setSmoothing(value);
                        proj.touch();
                      },
                    ),
                    _editorSlider(
                      label: 'Escala',
                      value: options.scale,
                      min: 1,
                      max: 3,
                      text: options.scale.toStringAsFixed(1),
                      onChanged: (value) {
                        setSheetState(() => options.scale = value);
                        proj.touch();
                      },
                    ),
                    _editorSlider(
                      label: 'Motion blur',
                      value: options.motionBlurIntensity,
                      min: 0,
                      max: 100,
                      text: '${options.motionBlurIntensity.round()}%',
                      onChanged: (value) {
                        setSheetState(
                          () => options.motionBlurIntensity = value,
                        );
                        proj.touch();
                      },
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Motion blur'),
                      value: options.motionBlur,
                      onChanged: (value) {
                        setSheetState(() => options.motionBlur = value);
                        proj.touch();
                      },
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Animacao de clique'),
                      value: options.clickAnimation,
                      onChanged: (value) {
                        setSheetState(() => options.clickAnimation = value);
                        proj.touch();
                      },
                    ),
                    DropdownButtonFormField<CursorStyle>(
                      value: options.style,
                      decoration: const InputDecoration(
                        labelText: 'Estilo do cursor',
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: CursorStyle.arrow,
                          child: Text('Seta'),
                        ),
                        DropdownMenuItem(
                          value: CursorStyle.hand,
                          child: Text('Mao'),
                        ),
                        DropdownMenuItem(
                          value: CursorStyle.auto,
                          child: Text('Automatico'),
                        ),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        setSheetState(() => options.style = value);
                        proj.touch();
                      },
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      'Cor de destaque',
                      style: TextStyle(fontSize: 12, color: Colors.white70),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 10,
                      children:
                          [
                            const Color(0xFFB6FF4A),
                            const Color(0xFF4DC3FF),
                            const Color(0xFFFFB74D),
                            const Color(0xFFFF4967),
                            const Color(0xFFB66AFF),
                          ].map((color) {
                            final selected =
                                options.highlightColor.toARGB32() ==
                                color.toARGB32();
                            return InkWell(
                              onTap: () {
                                setSheetState(
                                  () => options.highlightColor = color,
                                );
                                proj.touch();
                              },
                              child: Container(
                                width: 34,
                                height: 34,
                                decoration: BoxDecoration(
                                  color: color,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: selected
                                        ? Colors.white
                                        : Colors.transparent,
                                    width: 3,
                                  ),
                                ),
                              ),
                            );
                          }).toList(),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _editorSlider({
    required String label,
    required double value,
    required double min,
    required double max,
    required String text,
    required ValueChanged<double> onChanged,
  }) {
    return Row(
      children: [
        SizedBox(width: 110, child: Text(label)),
        Expanded(
          child: Slider(
            value: value.clamp(min, max).toDouble(),
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ),
        SizedBox(width: 48, child: Text(text, textAlign: TextAlign.right)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final proj = c.project;
        return Row(
          children: [
            Container(
              width: 340,
              decoration: const BoxDecoration(
                color: Color(0xFF10141D),
                border: Border(right: BorderSide(color: Color(0xFF252B39))),
              ),
              child: Material(
                color: Colors.transparent,
                child: Column(
                  children: [
                    TabBar(
                      controller: _tabs,
                      labelColor: _accent,
                      indicatorColor: _accent,
                      labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                      tabs: const [
                        Tab(text: 'Imagem'),
                        Tab(text: 'Transicoes'),
                        Tab(text: 'Sons'),
                        Tab(text: 'Audio'),
                        Tab(text: 'Pacotes'),
                      ],
                    ),
                    Expanded(
                      child: TabBarView(
                        controller: _tabs,
                        physics: const NeverScrollableScrollPhysics(),
                        children: [
                          ImagePanel(controller: c),
                          TransitionsPanel(controller: c),
                          SoundsPanel(
                            controller: c,
                            playhead: _playhead,
                            onPreview: _playSound,
                          ),
                          AudioPanel(controller: c),
                          c.ready
                              ? PacksPanel(controller: c)
                              : const Center(
                                  child: CircularProgressIndicator(),
                                ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(child: proj == null ? _empty() : _workspace(proj)),
          ],
        );
      },
    );
  }

  Widget _empty() => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.movie_edit, size: 56, color: Colors.white38),
        const SizedBox(height: 12),
        Text(
          _loading
              ? 'Abrindo video...'
              : 'Grave um video ou abra um arquivo para editar',
          style: const TextStyle(color: Colors.white54),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          key: const Key('open-video'),
          onPressed: _loading ? null : _pickVideo,
          icon: const Icon(Icons.folder_open),
          label: const Text('Abrir video'),
        ),
      ],
    ),
  );

  Widget _workspace(EditProject proj) {
    final rows = proj.overlays.length;
    return Column(
      children: [
        Container(
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: Color(0xFF252B39))),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Edicao • ${p.basename(proj.source)}',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              InkWell(
                key: const Key('kinetic-cursor-card'),
                onTap: () => _showKineticCursorSettings(proj),
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  height: 44,
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF171C27),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: _kineticOptions(proj).enabled
                          ? _accent
                          : const Color(0xFF30384A),
                      width: 1.5,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 50,
                        height: 36,
                        child: Stack(
                          children: [
                            Positioned(
                              left: 18,
                              top: 2,
                              child: _cursorThumbnail(),
                            ),
                            Positioned(
                              left: 10,
                              top: 8,
                              child: _cursorThumbnail(),
                            ),
                            Positioned(
                              left: 2,
                              top: 14,
                              child: _cursorThumbnail(),
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.mouse, size: 18),
                      const SizedBox(width: 5),
                      const Text(
                        'Kinetic Cursor',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Switch(
                        value: _kineticOptions(proj).enabled,
                        onChanged: (_) =>
                            setState(() => _toggleKineticCursor(proj)),
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: _pickVideo,
                icon: const Icon(Icons.folder_open, size: 18),
                label: const Text('Abrir'),
              ),
              const SizedBox(width: 6),
              OutlinedButton.icon(
                key: const Key('preview-render'),
                onPressed: _previewRender,
                icon: const Icon(Icons.slideshow, size: 18),
                label: const Text('Previa com transicoes'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                key: const Key('export-edit'),
                onPressed: _export,
                icon: const Icon(Icons.download, size: 18),
                label: const Text('Exportar'),
              ),
            ],
          ),
        ),
        Expanded(
          child: Container(
            margin: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF05070A),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF252B39)),
            ),
            clipBehavior: Clip.antiAlias,
            child: Center(
              child: AspectRatio(
                aspectRatio: proj.width / proj.height,
                child: LayoutBuilder(
                  builder: (context, box) => _stage(proj, box),
                ),
              ),
            ),
          ),
        ),
        _transport(proj),
        Container(
          height: (126 + rows * 14).clamp(142, 210).toDouble(),
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
          color: const Color(0xFF10141D),
          child: TimelineView(
            project: proj,
            playhead: _playhead,
            selectedClip: c.selectedClip,
            selectedOverlayId: c.selectedOverlayId,
            onSeek: _seekTimeline,
            onSelectClip: c.selectClip,
            onSelectOverlay: (id) {
              c.selectOverlay(id);
              _tabs.animateTo(0);
            },
            onTransitionTap: (i) {
              c.selectClip(i);
              _tabs.animateTo(1);
            },
            onMoveOverlay: (id, start, end) {
              for (final overlay in proj.overlays) {
                if (overlay.id == id) {
                  overlay.start = start;
                  overlay.end = end;
                  proj.touch();
                  break;
                }
              }
            },
            onResizeOverlay: (id, end) {
              for (final overlay in proj.overlays) {
                if (overlay.id == id) {
                  overlay.end = end;
                  proj.touch();
                  break;
                }
              }
            },
            onMoveSound: (id, at) {
              for (final sound in proj.sounds) {
                if (sound.id == id) {
                  sound.at = at;
                  proj.touch();
                  break;
                }
              }
            },
            onResizeSound: (id, duration) {
              for (final sound in proj.sounds) {
                if (sound.id == id) {
                  sound.duration = duration;
                  proj.touch();
                  break;
                }
              }
            },
            onSplitAt: _splitAt,
          ),
        ),
      ],
    );
  }

  Widget _cursorThumbnail() {
    return Container(
      width: 28,
      height: 20,
      decoration: BoxDecoration(
        color: const Color(0xFFB8C8A1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.white38),
      ),
      child: const Icon(Icons.near_me, size: 14, color: Colors.white),
    );
  }

  Widget _stage(EditProject proj, BoxConstraints box) {
    final w = box.maxWidth;
    final h = box.maxHeight;
    final clip = proj.clips[c.selectedClip];
    final kinetic = clip.kineticCursor;
    return ClipRect(
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerHover: (event) {
          if (kinetic?.enabled != true) return;
          final local = event.localPosition;
          _kineticCursor.addSample(
            x: local.dx / w,
            y: local.dy / h,
            timeMs: _player.state.position.inMilliseconds,
          );
        },
        onPointerMove: (event) {
          if (kinetic?.enabled != true) return;
          final local = event.localPosition;
          _kineticCursor.addSample(
            x: local.dx / w,
            y: local.dy / h,
            timeMs: _player.state.position.inMilliseconds,
          );
        },
        onPointerDown: (event) {
          if (kinetic?.enabled != true) return;
          final local = event.localPosition;
          _kineticCursor.addSample(
            x: local.dx / w,
            y: local.dy / h,
            timeMs: _player.state.position.inMilliseconds,
            isClick: true,
          );
        },
        child: Stack(
          children: [
            Positioned.fill(
              child: Video(controller: _video, controls: NoVideoControls),
            ),
            if (kinetic?.enabled == true)
              Positioned.fill(
                child: RepaintBoundary(
                  child: ListenableBuilder(
                    listenable: _kineticCursor,
                    builder: (context, _) => CustomPaint(
                      painter: KineticCursorPainter(
                        controller: _kineticCursor,
                        options: kinetic!,
                        timeMs: _player.state.position.inMilliseconds,
                      ),
                      isComplex: true,
                      willChange: true,
                    ),
                  ),
                ),
              ),
            for (final o in proj.overlays)
              if (_playhead >= o.start && _playhead <= o.end ||
                  o.id == c.selectedOverlayId)
                Positioned(
                  left: o.x * w,
                  top: o.y * h,
                  child: FractionalTranslation(
                    translation: const Offset(-0.5, -0.5),
                    child: GestureDetector(
                      key: ValueKey('overlay-${o.id}'),
                      onTap: () {
                        c.selectOverlay(o.id);
                        _tabs.animateTo(0);
                      },
                      onPanUpdate: (d) {
                        o.x = (o.x + d.delta.dx / w).clamp(0, 1).toDouble();
                        o.y = (o.y + d.delta.dy / h).clamp(0, 1).toDouble();
                        proj.touch();
                      },
                      child: Transform.rotate(
                        angle: o.rotation * math.pi / 180,
                        child: Opacity(
                          opacity:
                              o.opacity *
                              ((_playhead >= o.start && _playhead <= o.end)
                                  ? 1
                                  : 0.3),
                          child: Container(
                            width: o.scale * w,
                            decoration: o.id == c.selectedOverlayId
                                ? BoxDecoration(
                                    border: Border.all(
                                      color: _accent,
                                      width: 1.5,
                                    ),
                                  )
                                : null,
                            child: Image.file(
                              File(o.path),
                              fit: BoxFit.contain,
                              gaplessPlayback: true,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }

  Widget _transport(EditProject proj) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      child: Row(
        children: [
          IconButton.filled(
            key: const Key('play'),
            onPressed: _togglePlay,
            icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
          ),
          const SizedBox(width: 8),
          Text(
            '${formatTime(_playhead)} / ${formatTime(proj.duration)}',
            key: const Key('time-label'),
            style: const TextStyle(
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          const Spacer(),
          FilledButton.tonalIcon(
            key: const Key('split'),
            onPressed: _split,
            icon: const Icon(Icons.content_cut, size: 16),
            label: const Text('Dividir'),
          ),
          const SizedBox(width: 6),
          IconButton(
            key: const Key('move-left'),
            tooltip: 'Mover clipe para tras',
            onPressed: c.selectedClip > 0 ? () => _moveClip(-1) : null,
            icon: const Icon(Icons.arrow_back),
          ),
          IconButton(
            key: const Key('move-right'),
            tooltip: 'Mover clipe para frente',
            onPressed: c.selectedClip < proj.clips.length - 1
                ? () => _moveClip(1)
                : null,
            icon: const Icon(Icons.arrow_forward),
          ),
          IconButton(
            key: const Key('delete-clip'),
            tooltip: 'Excluir clipe selecionado',
            onPressed: proj.clips.length > 1 ? _deleteClip : null,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
    );
  }
}

class _PreviewDialog extends StatefulWidget {
  const _PreviewDialog({required this.path});

  final String path;

  @override
  State<_PreviewDialog> createState() => _PreviewDialogState();
}

class _PreviewDialogState extends State<_PreviewDialog> {
  late final Player _player = Player();
  late final VideoController _video = VideoController(_player);

  @override
  void initState() {
    super.initState();
    _player.open(Media(widget.path));
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text(
        'Previa renderizada (inclui transicoes, imagens e sons)',
      ),
      content: SizedBox(
        width: 640,
        height: 380,
        child: Video(controller: _video),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Fechar'),
        ),
      ],
    );
  }
}
