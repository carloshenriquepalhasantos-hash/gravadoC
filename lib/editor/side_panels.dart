import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../packs/pack_downloader.dart';
import 'editor_controller.dart';
import 'project.dart';
import 'timeline_view.dart';

const _accent = Color(0xFFB6FF4A);

void _msg(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

Future<String?> _askText(BuildContext context, String title, String hint) {
  final field = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: field,
        autofocus: true,
        decoration: InputDecoration(hintText: hint),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(
            onPressed: () => Navigator.pop(context, field.text),
            child: const Text('OK')),
      ],
    ),
  );
}

class LabeledSlider extends StatelessWidget {
  const LabeledSlider({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.text,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;
  final String? text;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      SizedBox(
          width: 70,
          child: Text(label, style: const TextStyle(fontSize: 12, color: Colors.white70))),
      Expanded(
        child: Slider(
          value: value.clamp(min, max).toDouble(),
          min: min,
          max: max,
          onChanged: onChanged,
        ),
      ),
      SizedBox(
          width: 44,
          child: Text(text ?? value.toStringAsFixed(2),
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 11, color: Colors.white54))),
    ]);
  }
}

class ImagePanel extends StatefulWidget {
  const ImagePanel({super.key, required this.controller});

  final EditorController controller;

  @override
  State<ImagePanel> createState() => _ImagePanelState();
}

class _ImagePanelState extends State<ImagePanel> {
  double _tolerance = 40;
  bool _busy = false;

  EditorController get c => widget.controller;

  Future<void> _pick() async {
    final file = await FilePicker.pickFile(
      dialogTitle: 'Escolha uma imagem',
      type: FileType.custom,
      allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp', 'bmp', 'gif'],
    );
    final path = file?.path;
    if (path != null) c.addOverlay(path);
  }

