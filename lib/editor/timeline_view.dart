import 'package:flutter/material.dart';

import 'project.dart';

const _accent = Color(0xFFB6FF4A);

String formatTime(double seconds) {
  final s = seconds < 0 ? 0.0 : seconds;
  final m = (s ~/ 60).toString().padLeft(2, '0');
  final r = (s % 60).toStringAsFixed(1).padLeft(4, '0');
  return '$m:$r';
}

class TimelineView extends StatelessWidget {
  const TimelineView({
    super.key,
    required this.project,
    required this.playhead,
    required this.selectedClip,
    required this.selectedOverlayId,
    required this.onSeek,
    required this.onSelectClip,
    required this.onSelectOverlay,
    required this.onTransitionTap,
    this.onMoveOverlay,
    this.onResizeOverlay,
    this.onMoveSound,
    this.onResizeSound,
    this.onSplitAt,
  });

  final EditProject project;
  final double playhead;
  final int selectedClip;
  final String? selectedOverlayId;
  final ValueChanged<double> onSeek;
  final ValueChanged<int> onSelectClip;
  final ValueChanged<String> onSelectOverlay;
  final ValueChanged<int> onTransitionTap;
  final void Function(String id, double start, double end)? onMoveOverlay;
  final void Function(String id, double end)? onResizeOverlay;
  final void Function(String id, double at)? onMoveSound;
  final void Function(String id, double duration)? onResizeSound;
  final ValueChanged<double>? onSplitAt;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        const pad = 12.0;
        final total = project.duration <= 0 ? 1.0 : project.duration;
        final pps = (box.maxWidth - pad * 2) / total;
        double seekFor(double dx) =>
            ((dx - pad) / pps).clamp(0, total).toDouble();

