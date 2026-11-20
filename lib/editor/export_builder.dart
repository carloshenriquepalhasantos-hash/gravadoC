import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'project.dart';

String _n(double v) => v.toStringAsFixed(3);

String ffprobeFor(String ffmpegPath) =>
    '${File(ffmpegPath).parent.path}${Platform.pathSeparator}ffprobe.exe';

MediaInfo parseProbe(String jsonText) {
  final json = jsonDecode(jsonText) as Map<String, dynamic>;
  final streams = (json['streams'] as List? ?? const [])
      .cast<Map<String, dynamic>>();
  final video = streams.firstWhere(
    (s) => s['codec_type'] == 'video',
    orElse: () => throw const FormatException('Arquivo sem video.'),
  );
  final fpsText = (video['avg_frame_rate'] ?? video['r_frame_rate'] ?? '30/1')
      .toString()
      .split('/');
  var fps = fpsText.length == 2
      ? (double.tryParse(fpsText[0]) ?? 0) / (double.tryParse(fpsText[1]) ?? 1)
      : double.tryParse(fpsText[0]) ?? 0;
  if (!fps.isFinite || fps < 1 || fps > 240) fps = 30;
  final duration = double.tryParse(
          '${(json['format'] as Map?)?['duration'] ?? video['duration']}') ??
      0;
  return MediaInfo(
    width: video['width'] as int,
    height: video['height'] as int,
    fps: fps,
    duration: duration,
    hasAudio: streams.any((s) => s['codec_type'] == 'audio'),
    audioStreamCount: streams.where((s) => s['codec_type'] == 'audio').length,
  );
}