  Future<void> _removeBackground(OverlayImage o) async {
    setState(() => _busy = true);
    try {
      await c.removeOverlayBackground(o, _tolerance);
    } on Object catch (e) {
      if (mounted) _msg(context, 'Nao foi possivel remover o fundo: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final project = c.project;
    final o = c.selectedOverlay;
    return ListView(padding: const EdgeInsets.all(14), children: [
      FilledButton.icon(
        key: const Key('add-image'),
        onPressed: project == null ? null : _pick,
        icon: const Icon(Icons.add_photo_alternate),
        label: const Text('Adicionar imagem'),
      ),
      const SizedBox(height: 8),
      if (project != null && project.overlays.isEmpty)
        const Text('PNG com transparencia, JPG ou WebP. Arraste a imagem no preview para posicionar.',
            style: TextStyle(fontSize: 12, color: Colors.white54)),
      if (project != null)
        Wrap(spacing: 6, children: [
          for (final img in project.overlays)
            ChoiceChip(
              key: ValueKey('chip-${img.id}'),
              label: Text(img.path.split(RegExp(r'[\\/]')).last,
                  overflow: TextOverflow.ellipsis),
              selected: img.id == c.selectedOverlayId,
              onSelected: (_) => c.selectOverlay(img.id),
            ),
        ]),
      if (o != null && project != null) ...[
        const Divider(height: 26),
        LabeledSlider(
            label: 'Opacidade',
            value: o.opacity,
            min: 0,
            max: 1,
            text: '${(o.opacity * 100).round()}%',
            onChanged: (v) {
              o.opacity = v;
              project.touch();
            }),
        LabeledSlider(
            label: 'Tamanho',
            value: o.scale,
            min: 0.05,
            max: 1,
            text: '${(o.scale * 100).round()}%',
            onChanged: (v) {
              o.scale = v;
              project.touch();
            }),
        LabeledSlider(
            label: 'Rotacao',
            value: o.rotation,
            min: -180,
            max: 180,
            text: '${o.rotation.round()}°',
            onChanged: (v) {
              o.rotation = v;
              project.touch();
            }),
        LabeledSlider(
            label: 'Posicao X',
            value: o.x,
            min: 0,
            max: 1,
            onChanged: (v) {
              o.x = v;
              project.touch();
            }),
        LabeledSlider(
            label: 'Posicao Y',
            value: o.y,
            min: 0,
            max: 1,
            onChanged: (v) {
              o.y = v;
              project.touch();
            }),
        const SizedBox(height: 4),
        Text('Aparece de ${formatTime(o.start)} ate ${formatTime(o.end)}',
            style: const TextStyle(fontSize: 12, color: Colors.white70)),
        RangeSlider(
          key: const Key('overlay-range'),
          values: RangeValues(
            o.start.clamp(0, project.duration).toDouble(),
            o.end.clamp(0, project.duration).toDouble(),
          ),
          min: 0,
          max: project.duration,
          onChanged: (v) {
            o.start = v.start;
            o.end = v.end;
            project.touch();
          },
        ),
        const Divider(height: 26),
        const Text('Remover fundo', style: TextStyle(fontWeight: FontWeight.w700)),
        const Text(
            'Funciona para fundo de cor uniforme (branco, verde...). Nao e recorte por IA.',
            style: TextStyle(fontSize: 11, color: Colors.white54)),
        LabeledSlider(
            label: 'Tolerancia',
            value: _tolerance,
            min: 5,
            max: 150,
            text: _tolerance.round().toString(),
            onChanged: (v) => setState(() => _tolerance = v)),
        Row(children: [
          Expanded(
            child: FilledButton.tonalIcon(
              key: const Key('remove-bg'),
              onPressed: _busy ? null : () => _removeBackground(o),
              icon: _busy
                  ? const SizedBox(
                      width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.auto_fix_high),
              label: const Text('Remover fundo'),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: o.originalPath == null ? null : () => c.restoreOverlayOriginal(o),
            child: const Text('Original'),
          ),
        ]),
        const SizedBox(height: 10),
        TextButton.icon(
          key: const Key('delete-image'),
          onPressed: () => c.removeOverlay(o),
          icon: const Icon(Icons.delete_outline),
          label: const Text('Excluir imagem'),
        ),
      ],
    ]);
  }
}

class TransitionsPanel extends StatefulWidget {
  const TransitionsPanel({super.key, required this.controller});

  final EditorController controller;

  @override
  State<TransitionsPanel> createState() => _TransitionsPanelState();
}

class _TransitionsPanelState extends State<TransitionsPanel> {
  String _query = '';

  EditorController get c => widget.controller;

  @override
  Widget build(BuildContext context) {
    final project = c.project;
    if (project == null) return const Center(child: Text('Abra um video.'));
    final i = c.selectedClip;
    final canApply = i >= 1 && i < project.clips.length;
    final current = canApply ? project.clips[i].transition : null;
    final allSounds = [for (final p in c.packs) ...p.sounds];

    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            canApply
                ? 'Transicao entre o clipe $i e o clipe ${i + 1}'
                : 'Selecione o 2o clipe (ou posterior) na linha do tempo para aplicar uma transicao.',
            style: TextStyle(fontSize: 12, color: canApply ? Colors.white : Colors.white54),
          ),
          if (current != null) ...[
            const SizedBox(height: 6),
            Row(children: [
              Expanded(
                  child: Text('Atual: ${current.name}',
                      key: const Key('current-transition'),
                      style: const TextStyle(color: _accent, fontWeight: FontWeight.w700))),
              TextButton(
                  key: const Key('remove-transition'),
                  onPressed: () => project.setTransition(i, null),
                  child: const Text('Remover')),
            ]),
            LabeledSlider(
              label: 'Duracao',
              value: current.duration,
              min: 0.1,
              max: 3,
              text: '${current.duration.toStringAsFixed(1)}s',
              onChanged: (v) => project.setTransition(i, current.copyWith(duration: v)),
            ),
            Row(children: [
              const Text('Som:', style: TextStyle(fontSize: 12, color: Colors.white70)),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButton<String?>(
                  isExpanded: true,
                  value: allSounds.any((s) => s.path == current.sfxPath) ? current.sfxPath : null,
                  items: [
                    const DropdownMenuItem(value: null, child: Text('Nenhum')),
                    for (final s in allSounds)
                      DropdownMenuItem(value: s.path, child: Text(s.name)),
                  ],
                  onChanged: (path) => project.setTransition(
                      i,
                      path == null
                          ? current.copyWith(clearSfx: true)
                          : current.copyWith(sfxPath: path)),
                ),
              ),
            ]),
          ],
          const SizedBox(height: 6),
          TextField(
            decoration: const InputDecoration(
                isDense: true, prefixIcon: Icon(Icons.search, size: 18), hintText: 'Buscar transicao'),
            onChanged: (v) => setState(() => _query = v.toLowerCase()),
          ),
        ]),
      ),
      Expanded(
        child: ListView(children: [
          for (final pack in c.packs)
            if (pack.transitions.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 2),
                child: Text(pack.name.toUpperCase(),
                    style: const TextStyle(fontSize: 10, color: Colors.white38)),
              ),
              for (final t in pack.transitions.where((t) =>
                  _query.isEmpty ||
                  t.name.toLowerCase().contains(_query) ||
                  t.xfade.contains(_query)))
                ListTile(
                  key: ValueKey('tr-${pack.id}-${t.id}'),
                  dense: true,
                  enabled: canApply,
                  selected: current?.xfade == t.xfade,
                  title: Text(t.name),
                  subtitle: Text(
                      t.sfxPath == null ? t.xfade : '${t.xfade} + som',
                      style: const TextStyle(fontSize: 10)),
                  onTap: () => project.setTransition(i, t.toSpec()),
                ),
            ],
        ]),
      ),
    ]);
  }
}

