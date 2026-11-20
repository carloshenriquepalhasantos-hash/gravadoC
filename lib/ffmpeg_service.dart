import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// FFmpeg embutido no pacote (pasta `ffmpeg` ao lado do executavel).
String get bundledFfmpegPath =>
    '${File(Platform.resolvedExecutable).parent.path}'
    '${Platform.pathSeparator}ffmpeg${Platform.pathSeparator}ffmpeg.exe';

const _knownFfmpegPaths = [r'C:\ffmpeg\bin\ffmpeg.exe'];

Future<String?> locateFfmpeg() async {
  if (await File(bundledFfmpegPath).exists()) return bundledFfmpegPath;
  for (final candidate in _knownFfmpegPaths) {
    if (await File(candidate).exists()) return candidate;
  }
  try {
    final result = await Process.run('where.exe', ['ffmpeg']);
    if (result.exitCode == 0) {
      final lines = (result.stdout as String)
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty);
      if (lines.isNotEmpty) return lines.first;
    }
  } on ProcessException {
    // where.exe indisponivel: trata como FFmpeg nao encontrado.
  }
  return null;
}

class CaptureDevices {
  const CaptureDevices({this.video = const [], this.audio = const []});

  final List<String> video;
  final List<String> audio;

  static final _loopback = RegExp(
    r'stereo mix|mixagem|loopback|virtual-audio-capturer|what u hear',
    caseSensitive: false,
  );

  String? get camera => video.isEmpty ? null : video.first;

  String? get microphone {
    for (final name in audio) {
      if (!_loopback.hasMatch(name)) return name;
    }
    return null;
  }

  // O FFmpeg nao captura audio do sistema sozinho: precisa de um dispositivo
  // de loopback (ex.: "Mixagem estereo") exposto pelo DirectShow.
  String? get systemAudio {
    for (final name in audio) {
      if (_loopback.hasMatch(name)) return name;
    }
    return null;
  }
}

CaptureDevices parseDshowDevices(String output) {
  final video = <String>[];
  final audio = <String>[];
  final line = RegExp(r'"(.+)"\s+\(([^)]*)\)\s*$');
  for (final raw in const LineSplitter().convert(output)) {
    final match = line.firstMatch(raw.trim());
    if (match == null) continue;
    final name = match.group(1)!;
    final kinds = match.group(2)!.split(',').map((k) => k.trim());
    if (kinds.contains('video')) video.add(name);
    if (kinds.contains('audio')) audio.add(name);
  }
  return CaptureDevices(video: video, audio: audio);
}

