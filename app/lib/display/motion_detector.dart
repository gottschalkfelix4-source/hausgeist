import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';

/// Erkennt Bewegung vor dem Tablet über die Frontkamera.
/// Die Bilder werden nur im Speicher verglichen, nie gespeichert oder gesendet.
///
/// Pro Bild (ca. 5/s, 320x240) wird der Helligkeitskanal auf ein 32x24-Raster verkleinert und mit
/// dem vorigen verglichen. [onMotion] bekommt den Anteil geänderter Rasterzellen (0..1):
/// jemand direkt vor dem Tablet ändert viel, jemand hinten im Raum wenig.
class MotionDetector {
  MotionDetector({required this.onMotion, required this.onLuma});

  final void Function(double area) onMotion;
  final void Function(double meanLuma) onLuma;

  static const _gx = 32, _gy = 24;
  static const _cellThreshold = 18; // Helligkeitsunterschied, ab dem eine Zelle "geändert" ist
  static const _minArea = 0.02; // darunter: Rauschen
  static const _interval = Duration(milliseconds: 200);

  CameraController? _cam;
  Float32List? _prev;
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);
  bool _starting = false;

  bool get running => _cam?.value.isStreamingImages ?? false;

  Future<void> start() async {
    if (_cam != null || _starting) return;
    _starting = true;
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) return;
      final front = cams.firstWhere((c) => c.lensDirection == CameraLensDirection.front, orElse: () => cams.first);
      final cam = CameraController(front, ResolutionPreset.low, enableAudio: false, imageFormatGroup: ImageFormatGroup.yuv420);
      await cam.initialize();
      await cam.startImageStream(_onFrame);
      _cam = cam;
    } catch (e) {
      debugPrint('Kamera nicht verfügbar: $e');
    } finally {
      _starting = false;
    }
  }

  Future<void> stop() async {
    final cam = _cam;
    _cam = null;
    _prev = null;
    if (cam == null) return;
    try {
      if (cam.value.isStreamingImages) await cam.stopImageStream();
    } catch (_) {}
    await cam.dispose();
  }

  void _onFrame(CameraImage img) {
    final now = DateTime.now();
    if (now.difference(_last) < _interval) return;
    _last = now;

    final grid = downsampleLuma(img.planes[0].bytes, img.width, img.height, img.planes[0].bytesPerRow);
    var mean = 0.0;
    for (final v in grid) {
      mean += v;
    }
    mean /= grid.length;
    onLuma(mean);

    final prev = _prev;
    _prev = grid;
    if (prev == null) return;
    final area = changedArea(prev, grid);
    if (area >= _minArea) onMotion(area);
  }

  /// Y-Kanal auf [_gx]x[_gy] Zellen mitteln (je Zelle 4x4 Stichproben).
  static Float32List downsampleLuma(Uint8List y, int w, int h, int stride) {
    final out = Float32List(_gx * _gy);
    final cw = w / _gx, ch = h / _gy;
    for (var gy = 0; gy < _gy; gy++) {
      for (var gx = 0; gx < _gx; gx++) {
        var sum = 0;
        for (var sy = 0; sy < 4; sy++) {
          final py = (gy * ch + (sy + .5) * ch / 4).toInt();
          for (var sx = 0; sx < 4; sx++) {
            final px = (gx * cw + (sx + .5) * cw / 4).toInt();
            final i = py * stride + px;
            if (i < y.length) sum += y[i];
          }
        }
        out[gy * _gx + gx] = sum / 16;
      }
    }
    return out;
  }

  /// Anteil geänderter Zellen. Eine gleichmäßige Helligkeitsänderung (Licht an, Belichtung)
  /// wird vorher herausgerechnet, damit sie nicht als Bewegung zählt.
  static double changedArea(Float32List a, Float32List b) {
    var ma = 0.0, mb = 0.0;
    for (var i = 0; i < a.length; i++) {
      ma += a[i];
      mb += b[i];
    }
    final shift = (mb - ma) / a.length;
    var changed = 0;
    for (var i = 0; i < a.length; i++) {
      if ((b[i] - a[i] - shift).abs() > _cellThreshold) changed++;
    }
    return changed / a.length;
  }
}
