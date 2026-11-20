import 'package:flutter/material.dart';

enum CursorStyle { arrow, hand, auto }

class KineticCursorOptions {
  KineticCursorOptions({
    this.enabled = false,
    this.smoothing = 65,
    this.scale = 1.5,
    this.motionBlur = true,
    this.motionBlurIntensity = 65,
    this.clickAnimation = true,
    this.highlightColor = const Color(0xFFB6FF4A),
    this.style = CursorStyle.arrow,
  });

  bool enabled;
  double smoothing;
  double scale;
  bool motionBlur;
  double motionBlurIntensity;
  bool clickAnimation;
  Color highlightColor;
  CursorStyle style;

  KineticCursorOptions copyWith({
    bool? enabled,
    double? smoothing,
    double? scale,
    bool? motionBlur,
    double? motionBlurIntensity,
    bool? clickAnimation,
    Color? highlightColor,
    CursorStyle? style,
  }) {
    return KineticCursorOptions(
      enabled: enabled ?? this.enabled,
      smoothing: smoothing ?? this.smoothing,
      scale: scale ?? this.scale,
      motionBlur: motionBlur ?? this.motionBlur,
      motionBlurIntensity: motionBlurIntensity ?? this.motionBlurIntensity,
      clickAnimation: clickAnimation ?? this.clickAnimation,
      highlightColor: highlightColor ?? this.highlightColor,
      style: style ?? this.style,
    );
  }
}