Future<CaptureDevices> listCaptureDevices(String ffmpegPath) async {
  final result = await Process.run(
    ffmpegPath,
    ['-hide_banner', '-list_devices', 'true', '-f', 'dshow', '-i', 'dummy'],
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  return parseDshowDevices('${result.stderr}\n${result.stdout}');
}

class RecordingRequest {
  const RecordingRequest({
    required this.outputPath,
    this.windowTitle,
    this.camera,
    this.microphone,
    this.systemAudio,
    this.separateTracks = false,
    this.cameraX = 0.75,
    this.cameraY = 0.75,
    this.cameraWidth = 320,
    this.cameraHeight = 180,
    this.cameraWidthRatio = 0.25,
    this.cameraHeightRatio = 0.14,
    this.previewPath,
    this.fps = 30,
  });

  final String outputPath;
  final String? windowTitle;
  final String? camera;
  final String? microphone;
  final String? systemAudio;
  final bool separateTracks;
  final double cameraX;
  final double cameraY;
  final int cameraWidth;
  final int cameraHeight;
  final double cameraWidthRatio;
  final double cameraHeightRatio;

  /// JPEG atualizado continuamente com a imagem da camera. O dispositivo so
  /// pode ser aberto por um processo, entao a previa durante a gravacao vem
  /// do proprio FFmpeg.
  final String? previewPath;
  final int fps;
}

List<String> buildRecordArgs(RecordingRequest r) {
  final args = <String>[
    '-y',
    '-hide_banner',
    '-loglevel',
    'warning',
    '-thread_queue_size',
    '512',
    '-f',
    'gdigrab',
    '-framerate',
    '${r.fps}',
    '-draw_mouse',
    '1',
    '-i',
    r.windowTitle == null ? 'desktop' : 'title=${r.windowTitle}',
  ];

  var next = 1;
  int? cameraIndex;
  if (r.camera != null) {
    args.addAll([
      '-thread_queue_size',
      '512',
      '-rtbufsize',
      '256M',
      '-f',
      'dshow',
      '-i',
      'video=${r.camera}',
    ]);
    cameraIndex = next++;
  }

  final audioIndexes = <int>[];
  for (final name in [r.microphone, r.systemAudio]) {
    if (name == null) continue;
    args.addAll([
      '-thread_queue_size',
      '512',
      '-f',
      'dshow',
      '-i',
      'audio=$name',
    ]);
    audioIndexes.add(next++);
  }

  // libx264 em yuv420p exige largura e altura pares (janelas podem ser impares).
  final filters = <String>['[0:v]scale=trunc(iw/2)*2:trunc(ih/2)*2[base]'];
  final withPreview = cameraIndex != null && r.previewPath != null;
  if (withPreview) {
    filters.add('[$cameraIndex:v]split=2[camsrc][campv]');
    filters.add('[campv]fps=8,scale=480:-2[pv]');
  }
  if (cameraIndex != null) {
    filters.add(
      '[${withPreview ? 'camsrc' : '$cameraIndex:v'}]scale='
      "'trunc(iw*${r.cameraWidthRatio.toStringAsFixed(4)}/2)*2':"
      "'trunc(ih*${r.cameraHeightRatio.toStringAsFixed(4)}/2)*2'[cam]",
    );
    filters.add(
      '[base][cam]'
      "overlay=x='min(W-w,max(0,W*${r.cameraX.toStringAsFixed(4)}))':"
      "y='min(H-h,max(0,H*${r.cameraY.toStringAsFixed(4)}))'"
      '[v]',
    );
  } else {
    filters.add('[base]null[v]');
  }

  late final List<String> audioMap;
  if (audioIndexes.length == 2 && r.separateTracks) {
    audioMap = ['-map', '${audioIndexes[0]}:a', '-map', '${audioIndexes[1]}:a'];
  } else if (audioIndexes.length == 2) {
    filters.add(
      '[${audioIndexes[0]}:a][${audioIndexes[1]}:a]'
      'amix=inputs=2:duration=longest[a]',
    );
    audioMap = ['-map', '[a]'];
  } else if (audioIndexes.length == 1) {
    audioMap = ['-map', '${audioIndexes[0]}:a'];
  } else {
    audioMap = ['-an'];
  }

  args.addAll([
    '-filter_complex',
    filters.join(';'),
    '-map',
    '[v]',
    ...audioMap,
    '-r',
    '${r.fps}',
    '-c:v',
    'libx264',
    '-preset',
    'veryfast',
    '-crf',
    '23',
    '-pix_fmt',
    'yuv420p',
    if (audioIndexes.isNotEmpty) ...['-c:a', 'aac', '-b:a', '160k'],
    '-movflags',
    '+faststart',
    r.outputPath,
    if (withPreview) ...[
      '-map',
      '[pv]',
      '-an',
      '-c:v',
      'mjpeg',
      '-q:v',
      '6',
      '-f',
      'image2',
      '-atomic_writing',
      '1',
      '-update',
      '1',
      r.previewPath!,
    ],
  ]);
  return args;
}

List<String> buildCutArgs({
  required String input,
  required String output,
  required double startSeconds,
  required double endSeconds,
}) {
  return [
    '-y',
    '-hide_banner',
    '-loglevel',
    'error',
    '-ss',
    startSeconds.toStringAsFixed(3),
    '-i',
    input,
    '-t',
    (endSeconds - startSeconds).toStringAsFixed(3),
    '-c:v',
    'libx264',
    '-preset',
    'veryfast',
    '-crf',
    '20',
    '-pix_fmt',
    'yuv420p',
    '-c:a',
    'aac',
    '-movflags',
    '+faststart',
    output,
  ];
}

class FfmpegRecorder {
  FfmpegRecorder(this.ffmpegPath);

  final String ffmpegPath;
  Process? _process;
  final List<String> _log = [];

  static File get _pidFile =>
      File('${Directory.systemTemp.path}${Platform.pathSeparator}'
          'gravadoc_recorder.pid');

  /// Encerra um gravador deixado por uma sessao anterior (app fechado ou
  /// derrubado durante a gravacao). Ele continuaria segurando a camera e o
  /// preview ficaria preto.
  static Future<void> killStale() async {
    try {
      final file = _pidFile;
      if (!await file.exists()) return;
      final pid = int.tryParse((await file.readAsString()).trim());
      await file.delete();
      if (pid == null) return;
      final listing = await Process.run(
        'tasklist',
        ['/FI', 'PID eq $pid', '/FO', 'CSV', '/NH'],
      );
      if (!'${listing.stdout}'.toLowerCase().contains('ffmpeg')) return;
      await Process.run('taskkill', ['/PID', '$pid', '/F', '/T']);
    } on Object {
      // Sem arquivo/permissao: nada para limpar.
    }
  }

  bool get isRecording => _process != null;
  String get log => _log.join();

  Future<void> start(RecordingRequest request) async {
    final process = await Process.start(ffmpegPath, buildRecordArgs(request));
    _process = process;
    _log.clear();
    try {
      await _pidFile.writeAsString('${process.pid}');
    } on Object {
      // O PID so serve para limpeza; gravar nao depende dele.
    }
    process.stderr.transform(utf8.decoder).listen((chunk) {
      _log.add(chunk);
      if (_log.length > 40) _log.removeAt(0);
    });
    process.stdout.drain<void>();
    unawaited(process.exitCode.then((_) => _clearPid(process.pid)));

    // Dispositivo ocupado, janela inexistente etc. fazem o FFmpeg sair logo.
    final early = await process.exitCode
        .then<int?>((code) => code)
        .timeout(const Duration(seconds: 2), onTimeout: () => null);
    if (early != null) {
      _process = null;
      throw StateError(
        log.trim().isEmpty ? 'FFmpeg encerrou ($early).' : log.trim(),
      );
    }
  }

  static Future<void> _clearPid(int pid) async {
    try {
      final file = _pidFile;
      if (await file.exists() &&
          int.tryParse((await file.readAsString()).trim()) == pid) {
        await file.delete();
      }
    } on Object {
      // Ja removido.
    }
  }

  // Enviar "q" faz o FFmpeg finalizar o MP4 corretamente.
  Future<int> stop() async {
    final process = _process;
    if (process == null) return -1;
    _process = null;
    try {
      process.stdin.write('q');
      await process.stdin.flush();
      await process.stdin.close();
    } on Object {
      // stdin ja fechado: o processo esta terminando.
    }
    final code = await process.exitCode.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        process.kill();
        return -1;
      },
    );
    return code;
  }
}

enum ExportResult { copied, cut }

Future<ExportResult> exportRecording({
  required String source,
  required String target,
  required double startSeconds,
  required double endSeconds,
  required double totalSeconds,
  String? ffmpegPath,
}) async {
  final trimsStart = startSeconds > 0.05;
  final trimsEnd =
      endSeconds > startSeconds && endSeconds < totalSeconds - 0.05;
  if ((trimsStart || trimsEnd) && ffmpegPath != null) {
    final result = await Process.run(
      ffmpegPath,
      buildCutArgs(
        input: source,
        output: target,
        startSeconds: startSeconds,
        endSeconds: endSeconds > startSeconds ? endSeconds : totalSeconds,
      ),
      stderrEncoding: utf8,
    );
    if (result.exitCode != 0) {
      throw StateError('Falha ao cortar o video: ${result.stderr}');
    }
    return ExportResult.cut;
  }
  await File(source).copy(target);
  return ExportResult.copied;
}