Future<MediaInfo> probeMedia(String ffmpegPath, String path) async {
  final result = await Process.run(
    ffprobeFor(ffmpegPath),
    [
      '-v', 'error', '-print_format', 'json', '-show_streams',
      '-show_format', path,
    ],
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (result.exitCode != 0) {
    throw ProcessException('ffprobe', [path], '${result.stderr}');
  }
  return parseProbe(result.stdout as String);
}

class ExportPlan {
  const ExportPlan(this.args, this.duration);

  final List<String> args;
  final double duration;
}

class _Extra {
  const _Extra(this.path, this.at, this.gain, this.duration);

  final String path;
  final double at;
  final double gain;
  final double duration;
}

/// Monta o comando FFmpeg da edicao inteira. Tempos de imagens e sons ficam
/// no tempo de saida (ja considerando a sobreposicao das transicoes).
ExportPlan buildExportPlan(
  EditProject p, {
  required String output,
  bool preview = false,
}) {
  final total = p.duration;
  final args = <String>['-y', '-hide_banner', '-loglevel', 'error'];
  args.addAll(['-i', p.source]);

  var next = 1;
  final overlayIndex = <int>[];
  for (final o in p.overlays) {
    args.addAll([
      '-loop', '1', '-framerate', _n(p.fps), '-t', _n(total), '-i', o.path,
    ]);
    overlayIndex.add(next++);
  }

  final extras = <_Extra>[
    for (final s in p.sounds) _Extra(s.path, s.at, s.gain, s.duration),
    for (var i = 1; i < p.clips.length; i++)
      if (p.clips[i].transition?.sfxPath != null)
        _Extra(p.clips[i].transition!.sfxPath!, p.clipStart(i),
            p.clips[i].transition!.sfxGain, 5),
  ];
  final extraIndex = <int>[];
  for (final e in extras) {
    args.addAll(['-i', e.path]);
    extraIndex.add(next++);
  }

  final f = <String>[];
  final fps = _n(p.fps);
  final hasSeparateTracks = p.hasAudio && p.audioStreamCount > 1;
  for (var k = 0; k < p.clips.length; k++) {
    final c = p.clips[k];
    f.add('[0:v]trim=start=${_n(c.start)}:end=${_n(c.end)},'
        'setpts=PTS-STARTPTS,fps=$fps,'
        'scale=trunc(iw/2)*2:trunc(ih/2)*2,setsar=1,format=yuv420p[v$k]');
    if (p.hasAudio) {
      if (hasSeparateTracks) {
        final voiceFilters = <String>[];
        if (p.noiseReduction) voiceFilters.add('afftdn=nf=-25');
        if (p.voiceEnhancement) {
          voiceFilters.addAll([
            'highpass=f=80',
            'lowpass=f=12000',
            'equalizer=f=3000:t=q:w=1:g=3',
            'acompressor=threshold=-18dB:ratio=3:attack=20:release=250',
          ]);
        }
        voiceFilters.add('volume=${_n(p.voiceGain)}');
        f.add('[0:a:0]atrim=start=${_n(c.start)}:end=${_n(c.end)},'
            'asetpts=PTS-STARTPTS,aformat=sample_rates=48000:channel_layouts=stereo,'
            '${voiceFilters.join(',')}[voice$k]');
        f.add('[0:a:1]atrim=start=${_n(c.start)}:end=${_n(c.end)},'
            'asetpts=PTS-STARTPTS,aformat=sample_rates=48000:channel_layouts=stereo,'
            'volume=${_n(p.systemAudioGain)}[system$k]');
        f.add('[voice$k][system$k]amix=inputs=2:duration=first:normalize=0[a$k]');
      } else {
        final filters = <String>[];
        if (p.noiseReduction) filters.add('afftdn=nf=-25');
        if (p.voiceEnhancement) {
          filters.addAll([
            'highpass=f=80',
            'lowpass=f=12000',
            'equalizer=f=3000:t=q:w=1:g=3',
            'acompressor=threshold=-18dB:ratio=3:attack=20:release=250',
          ]);
        }
        filters.add('volume=${_n(p.originalAudioGain)}');
        f.add('[0:a]atrim=start=${_n(c.start)}:end=${_n(c.end)},'
            'asetpts=PTS-STARTPTS,aformat=sample_rates=48000:channel_layouts=stereo,'
            '${filters.join(',')}[a$k]');
      }
    }
  }

  var v = 'v0';
  var a = 'a0';
  var curDur = p.clips.first.duration;
  for (var k = 1; k < p.clips.length; k++) {
    final d = p.transitionInto(k);
    if (d > 0) {
      final t = p.clips[k].transition!;
      f.add('[$v][v$k]xfade=transition=${t.xfade}:duration=${_n(d)}:'
          'offset=${_n(curDur - d)}[vx$k]');
      if (p.hasAudio) f.add('[$a][a$k]acrossfade=d=${_n(d)}[ax$k]');
    } else {
      f.add('[$v][v$k]concat=n=2:v=1:a=0[vx$k]');
      if (p.hasAudio) f.add('[$a][a$k]concat=n=2:v=0:a=1[ax$k]');
    }
    v = 'vx$k';
    a = 'ax$k';
    curDur += p.clips[k].duration - d;
  }

  for (var j = 0; j < p.overlays.length; j++) {
    final o = p.overlays[j];
    final width = math.max(2, (p.width * o.scale / 2).round() * 2);
    final chain = StringBuffer('[${overlayIndex[j]}:v]format=rgba,'
        'scale=$width:-2');
    if (o.rotation.abs() > 0.01) {
      final rad = (o.rotation * math.pi / 180).toStringAsFixed(5);
      chain.write(',rotate=a=$rad:ow=rotw($rad):oh=roth($rad):c=none');
    }
    if (o.opacity < 0.999) {
      chain.write(',colorchannelmixer=aa=${o.opacity.toStringAsFixed(3)}');
    }
    chain.write('[ov$j]');
    f.add(chain.toString());
    final end = math.min(o.end, total);
    f.add("[$v][ov$j]overlay=x='W*${o.x.toStringAsFixed(4)}-w/2':"
        "y='H*${o.y.toStringAsFixed(4)}-h/2':"
        "enable='between(t,${_n(o.start)},${_n(end)})':"
        'eof_action=pass:format=auto[vo$j]');
    v = 'vo$j';
  }
  f.add('[$v]${preview ? 'scale=-2:360,' : ''}format=yuv420p[vout]');

  String? audioOut;
  if (p.hasAudio || extras.isNotEmpty) {
    if (!p.hasAudio) {
      f.add('anullsrc=r=48000:cl=stereo,atrim=duration=${_n(total)}[abase]');
      a = 'abase';
    }
    if (extras.isEmpty) {
      audioOut = a;
    } else {
      final labels = <String>[];
      for (var i = 0; i < extras.length; i++) {
        final e = extras[i];
        f.add('[${extraIndex[i]}:a]'
            'aformat=sample_rates=48000:channel_layouts=stereo,'
            'volume=${e.gain.toStringAsFixed(3)},'
            'apad=whole_dur=${_n(e.duration)},atrim=duration=${_n(e.duration)},'
            'adelay=${(e.at * 1000).round()}:all=1[s$i]');
        labels.add('[s$i]');
      }
      f.add('[$a]${labels.join()}amix=inputs=${extras.length + 1}:'
          'duration=first:normalize=0:dropout_transition=0,'
          'alimiter=limit=0.97[amix]');
      audioOut = 'amix';
    }
  }

  args.addAll(['-filter_complex', f.join(';'), '-map', '[vout]']);
  if (audioOut != null) args.addAll(['-map', '[$audioOut]']);
  args.addAll([
    '-t', _n(total),
    '-c:v', 'libx264',
    '-preset', preview ? 'ultrafast' : 'veryfast',
    '-crf', preview ? '32' : '20',
    '-pix_fmt', 'yuv420p',
    if (audioOut != null) ...['-c:a', 'aac', '-b:a', '192k'] else '-an',
    '-movflags', '+faststart',
    output,
  ]);
  return ExportPlan(args, total);
}

class ExportJob {
  ExportJob._(this._process, this.done);

  final Process _process;
  final Future<void> done;
  bool _cancelled = false;

  void cancel() {
    _cancelled = true;
    _process.kill();
  }

  /// Inicia o FFmpeg; [onProgress] recebe 0..1.
  static Future<ExportJob> start(
    String ffmpegPath,
    ExportPlan plan, {
    void Function(double progress)? onProgress,
  }) async {
    final args = [
      ...plan.args.take(4),
      '-progress', 'pipe:1', '-nostats',
      ...plan.args.skip(4),
    ];
    final process = await Process.start(ffmpegPath, args);
    final errors = StringBuffer();
    process.stderr.transform(utf8.decoder).listen(errors.write);
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      if (line.startsWith('out_time_us=') && plan.duration > 0) {
        final us = int.tryParse(line.substring(12));
        if (us != null) {
          onProgress?.call((us / 1e6 / plan.duration).clamp(0, 1).toDouble());
        }
      }
    });
    late final ExportJob job;
    final done = process.exitCode.then((code) {
      if (job._cancelled) throw const _Cancelled();
      if (code != 0) throw StateError('FFmpeg falhou: $errors');
      onProgress?.call(1);
    });
    job = ExportJob._(process, done);
    return job;
  }
}

class _Cancelled implements Exception {
  const _Cancelled();

  @override
  String toString() => 'Exportacao cancelada.';
}