class SoundsPanel extends StatelessWidget {
  const SoundsPanel({
    super.key,
    required this.controller,
    required this.playhead,
    required this.onPreview,
  });

  final EditorController controller;
  final double playhead;
  final ValueChanged<String> onPreview;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final project = c.project;
    return ListView(padding: const EdgeInsets.only(bottom: 12), children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 4),
        child: Text(
          project == null
              ? 'Abra um video.'
              : 'Inserir no cursor: ${formatTime(playhead)}',
          style: const TextStyle(fontSize: 12, color: Colors.white70),
        ),
      ),
      for (final pack in c.packs)
        if (pack.sounds.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 2),
            child: Text(pack.name.toUpperCase(),
                style: const TextStyle(fontSize: 10, color: Colors.white38)),
          ),
          for (final s in pack.sounds)
            ListTile(
              key: ValueKey('snd-${pack.id}-${s.id}'),
              dense: true,
              title: Text(s.name),
              subtitle: Text(s.category, style: const TextStyle(fontSize: 10)),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                  tooltip: 'Ouvir',
                  icon: const Icon(Icons.play_arrow),
                  onPressed: () => onPreview(s.path),
                ),
                IconButton(
                  key: ValueKey('insert-${pack.id}-${s.id}'),
                  tooltip: 'Inserir no cursor',
                  icon: const Icon(Icons.add_circle_outline),
                  onPressed: project == null ? null : () => c.addSound(s, playhead),
                ),
              ]),
            ),
        ],
      if (project != null && project.sounds.isNotEmpty) ...[
        const Divider(height: 28),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 14),
          child: Text('Sons na linha do tempo',
              style: TextStyle(fontWeight: FontWeight.w700)),
        ),
        for (final s in project.sounds)
          Padding(
            key: ValueKey('placed-${s.id}'),
            padding: const EdgeInsets.fromLTRB(14, 6, 6, 0),
            child: Column(children: [
              Row(children: [
                Expanded(child: Text('${s.name} • ${formatTime(s.at)}')),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 18),
                  onPressed: () => c.removeSound(s),
                ),
              ]),
              LabeledSlider(
                label: 'Volume',
                value: s.gain,
                min: 0,
                max: 2,
                text: '${(s.gain * 100).round()}%',
                onChanged: (v) {
                  s.gain = v;
                  project.touch();
                },
              ),
              LabeledSlider(
                label: 'Inicio',
                value: s.at,
                min: 0,
                max: project.duration,
                text: formatTime(s.at),
                onChanged: (v) {
                  s.at = v;
                  project.touch();
                },
              ),
              LabeledSlider(
                label: 'Duracao',
                value: s.duration.clamp(0.1, project.duration).toDouble(),
                min: 0.1,
                max: project.duration,
                text: '${s.duration.toStringAsFixed(1)}s',
                onChanged: (v) {
                  s.duration = v;
                  project.touch();
                },
              ),
            ]),
          ),
      ],
    ]);
  }
}

class AudioPanel extends StatelessWidget {
  const AudioPanel({super.key, required this.controller});

  final EditorController controller;

