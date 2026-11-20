import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../cursor/kinetic_cursor_options.dart';

/// Transicoes do filtro xfade do FFmpeg. Qualquer nome vindo de pacote de
/// terceiros so e aceito se estiver aqui, pois vai direto para o filtergraph.
const kXfadeTransitions = <String>{
  'circleclose',
  'circlecrop',
  'circleopen',
  'coverdown',
  'coverleft',
  'coverright',
  'coverup',
  'diagbl',
  'diagbr',
  'diagtl',
  'diagtr',
  'dissolve',
  'distance',
  'fade',
  'fadeblack',
  'fadefast',
  'fadegrays',
  'fadeslow',
  'fadewhite',
  'hblur',
  'hlslice',
  'hlwind',
  'horzclose',
  'horzopen',
  'hrslice',
  'hrwind',
  'pixelize',
  'radial',
  'rectcrop',
  'revealdown',
  'revealleft',
  'revealright',
  'revealup',
  'slidedown',
  'slideleft',
  'slideright',
  'slideup',
  'smoothdown',
  'smoothleft',
  'smoothright',
  'smoothup',
  'squeezeh',
  'squeezev',
  'vdslice',
  'vdwind',
  'vertclose',
  'vertopen',
  'vuslice',
  'vuwind',
  'wipebl',
  'wipebr',
  'wipedown',
  'wipeleft',
  'wiperight',
  'wipetl',
  'wipetr',
  'wipeup',
  'zoomin',
};

class TransitionSpec {
  const TransitionSpec({
    required this.xfade,
    required this.name,
    this.duration = 0.5,
    this.sfxPath,
    this.sfxGain = 1,
  }) : assert(duration > 0);

  final String xfade;
  final String name;
  final double duration;
  final String? sfxPath;
  final double sfxGain;

  TransitionSpec copyWith({
    double? duration,
    String? sfxPath,
    bool clearSfx = false,
    double? sfxGain,
  }) => TransitionSpec(
    xfade: xfade,
    name: name,
    duration: duration ?? this.duration,
    sfxPath: clearSfx ? null : (sfxPath ?? this.sfxPath),
    sfxGain: sfxGain ?? this.sfxGain,
  );
}

/// Trecho do video de origem, em segundos. [transition] e a transicao que
/// entra neste clipe vinda do clipe anterior.
class EditClip {
  EditClip({
    required this.start,
    required this.end,
    this.transition,
    this.kineticCursor,
  });

  final double start;
  final double end;
  final TransitionSpec? transition;
  KineticCursorOptions? kineticCursor;

  double get duration => end - start;

  EditClip copyWith({
    double? start,
    double? end,
    TransitionSpec? transition,
    bool clearTransition = false,
    KineticCursorOptions? kineticCursor,
    bool clearKineticCursor = false,
  }) => EditClip(
    start: start ?? this.start,
    end: end ?? this.end,
    transition: clearTransition ? null : (transition ?? this.transition),
    kineticCursor: clearKineticCursor
        ? null
        : (kineticCursor ?? this.kineticCursor),
  );
}

/// Imagem por cima do video. x/y sao o centro como fracao do quadro e scale
/// e a largura como fracao da largura do video. start/end em tempo de saida.
class OverlayImage {
  OverlayImage({
    required this.id,
    required this.path,
    required this.end,
    this.originalPath,
    this.x = 0.5,
    this.y = 0.5,
    this.scale = 0.25,
    this.opacity = 1,
    this.rotation = 0,
    this.start = 0,
  });

  final String id;
  String path;
  String? originalPath;
  double x;
  double y;
  double scale;
  double opacity;
  double rotation;
  double start;
  double end;
}

class SoundItem {
  SoundItem({
    required this.id,
    required this.name,
    required this.path,
    required this.at,
    this.gain = 1,
    this.duration = 5,
  });

  final String id;
  final String name;
  final String path;
  double at;
  double gain;
  double duration;
}

class MediaInfo {
  const MediaInfo({
    required this.width,
    required this.height,
    required this.fps,
    required this.duration,
    required this.hasAudio,
    this.audioStreamCount = 1,
  });

  final int width;
  final int height;
  final double fps;
  final double duration;
  final bool hasAudio;
  final int audioStreamCount;
}

class EditProject extends ChangeNotifier {
  EditProject({required this.source, required MediaInfo info})
    : width = info.width,
      height = info.height,
      fps = info.fps,
      hasAudio = info.hasAudio,
      audioStreamCount = info.audioStreamCount,
      sourceDuration = info.duration,
      clips = [EditClip(start: 0, end: info.duration)];

  static const minClip = 0.1;

  final String source;
  final int width;
  final int height;
  final double fps;
  final bool hasAudio;
  final int audioStreamCount;
  final double sourceDuration;
  List<EditClip> clips;
  final List<OverlayImage> overlays = [];
  final List<SoundItem> sounds = [];
  double originalAudioGain = 1;
  double voiceGain = 1;
  double systemAudioGain = 1;
  bool noiseReduction = false;
  bool voiceEnhancement = false;

  /// Duracao efetiva da transicao que entra no clipe [i]. Limitada para que
  /// transicoes vizinhas nunca se sobreponham dentro do mesmo clipe.
  double transitionInto(int i) {
    final t = clips[i].transition;
    if (i == 0 || t == null) return 0;
    return math.min(
      t.duration,
      0.45 * math.min(clips[i - 1].duration, clips[i].duration),
    );
  }

  double clipStart(int i) {
    var s = 0.0;
    for (var k = 1; k <= i; k++) {
      s += clips[k - 1].duration - transitionInto(k);
    }
    return s;
  }

  double get duration => clipStart(clips.length - 1) + clips.last.duration;

  /// Instante de saida em que o clipe [i] cede a vez ao proximo.
  double handoverTime(int i) =>
      i + 1 < clips.length ? clipStart(i + 1) : duration;

  ({int index, double source}) locate(double t) {
    final time = t.clamp(0, duration).toDouble();
    for (var i = clips.length - 1; i >= 0; i--) {
      final s = clipStart(i);
      if (time >= s || i == 0) {
        return (
          index: i,
          source: math.min(clips[i].start + (time - s), clips[i].end),
        );
      }
    }
    return (index: 0, source: clips.first.start);
  }

  bool splitAt(double t) {
    final at = locate(t);
    final clip = clips[at.index];
    if (at.source - clip.start < minClip || clip.end - at.source < minClip) {
      return false;
    }
    clips = [
      ...clips.sublist(0, at.index),
      clip.copyWith(end: at.source),
      EditClip(start: at.source, end: clip.end),
      ...clips.sublist(at.index + 1),
    ];
    notifyListeners();
    return true;
  }

  bool removeClip(int i) {
    if (clips.length <= 1) return false;
    clips = [...clips]..removeAt(i);
    notifyListeners();
    return true;
  }

  bool moveClip(int i, int delta) {
    final j = i + delta;
    if (j < 0 || j >= clips.length) return false;
    final list = [...clips];
    final tmp = list[i];
    list[i] = list[j];
    list[j] = tmp;
    clips = list;
    notifyListeners();
    return true;
  }

  void setTransition(int i, TransitionSpec? spec) {
    if (i <= 0 || i >= clips.length) return;
    clips = [...clips];
    clips[i] = spec == null
        ? clips[i].copyWith(clearTransition: true)
        : clips[i].copyWith(transition: spec);
    notifyListeners();
  }

  void touch() => notifyListeners();
}
