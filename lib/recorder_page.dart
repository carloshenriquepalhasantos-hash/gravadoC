import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';

import 'ffmpeg_service.dart';

class RecorderPage extends StatefulWidget {
  const RecorderPage({super.key, this.onOpenEditor});

  /// Chamado com o caminho da gravacao quando o usuario pede para edita-la.
  final ValueChanged<String>? onOpenEditor;

  @override
  State<RecorderPage> createState() => _RecorderPageState();
}

class _RecorderPageState extends State<RecorderPage>
    with TickerProviderStateMixin {
  static const _globalHotkeyChannel = MethodChannel('gravadoc/global_hotkey');
  final RTCVideoRenderer _screenRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _cameraRenderer = RTCVideoRenderer();
  MediaStream? _screenStream;
  MediaStream? _cameraStream;
  FfmpegRecorder? _recorder;
  String? _ffmpegPath;
  CaptureDevices _devices = const CaptureDevices();
  bool _devicesLoaded = false;
  DesktopCapturerSource? _selectedSource;
  Timer? _timer;
  Duration _elapsed = Duration.zero;
  DateTime? _startedAt;
  String? _recordingPath;
  bool _recording = false;
  bool _microphone = true;
  bool _systemAudio = true;
  bool _cameraOn = false;
  bool _renderersReady = false;
  double _inPoint = 0;
  double _outPoint = 0;
  double _cameraX = 1;
  double _cameraY = 1;
  double _cameraWidth = 180;
  double _cameraHeight = 120;
  static const double _cameraMinWidth = 180;
  static const double _cameraMinHeight = 120;
  double _cameraWidthRatio = 180 / 720;
  double _cameraHeightRatio = 120 / 520;
  bool _cameraLocked = false;
  int _startDelaySeconds = 0;
  Timer? _countdownTimer;
  int _countdown = 0;
  final FocusNode _hotkeyFocus = FocusNode();
  LogicalKeyboardKey _recordHotkey = LogicalKeyboardKey.f9;
  LogicalKeyboardKey _stopHotkey = LogicalKeyboardKey.f9;
  Uint8List? _cameraPreviewBytes;
  Timer? _previewTimer;
  DateTime? _previewStamp;

  static String get _previewFile =>
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'gravadoc_camera_preview.jpg';

  @override
  void initState() {
    super.initState();
    FfmpegRecorder.killStale();
    _loadHotkeyPreferences();
    _initializeRenderers();
    _loadDevices();
  }

  Future<void> _initializeRenderers() async {
    await _screenRenderer.initialize();
    await _cameraRenderer.initialize();
    if (mounted) setState(() => _renderersReady = true);
  }

  Future<void> _loadHotkeyPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final delay = prefs.getInt('recorder_start_delay') ?? 0;
    final recordKey =
        prefs.getInt('recorder_start_key') ?? LogicalKeyboardKey.f9.keyId;
    final stopKey =
        prefs.getInt('recorder_stop_key') ?? LogicalKeyboardKey.f9.keyId;
    if (!mounted) return;
    setState(() {
      _startDelaySeconds = delay.clamp(0, 300);
      _recordHotkey = LogicalKeyboardKey(recordKey);
      _stopHotkey = LogicalKeyboardKey(stopKey);
    });
    await _registerGlobalHotkey();
    _globalHotkeyChannel.setMethodCallHandler((call) async {
      if (call.method == 'hotkeyPressed' && mounted) {
        if (_recording) {
          await _stopRecording();
        } else {
          await _startRecording();
        }
      }
    });
  }

  int _virtualKeyFor(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.f9) return 0x78;
    if (key == LogicalKeyboardKey.f8) return 0x77;
    if (key == LogicalKeyboardKey.f10) return 0x79;
    if (key == LogicalKeyboardKey.f11) return 0x7A;
    if (key == LogicalKeyboardKey.f12) return 0x7B;
    if (key == LogicalKeyboardKey.space) return 0x20;
    if (key == LogicalKeyboardKey.pause) return 0x13;
    if (key == LogicalKeyboardKey.escape) return 0x1B;
    return key.keyId & 0xFFFF;
  }

  Future<void> _registerGlobalHotkey() async {
    try {
      await _globalHotkeyChannel.invokeMethod('setHotkey', {
        'vk': _virtualKeyFor(_recordHotkey),
      });
    } on MissingPluginException {}
  }

  Future<void> _saveHotkeyPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('recorder_start_delay', _startDelaySeconds);
    await prefs.setInt('recorder_start_key', _recordHotkey.keyId);
    await prefs.setInt('recorder_stop_key', _stopHotkey.keyId);
  }

  Future<void> _captureHotkey() async {
    final captureFocus = FocusNode();
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) => RawKeyboardListener(
        focusNode: captureFocus,
        autofocus: true,
        onKey: (event) {
          if (event is! RawKeyDownEvent) return;
          final key = event.logicalKey;
          if (key == LogicalKeyboardKey.escape) {
            Navigator.of(dialogContext).pop();
            return;
          }
          setState(() {
            _recordHotkey = key;
            _stopHotkey = key;
          });
          _saveHotkeyPreferences();
          _registerGlobalHotkey();
          Navigator.of(dialogContext).pop();
        },
        child: const AlertDialog(
          title: Text('Definir atalho'),
          content: Text(
            'Pressione a tecla que iniciara e parara a gravacao.\n'
            'Pressione Esc para cancelar.',
          ),
        ),
      ),
    );
    captureFocus.dispose();
  }

  Future<void> _loadDevices() async {
    final ffmpeg = await locateFfmpeg();
    final devices = ffmpeg == null
        ? const CaptureDevices()
        : await listCaptureDevices(ffmpeg);
    if (!mounted) return;
    setState(() {
      _ffmpegPath = ffmpeg;
      _devices = devices;
      _devicesLoaded = true;
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _previewTimer?.cancel();
    _countdownTimer?.cancel();
    _globalHotkeyChannel.invokeMethod('clearHotkey');
    _hotkeyFocus.dispose();
    _recorder?.stop();
    _screenRenderer.dispose();
    _cameraRenderer.dispose();
    _screenStream?.dispose();
    _cameraStream?.dispose();
    super.dispose();
  }

  Future<void> _selectSource() async {
    if (!_renderersReady) return;
    if (!WebRTC.platformIsDesktop) {
      _showMessage('A captura nativa esta disponivel no Windows.');
      return;
    }
    final sources = await desktopCapturer.getSources(
      types: [SourceType.Screen, SourceType.Window],
    );
    if (!mounted) return;
    final source = await showDialog<DesktopCapturerSource>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Escolha o que gravar'),
        content: SizedBox(
          width: 760,
          height: 460,
          child: GridView.builder(
            itemCount: sources.length,
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 240,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 1.35,
            ),
            itemBuilder: (context, index) {
              final item = sources[index];
              return InkWell(
                onTap: () => Navigator.pop(context, item),
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF171C27),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFF30384A)),
                  ),
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    children: [
                      Expanded(
                        child: item.thumbnail == null
                            ? const Icon(Icons.desktop_windows, size: 44)
                            : Image.memory(
                                item.thumbnail!,
                                fit: BoxFit.contain,
                              ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        item.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
    if (source == null) return;

    await _screenStream?.dispose();
    final stream = await navigator.mediaDevices.getDisplayMedia({
      'video': {
        'deviceId': {'exact': source.id},
        'mandatory': {'frameRate': 30.0},
      },
      'audio': false,
    });
    _screenStream = stream;
    _screenRenderer.srcObject = stream;
    setState(() => _selectedSource = source);
  }

  Future<bool> _acquireCamera() async {
    try {
      MediaStream? stream;
      try {
        final devices = await navigator.mediaDevices.enumerateDevices();
        final cameras = devices.where((d) => d.kind == 'videoinput').toList();
        if (cameras.isNotEmpty) {
          stream = await navigator.mediaDevices.getUserMedia({
            'video': {
              'deviceId': {'exact': cameras.first.deviceId},
              'mandatory': {'minWidth': 640, 'minHeight': 360},
              'facingMode': 'user',
            },
            'audio': false,
          });
        }
      } on Object {
        stream = null;
      }
      stream ??= await navigator.mediaDevices.getUserMedia({
        'video': {
          'facingMode': 'user',
          'mandatory': {'minWidth': 640, 'minHeight': 360},
        },
        'audio': false,
      });
      for (final track in stream.getVideoTracks()) {
        track.enabled = true;
      }
      await _cameraRenderer.initialize();
      _cameraStream = stream;
      _cameraRenderer.srcObject = stream;
      return true;
    } catch (error) {
      if (mounted) {
        setState(() => _cameraOn = false);
        _showMessage('Nao foi possivel acessar a camera: $error');
      }
      return false;
    }
  }

  Future<void> _releaseCamera() async {
    _cameraRenderer.srcObject = null;
    await _cameraStream?.dispose();
    _cameraStream = null;
    _cameraRenderer.srcObject = null;
  }

  Future<void> _toggleCamera() async {
    if (_cameraOn) {
      await _releaseCamera();
      setState(() => _cameraOn = false);
      return;
    }
    setState(() => _cameraOn = true);
    await _acquireCamera();
  }

  Future<void> _startRecording() async {
    if (_countdown > 0) {
      _countdownTimer?.cancel();
      setState(() => _countdown = 0);
      return;
    }
    if (_startDelaySeconds > 0 && !_recording) {
      setState(() => _countdown = _startDelaySeconds);
      _countdownTimer?.cancel();
      _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (_countdown <= 1) {
          timer.cancel();
          setState(() => _countdown = 0);
          _startRecordingNow();
        } else {
          setState(() => _countdown--);
        }
      });
      return;
    }
    await _startRecordingNow();
  }

  Future<void> _startRecordingNow() async {
    final ffmpeg = _ffmpegPath;
    if (ffmpeg == null) {
      _showMessage(
        'FFmpeg nao encontrado. Instale em C:\\ffmpeg\\bin ou adicione ao PATH.',
      );
      return;
    }
    if (_selectedSource == null) {
      await _selectSource();
    }
    final source = _selectedSource;
    if (source == null) return;

    try {
      final directory = await getApplicationDocumentsDirectory();
      final outputDir = Directory('${directory.path}\\gravadoC');
      if (!await outputDir.exists()) await outputDir.create(recursive: true);
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final outputPath = '${outputDir.path}\\gravacao-$timestamp.mp4';

      final camera = _cameraOn ? _devices.camera : null;
      final previewPath = camera == null ? null : _previewFile;
      if (camera != null) {
        // A camera so abre em um processo: libera o WebRTC e deixa o FFmpeg
        // gravar; a previa passa a vir dele.
        try {
          await File(_previewFile).delete();
        } on FileSystemException {
          // Sem previa anterior.
        }
        _cameraRenderer.srcObject = null;
        await _cameraStream?.dispose();
        _cameraStream = null;
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }

      RecordingRequest request({required bool withCamera}) => RecordingRequest(
        outputPath: outputPath,
        windowTitle: source.type == SourceType.Window ? source.name : null,
        camera: withCamera ? camera : null,
        previewPath: withCamera ? previewPath : null,
        microphone: _microphone ? _devices.microphone : null,
        systemAudio: _systemAudio ? _devices.systemAudio : null,
        separateTracks: true,
        cameraX: _cameraX,
        cameraY: _cameraY,
        cameraWidth: _cameraWidth.round(),
        cameraHeight: _cameraHeight.round(),
        cameraWidthRatio: _cameraWidthRatio,
        cameraHeightRatio: _cameraHeightRatio,
      );

      final recorder = FfmpegRecorder(ffmpeg);
      var cameraRecorded = camera != null;
      try {
        await recorder.start(request(withCamera: true));
      } on StateError catch (error) {
        if (camera == null) rethrow;
        // Dispositivo ainda ocupado: grava so a tela e devolve a camera ao preview.
        cameraRecorded = false;
        _showMessage('Camera indisponivel para gravar: ${error.message}');
        await recorder.start(request(withCamera: false));
        if (_cameraOn) await _acquireCamera();
      }
      if (cameraRecorded) _startPreviewPolling();

      _recorder = recorder;
      _recordingPath = outputPath;
      _startedAt = DateTime.now();
      _elapsed = Duration.zero;
      _timer = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (!mounted) return;
        setState(() => _elapsed = DateTime.now().difference(_startedAt!));
      });
      setState(() {
        _recording = true;
        _inPoint = 0;
        _outPoint = 0;
      });
    } catch (error) {
      _showMessage('Nao foi possivel iniciar: $error');
    }
  }

  void _startPreviewPolling() {
    _previewTimer?.cancel();
    _previewStamp = null;
    _previewTimer = Timer.periodic(const Duration(milliseconds: 120), (
      _,
    ) async {
      try {
        final file = File(_previewFile);
        final stamp = file.lastModifiedSync();
        if (stamp == _previewStamp) return;
        final bytes = await file.readAsBytes();
        if (!mounted || bytes.isEmpty) return;
        _previewStamp = stamp;
        setState(() => _cameraPreviewBytes = bytes);
      } on FileSystemException {
        // Quadro ainda sendo escrito: tenta de novo no proximo ciclo.
      }
    });
  }

  Future<void> _stopRecording() async {
    final recorder = _recorder;
    if (recorder == null) return;
    _timer?.cancel();
    _previewTimer?.cancel();
    setState(() => _recording = false);
    await recorder.stop();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    setState(() {
      _recorder = null;
      _cameraPreviewBytes = null;
      _outPoint = _elapsed.inMilliseconds / 1000;
    });
    // O FFmpeg soltou a camera: o preview volta para o WebRTC.
    if (_cameraOn && _cameraStream == null) await _acquireCamera();

    final path = _recordingPath;
    if (path == null) {
      _showMessage('A gravacao nao possui caminho de arquivo.');
      return;
    }
    final file = File(path);
    if (!await file.exists() || await file.length() == 0) {
      _showMessage('A gravacao nao gerou arquivo: ${recorder.log.trim()}');
      return;
    }
  }

  Future<void> _exportVideo() async {
    if (_recordingPath == null) {
      _showMessage('Grave um video antes de exportar.');
      return;
    }
    final source = File(_recordingPath!);
    if (!await source.exists()) {
      _showMessage('O arquivo gravado ainda nao esta disponivel.');
      return;
    }
    // O seletor grava os bytes recebidos no destino; o conteudo real e
    // escrito logo depois, sem carregar o video inteiro na memoria.
    final destination = await FilePicker.saveFile(
      dialogTitle: 'Exportar video',
      fileName: 'gravadoC-${DateTime.now().millisecondsSinceEpoch}.mp4',
      bytes: Uint8List(0),
      mimeType: 'video/mp4',
    );
    if (destination == null) return;

    final target = destination.toFilePath();
    try {
      final result = await exportRecording(
        source: source.path,
        target: target,
        startSeconds: _inPoint,
        endSeconds: _outPoint,
        totalSeconds: _elapsed.inMilliseconds / 1000,
        ffmpegPath: _ffmpegPath,
      );
      _showMessage(
        result == ExportResult.cut
            ? 'Video cortado e exportado em $target'
            : 'Video exportado em $target',
      );
    } catch (error) {
      _showMessage('Nao foi possivel exportar: $error');
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  void _onHotkey(RawKeyEvent event) {
    if (event is! RawKeyDownEvent) return;
    if (event.logicalKey == _recordHotkey || event.logicalKey == _stopHotkey) {
      if (_recording) {
        _stopRecording();
      } else {
        _startRecording();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return RawKeyboardListener(
      focusNode: _hotkeyFocus,
      autofocus: true,
      onKey: _onHotkey,
      child: Scaffold(
        body: Row(
          children: [
            Material(
              color: const Color(0xFF10141D),
              child: Container(
                width: 220,
                decoration: const BoxDecoration(
                  border: Border(right: BorderSide(color: Color(0xFF252B39))),
                ),
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'gravadoC',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      'FONTES',
                      style: TextStyle(fontSize: 11, color: Colors.white54),
                    ),
                    const SizedBox(height: 10),
                    _SourceButton(
                      icon: Icons.desktop_windows,
                      label: _selectedSource?.name ?? 'Tela',
                      selected: _selectedSource != null,
                      onTap: _selectSource,
                    ),
                    _SourceButton(
                      icon: Icons.videocam,
                      label: 'Camera',
                      selected: _cameraOn,
                      onTap: _toggleCamera,
                    ),
                    const SizedBox(height: 18),
                    const Text(
                      'AUDIO',
                      style: TextStyle(fontSize: 11, color: Colors.white54),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        'Microfone',
                        style: TextStyle(fontSize: 13),
                      ),
                      subtitle: _devicesLoaded && _devices.microphone == null
                          ? const Text(
                              'indisponivel',
                              style: TextStyle(fontSize: 10),
                            )
                          : null,
                      value:
                          _microphone &&
                          (!_devicesLoaded || _devices.microphone != null),
                      onChanged:
                          _recording ||
                              (_devicesLoaded && _devices.microphone == null)
                          ? null
                          : (value) => setState(() => _microphone = value),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        'Sistema',
                        style: TextStyle(fontSize: 13),
                      ),
                      subtitle: _devicesLoaded && _devices.systemAudio == null
                          ? const Text(
                              'sem dispositivo loopback',
                              style: TextStyle(fontSize: 10),
                            )
                          : null,
                      value:
                          _systemAudio &&
                          (!_devicesLoaded || _devices.systemAudio != null),
                      onChanged:
                          _recording ||
                              (_devicesLoaded && _devices.systemAudio == null)
                          ? null
                          : (value) => setState(() => _systemAudio = value),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'ATRASO',
                      style: TextStyle(fontSize: 11, color: Colors.white54),
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: Slider(
                            value: _startDelaySeconds.toDouble(),
                            min: 0,
                            max: 300,
                            divisions: 60,
                            label: _startDelaySeconds == 0
                                ? 'Agora'
                                : '${_startDelaySeconds}s',
                            onChanged: _recording
                                ? null
                                : (value) => setState(
                                    () => _startDelaySeconds = value.round(),
                                  ),
                            onChangeEnd: (_) => _saveHotkeyPreferences(),
                          ),
                        ),
                        SizedBox(
                          width: 44,
                          child: Text(
                            '${_startDelaySeconds}s',
                            textAlign: TextAlign.right,
                            style: const TextStyle(fontSize: 11),
                          ),
                        ),
                      ],
                    ),
                    const Text(
                      'ATALHO INICIAR/PARAR',
                      style: TextStyle(fontSize: 11, color: Colors.white54),
                    ),
                    OutlinedButton.icon(
                      key: const Key('configure-record-hotkey'),
                      onPressed: _recording ? null : () => _captureHotkey(),
                      icon: const Icon(Icons.keyboard, size: 16),
                      label: Text(_recordHotkey.keyLabel),
                    ),
                    const Spacer(),
                    _SourceButton(
                      icon: Icons.folder_open,
                      label: 'Abrir pasta',
                      onTap: () async {
                        final directory =
                            await getApplicationDocumentsDirectory();
                        await Process.run('explorer.exe', [
                          '${directory.path}\\gravadoC',
                        ]);
                      },
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: Column(
                children: [
                  Container(
                    height: 64,
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    decoration: const BoxDecoration(
                      border: Border(
                        bottom: BorderSide(color: Color(0xFF252B39)),
                      ),
                    ),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Nova gravacao',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const Spacer(),
                        Text(
                          _formatDuration(_elapsed),
                          style: const TextStyle(
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                        const SizedBox(width: 16),
                        ElevatedButton.icon(
                          onPressed: _recording
                              ? _stopRecording
                              : _startRecording,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _recording
                                ? const Color(0xFFFF4967)
                                : const Color(0xFFB6FF4A),
                            foregroundColor: const Color(0xFF10141D),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 18,
                              vertical: 14,
                            ),
                          ),
                          icon: Icon(
                            _recording ? Icons.stop : Icons.fiber_manual_record,
                          ),
                          label: Text(_recording ? 'Parar' : 'Gravar'),
                        ),
                        const SizedBox(width: 10),
                        OutlinedButton.icon(
                          onPressed: _exportVideo,
                          icon: const Icon(Icons.download),
                          label: const Text('Exportar'),
                        ),
                        const SizedBox(width: 10),
                        FilledButton.tonalIcon(
                          key: const Key('open-editor'),
                          onPressed: _recording || _recordingPath == null
                              ? null
                              : () =>
                                    widget.onOpenEditor?.call(_recordingPath!),
                          icon: const Icon(Icons.movie_edit),
                          label: const Text('Editar'),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Container(
                      margin: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        color: const Color(0xFF05070A),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: const Color(0xFF252B39)),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: LayoutBuilder(
                        builder: (context, previewBox) => MouseRegion(
                          opaque: false,
                          cursor: MouseCursor.defer,
                          child: Listener(
                            behavior: HitTestBehavior.translucent,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                if (_screenStream != null)
                                  RTCVideoView(
                                    _screenRenderer,
                                    objectFit: RTCVideoViewObjectFit
                                        .RTCVideoViewObjectFitContain,
                                  )
                                else
                                  const Center(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.desktop_windows,
                                          size: 56,
                                          color: Colors.white38,
                                        ),
                                        SizedBox(height: 12),
                                        Text(
                                          'Selecione uma tela ou janela',
                                          style: TextStyle(
                                            color: Colors.white54,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                if (_countdown > 0)
                                  Positioned.fill(
                                    child: Center(
                                      child: Container(
                                        width: 92,
                                        height: 92,
                                        alignment: Alignment.center,
                                        decoration: const BoxDecoration(
                                          color: Color(0xCC10141D),
                                          shape: BoxShape.circle,
                                        ),
                                        child: Text(
                                          '$_countdown',
                                          style: const TextStyle(
                                            fontSize: 48,
                                            fontWeight: FontWeight.w800,
                                            color: Color(0xFFB6FF4A),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                if (_cameraOn)
                                  Positioned.fill(
                                    child: LayoutBuilder(
                                      builder: (context, box) {
                                        final maxW = box.maxWidth;
                                        final maxH = box.maxHeight;
                                        final width = _cameraWidth
                                            .clamp(
                                              _cameraMinWidth,
                                              maxW < 360 ? maxW : maxW * 0.35,
                                            )
                                            .toDouble();
                                        final height = _cameraHeight
                                            .clamp(
                                              _cameraMinHeight,
                                              maxH < 240 ? maxH : maxH * 0.35,
                                            )
                                            .toDouble();
                                        final left = (_cameraX * maxW)
                                            .clamp(0, maxW - width)
                                            .toDouble();
                                        final top = (_cameraY * maxH)
                                            .clamp(0, maxH - height)
                                            .toDouble();
                                        return Stack(
                                          children: [
                                            Positioned(
                                              key: const Key('camera-box'),
                                              left: left,
                                              top: top,
                                              width: width,
                                              height: height,
                                              child: MouseRegion(
                                                cursor: _cameraLocked
                                                    ? MouseCursor.defer
                                                    : SystemMouseCursors.move,
                                                child: GestureDetector(
                                                  onPanUpdate: _cameraLocked
                                                      ? null
                                                      : (d) {
                                                          setState(() {
                                                            _cameraX =
                                                                ((left + d.delta.dx) /
                                                                        maxW)
                                                                    .clamp(
                                                                      0,
                                                                      1 -
                                                                          width /
                                                                              maxW,
                                                                    )
                                                                    .toDouble();
                                                            _cameraY =
                                                                ((top + d.delta.dy) /
                                                                        maxH)
                                                                    .clamp(
                                                                      0,
                                                                      1 -
                                                                          height /
                                                                              maxH,
                                                                    )
                                                                    .toDouble();
                                                          });
                                                        },
                                                  child: Container(
                                                    decoration: BoxDecoration(
                                                      color: const Color(
                                                        0xFF10141D,
                                                      ),
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            12,
                                                          ),
                                                      border: Border.all(
                                                        color: _cameraLocked
                                                            ? Colors.white54
                                                            : const Color(
                                                                0xFFB6FF4A,
                                                              ),
                                                        width: 2,
                                                      ),
                                                    ),
                                                    clipBehavior:
                                                        Clip.antiAlias,
                                                    child: Stack(
                                                      children: [
                                                        Positioned.fill(
                                                          child:
                                                              _recording &&
                                                                  _cameraPreviewBytes !=
                                                                      null
                                                              ? Image.memory(
                                                                  _cameraPreviewBytes!,
                                                                  fit: BoxFit
                                                                      .cover,
                                                                  gaplessPlayback:
                                                                      true,
                                                                )
                                                              : RTCVideoView(
                                                                  _cameraRenderer,
                                                                  objectFit:
                                                                      RTCVideoViewObjectFit
                                                                          .RTCVideoViewObjectFitCover,
                                                                ),
                                                        ),
                                                        Positioned(
                                                          left: 4,
                                                          top: 4,
                                                          child: Visibility(
                                                            visible: true,
                                                            maintainSize: false,
                                                            maintainAnimation:
                                                                false,
                                                            maintainState:
                                                                false,
                                                            child: IconButton(
                                                              key: const Key(
                                                                'camera-lock',
                                                              ),
                                                              onPressed: () => setState(
                                                                () => _cameraLocked =
                                                                    !_cameraLocked,
                                                              ),
                                                              icon: Icon(
                                                                _cameraLocked
                                                                    ? Icons.lock
                                                                    : Icons
                                                                          .lock_open,
                                                                size: 16,
                                                              ),
                                                            ),
                                                          ),
                                                        ),
                                                        Positioned(
                                                          right: 4,
                                                          top: 4,
                                                          child: Visibility(
                                                            visible: true,
                                                            maintainSize: false,
                                                            maintainAnimation:
                                                                false,
                                                            maintainState:
                                                                false,
                                                            child: IconButton(
                                                              key: const Key(
                                                                'camera-remove',
                                                              ),
                                                              onPressed:
                                                                  _recording
                                                                  ? null
                                                                  : () async {
                                                                      await _releaseCamera();
                                                                      setState(
                                                                        () => _cameraOn =
                                                                            false,
                                                                      );
                                                                    },
                                                              icon: const Icon(
                                                                Icons.close,
                                                                size: 16,
                                                              ),
                                                            ),
                                                          ),
                                                        ),
                                                        Positioned(
                                                          right: -14,
                                                          bottom: -14,
                                                          width: 28,
                                                          height: 28,
                                                          child: Visibility(
                                                            visible: true,
                                                            maintainSize: false,
                                                            maintainAnimation:
                                                                false,
                                                            maintainState:
                                                                false,
                                                            child: MouseRegion(
                                                              cursor:
                                                                  _cameraLocked
                                                                  ? MouseCursor
                                                                        .defer
                                                                  : SystemMouseCursors
                                                                        .resizeDownRight,
                                                              child: GestureDetector(
                                                                key: const Key(
                                                                  'camera-resize',
                                                                ),
                                                                onPanUpdate:
                                                                    _cameraLocked
                                                                    ? null
                                                                    : (d) {
                                                                        setState(() {
                                                                          _cameraWidth = (_cameraWidth + d.delta.dx)
                                                                              .clamp(
                                                                                180,
                                                                                maxW - left,
                                                                              )
                                                                              .toDouble();
                                                                          _cameraHeight = (_cameraHeight + d.delta.dy)
                                                                              .clamp(
                                                                                120,
                                                                                maxH - top,
                                                                              )
                                                                              .toDouble();
                                                                          _cameraWidthRatio =
                                                                              _cameraWidth /
                                                                              maxW;
                                                                          _cameraHeightRatio =
                                                                              _cameraHeight /
                                                                              maxH;
                                                                        });
                                                                      },
                                                                child: Container(
                                                                  decoration: BoxDecoration(
                                                                    color: const Color(
                                                                      0xFFB6FF4A,
                                                                    ),
                                                                    shape: BoxShape
                                                                        .circle,
                                                                    border: Border.all(
                                                                      color: Colors
                                                                          .black54,
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
                                                ),
                                              ),
                                            ),
                                          ],
                                        );
                                      },
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SourceButton extends StatelessWidget {
  const _SourceButton({
    required this.icon,
    required this.label,
    this.selected = false,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: selected
            ? const Color(0xFFB6FF4A).withValues(alpha: 0.12)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(9),
          child: Container(
            height: 42,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(9),
              border: Border.all(
                color: selected
                    ? const Color(0xFFB6FF4A).withValues(alpha: 0.5)
                    : const Color(0xFF252B39),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 18,
                  color: selected ? const Color(0xFFB6FF4A) : Colors.white70,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