  @override
  Widget build(BuildContext context) {
    final project = controller.project;
    if (project == null) {
      return const Center(
        child: Text('Abra um video para ajustar o audio.',
            style: TextStyle(color: Colors.white54)),
      );
    }

    final separated = project.audioStreamCount > 1;
    return ListView(padding: const EdgeInsets.all(14), children: [
      const Text('Controle de audio',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
      const SizedBox(height: 6),
      Text(
        separated
            ? 'Microfone e audio do sistema foram gravados em faixas separadas.'
            : 'Este video possui uma faixa de audio combinada.',
        style: const TextStyle(fontSize: 12, color: Colors.white54),
      ),
      const SizedBox(height: 14),
      if (separated) ...[
        LabeledSlider(
          label: 'Voz',
          value: project.voiceGain,
          min: 0,
          max: 2,
          text: '${(project.voiceGain * 100).round()}%',
          onChanged: (v) {
            project.voiceGain = v;
            project.touch();
          },
        ),
        LabeledSlider(
          label: 'Sons externos',
          value: project.systemAudioGain,
          min: 0,
          max: 2,
          text: '${(project.systemAudioGain * 100).round()}%',
          onChanged: (v) {
            project.systemAudioGain = v;
            project.touch();
          },
        ),
      ] else
        LabeledSlider(
          label: 'Audio geral',
          value: project.originalAudioGain,
          min: 0,
          max: 2,
          text: '${(project.originalAudioGain * 100).round()}%',
          onChanged: (v) {
            project.originalAudioGain = v;
            project.touch();
          },
        ),
      const Divider(height: 28),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Reduzir ruido'),
        subtitle: const Text('Reducao filtrada de ruido de fundo'),
        value: project.noiseReduction,
        onChanged: (v) {
          project.noiseReduction = v;
          project.touch();
        },
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Realcar voz'),
        subtitle: const Text('Equaliza frequencias e estabiliza a voz'),
        value: project.voiceEnhancement,
        onChanged: (v) {
          project.voiceEnhancement = v;
          project.touch();
        },
      ),
      const SizedBox(height: 8),
      const Text(
        'Para separar voz e sons externos em arquivos ja gravados, use um novo video gravado pelo gravadoC com microfone e sistema ativados.',
        style: TextStyle(fontSize: 11, color: Colors.white38),
      ),
    ]);
  }
}

class PacksPanel extends StatefulWidget {
  const PacksPanel({super.key, required this.controller});

  final EditorController controller;

  @override
  State<PacksPanel> createState() => _PacksPanelState();
}

class _PacksPanelState extends State<PacksPanel> {
  bool _busy = false;

  EditorController get c => widget.controller;