        return GestureDetector(
          key: const Key('timeline'),
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) => onSeek(seekFor(d.localPosition.dx)),
          onDoubleTapDown: (d) => onSplitAt?.call(seekFor(d.localPosition.dx)),
          onSecondaryTapUp: (d) => onSplitAt?.call(seekFor(d.localPosition.dx)),
          onHorizontalDragUpdate: (d) => onSeek(seekFor(d.localPosition.dx)),
          child: SizedBox(
            width: box.maxWidth,
            child: Stack(
              children: [
                const Positioned(
                  left: 0,
                  top: 20,
                  child: Text(
                    '1 VIDEO',
                    style: TextStyle(fontSize: 8, color: Colors.white38),
                  ),
                ),
                const Positioned(
                  left: 0,
                  top: 124,
                  child: Text(
                    '2 AUDIO',
                    style: TextStyle(fontSize: 8, color: Colors.white38),
                  ),
                ),
                const Positioned(
                  left: 0,
                  top: 94,
                  child: Text(
                    '3 IMAGEM',
                    style: TextStyle(fontSize: 8, color: Colors.white38),
                  ),
                ),
                const Positioned(
                  left: 0,
                  top: 138,
                  child: Text(
                    '4 OVERLAY',
                    style: TextStyle(fontSize: 8, color: Colors.white38),
                  ),
                ),
                _ruler(pps, pad, total),
                for (var i = 0; i < project.clips.length; i++)
                  _clip(i, pps, pad),
                for (var i = 1; i < project.clips.length; i++)
                  _transitionChip(i, pps, pad),
                for (var j = 0; j < project.overlays.length; j++)
                  _overlayBar(project.overlays[j], j, pps, pad, total),
                for (var j = 0; j < project.sounds.length; j++)
                  _soundMarker(project.sounds[j], j, pps, pad, total),
                Positioned(
                  left: pad + playhead * pps - 1,
                  top: 0,
                  bottom: 0,
                  child: Container(
                    key: const Key('playhead'),
                    width: 2,
                    color: Colors.redAccent,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _ruler(double pps, double pad, double total) {
    final step = total <= 20 ? 1 : (total <= 60 ? 5 : 10);
    return Positioned.fill(
      child: Stack(
        children: [
          for (var t = 0; t <= total; t += step)
            Positioned(
              left: pad + t * pps,
              top: 0,
              child: Text(
                formatTime(t.toDouble()).substring(0, 5),
                style: const TextStyle(fontSize: 9, color: Colors.white38),
              ),
            ),
        ],
      ),
    );
  }

  Widget _clip(int i, double pps, double pad) {
    final c = project.clips[i];
    final selected = i == selectedClip;
    return Positioned(
      left: pad + project.clipStart(i) * pps,
      top: 16,
      width: (c.duration * pps).clamp(6, double.infinity),
      height: 52,
      child: Container(
        key: ValueKey('clip-$i'),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF3B5A1F) : const Color(0xFF263D20),
          border: Border.all(
            color: selected ? _accent : const Color(0xFF3F5A33),
            width: selected ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(6),
        ),
        child: GestureDetector(
          onTap: () {
            onSelectClip(i);
            onSeek(project.clipStart(i));
          },
          child: Text(
            'Clipe ${i + 1}\n${c.duration.toStringAsFixed(1)}s',
            overflow: TextOverflow.clip,
            maxLines: 2,
            style: const TextStyle(fontSize: 10, color: Colors.white70),
          ),
        ),
      ),
    );
  }

  Widget _transitionChip(int i, double pps, double pad) {
    final t = project.clips[i].transition;
    return Positioned(
      left: pad + project.clipStart(i) * pps - 2,
      top: 70,
      child: GestureDetector(
        key: ValueKey('transition-$i'),
        onTap: () => onTransitionTap(i),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(
            color: t == null
                ? const Color(0xFF1A2030)
                : const Color(0xFF5B3FA0),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white24),
          ),
          child: Text(
            t == null ? '+ trans.' : t.name,
            style: const TextStyle(fontSize: 9, color: Colors.white70),
          ),
        ),
      ),
    );
  }

  Widget _overlayBar(
    OverlayImage o,
    int row,
    double pps,
    double pad,
    double total,
  ) {
    final selected = o.id == selectedOverlayId;
    final start = o.start.clamp(0, total).toDouble();
    final end = o.end.clamp(start, total).toDouble();
    return Positioned(
      left: pad + start * pps,
      top: 92 + row * 14.0,
      width: ((end - start) * pps).clamp(4, double.infinity),
      height: 11,
      child: GestureDetector(
        key: ValueKey('overlay-bar-${o.id}'),
        onTap: () => onSelectOverlay(o.id),
        onHorizontalDragUpdate: (d) {
          final delta = d.delta.dx / pps;
          final length = end - start;
          var nextStart = (start + delta).clamp(0, total - length).toDouble();
          onMoveOverlay?.call(o.id, nextStart, nextStart + length);
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            Container(
              decoration: BoxDecoration(
                color: const Color(0xFF1E88C9)
                    .withValues(alpha: selected ? 1 : 0.6),
                border: selected ? Border.all(color: Colors.white) : null,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              width: 8,
              child: GestureDetector(
                key: ValueKey('overlay-resize-${o.id}'),
                onHorizontalDragUpdate: (d) {
                  final nextEnd = (end + d.delta.dx / pps)
                      .clamp(start + 0.1, total)
                      .toDouble();
                  onResizeOverlay?.call(o.id, nextEnd);
                },
                child: Container(color: Colors.white24),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _soundMarker(
    SoundItem s,
    int row,
    double pps,
    double pad,
    double total,
  ) {
    final start = s.at.clamp(0, total).toDouble();
    final end = (start + s.duration).clamp(start + 0.1, total).toDouble();
    return Positioned(
      left: pad + start * pps,
      top: 122 + row * 14.0,
      width: ((end - start) * pps).clamp(12, double.infinity),
      height: 11,
      child: GestureDetector(
        key: ValueKey('sound-bar-${s.id}'),
        onHorizontalDragUpdate: (d) {
          final next = (start + d.delta.dx / pps)
              .clamp(0, total - s.duration)
              .toDouble();
          onMoveSound?.call(s.id, next);
        },
        child: Tooltip(
          message: s.name,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFFFFB74D).withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: const Icon(
                  Icons.music_note,
                  size: 9,
                  color: Colors.black87,
                ),
              ),
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                width: 8,
                child: GestureDetector(
                  key: ValueKey('sound-resize-${s.id}'),
                  onHorizontalDragUpdate: (d) {
                    final duration = (s.duration + d.delta.dx / pps)
                        .clamp(0.1, total - start)
                        .toDouble();
                    onResizeSound?.call(s.id, duration);
                  },
                  child: Container(color: Colors.black26),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