  Future<void> _run(Future<String?> Function() action) async {
    setState(() => _busy = true);
    try {
      final done = await action();
      if (done != null && mounted) _msg(context, done);
    } on Object catch (e) {
      if (mounted) _msg(context, 'Nao foi possivel instalar: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  PackDownloader _downloaderFor(Uri uri) => PackDownloader(
      allowLocal: uri.host == 'localhost' || uri.host == '127.0.0.1');

  Future<void> _importFolder() => _run(() async {
        final dir = await FilePicker.pickDirectory(dialogTitle: 'Pasta do pacote');
        if (dir == null) return null;
        final pack = await c.repository.installDirectory(Directory(dir.toFilePath()));
        return 'Pacote "${pack.name}" instalado.';
      });

  Future<void> _importZip() => _run(() async {
        final file = await FilePicker.pickFile(
          dialogTitle: 'Pacote .zip',
          type: FileType.custom,
          allowedExtensions: const ['zip'],
        );
        final path = file?.path;
        if (path == null) return null;
        final pack = await c.repository.installZipBytes(await File(path).readAsBytes());
        return 'Pacote "${pack.name}" instalado.';
      });

  Future<void> _importUrl() async {
    final text = await _askText(context, 'URL do pacote (.zip)', 'https://...');
    final uri = text == null ? null : Uri.tryParse(text.trim());
    if (uri == null) return;
    await _run(() async {
      final bytes = await _downloaderFor(uri).fetch(uri);
      final pack = await c.repository.installZipBytes(bytes);
      return 'Pacote "${pack.name}" instalado.';
    });
  }

  Future<void> _openCatalog() async {
    final text = await _askText(context, 'URL do catalogo (JSON)', 'https://.../catalog.json');
    final uri = text == null ? null : Uri.tryParse(text.trim());
    if (uri == null || !mounted) return;
    final catalog = RemoteCatalog(_downloaderFor(uri));
    try {
      final entries = await catalog.fetch(uri);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Catalogo remoto'),
          content: SizedBox(
            width: 420,
            height: 320,
            child: entries.isEmpty
                ? const Text('Nenhum pacote no catalogo.')
                : ListView(children: [
                    for (final e in entries)
                      ListTile(
                        title: Text('${e.name} ${e.version}'),
                        subtitle: Text(
                          '${e.license.isEmpty ? 'licenca nao informada' : e.license}'
                          ' • ${e.sha256 == null ? 'sem SHA-256' : 'SHA-256 verificado'}',
                          style: const TextStyle(fontSize: 11),
                        ),
                        trailing: const Icon(Icons.download),
                        onTap: () async {
                          Navigator.pop(context);
                          await _run(() async {
                            final pack = await catalog.install(c.repository, e);
                            return 'Pacote "${pack.name}" instalado.';
                          });
                        },
                      ),
                  ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Fechar'))
          ],
        ),
      );
    } on Object catch (e) {
      if (mounted) _msg(context, 'Catalogo indisponivel: $e');
    }
  }

  Future<void> _toggleServer(bool on) async {
    try {
      if (on) {
        await c.server.start(port: 8765);
      } else {
        await c.server.stop();
      }
    } on Object catch (e) {
      if (mounted) _msg(context, 'Servidor: $e');
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final server = c.server;
    return ListView(padding: const EdgeInsets.all(14), children: [
      Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton.icon(
            onPressed: _busy ? null : _importFolder,
            icon: const Icon(Icons.folder_open, size: 16),
            label: const Text('Pasta')),
        OutlinedButton.icon(
            onPressed: _busy ? null : _importZip,
            icon: const Icon(Icons.archive, size: 16),
            label: const Text('Zip')),
        OutlinedButton.icon(
            onPressed: _busy ? null : _importUrl,
            icon: const Icon(Icons.link, size: 16),
            label: const Text('URL')),
        OutlinedButton.icon(
            onPressed: _busy ? null : _openCatalog,
            icon: const Icon(Icons.cloud_download, size: 16),
            label: const Text('Catalogo')),
      ]),
      const SizedBox(height: 14),
      for (final pack in c.packs)
        Card(
          key: ValueKey('pack-${pack.id}'),
          child: ListTile(
            dense: true,
            title: Text('${pack.name}  ${pack.version}'),
            subtitle: Text(
              '${pack.transitions.length} transicoes • ${pack.sounds.length} sons'
              '${pack.license.isEmpty ? '' : '\nLicenca: ${pack.license}'}',
              style: const TextStyle(fontSize: 11),
            ),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _run(() async {
                await c.repository.remove(pack.id);
                return 'Pacote removido.';
              }),
            ),
          ),
        ),
      const Divider(height: 28),
      SwitchListTile(
        key: const Key('api-switch'),
        contentPadding: EdgeInsets.zero,
        title: const Text('API REST local'),
        subtitle: const Text('Instalar e listar pacotes por HTTP (so neste computador)',
            style: TextStyle(fontSize: 11)),
        value: server.running,
        onChanged: _toggleServer,
      ),
      if (server.running) ...[
        SelectableText('http://127.0.0.1:${server.port}',
            style: const TextStyle(fontFamily: 'Consolas', fontSize: 12)),
        const SizedBox(height: 4),
        Row(children: [
          Expanded(
            child: Text('Token: ${server.token.substring(0, 8)}…',
                style: const TextStyle(fontFamily: 'Consolas', fontSize: 12)),
          ),
          TextButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: server.token));
              _msg(context, 'Token copiado.');
            },
            icon: const Icon(Icons.copy, size: 14),
            label: const Text('Copiar'),
          ),
        ]),
        const Text(
          'Use o cabecalho  Authorization: Bearer <token>\n'
          'GET /packs • GET /packs/{id} • POST /packs (zip ou {"url"}) • DELETE /packs/{id}',
          style: TextStyle(fontSize: 11, color: Colors.white54),
        ),
      ],
    ]);
  }
}
