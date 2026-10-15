import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:light/light.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'display_controller.dart';
import 'motion_detector.dart';

/// Verbindet den [DisplayController] mit Android: Wakelock, Fensterhelligkeit,
/// Lichtsensor und Kamera. Die UI hört auf [state] und [nightTheme].
class DisplayService extends ChangeNotifier with WidgetsBindingObserver {
  DisplayService([DisplaySettings settings = const DisplaySettings()]) : ctrl = DisplayController(settings);

  final DisplayController ctrl;
  late final MotionDetector _motion = MotionDetector(onMotion: _onMotion, onLuma: _onLuma);

  Timer? _ticker;
  Timer? _ramp;
  StreamSubscription<int>? _lux;
  bool _hasLightSensor = false;
  double _current = -1; // zuletzt gesetzte Helligkeit
  DisplayState _lastState = DisplayState.active;
  bool _lastNight = false;

  DisplayState get state => ctrl.state;
  bool get nightTheme => ctrl.nightTheme;

  Future<void> start() async {
    WidgetsBinding.instance.addObserver(this);
    await WakelockPlus.enable();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      ctrl.tick();
      _apply();
    });
    _ramp = Timer.periodic(const Duration(milliseconds: 100), (_) => _rampStep());
    _lux = Light().lightSensorStream.listen((v) {
      _hasLightSensor = true;
      ctrl.onAmbientLux(v.toDouble());
    }, onError: (_) {});
    if (ctrl.settings.useCamera) await _motion.start();
    _apply();
  }

  void updateSettings(DisplaySettings s) {
    ctrl.settings = s;
    if (s.useCamera) {
      unawaited(_motion.start());
    } else {
      unawaited(_motion.stop());
    }
    _apply();
  }

  void touch() {
    ctrl.onTouch();
    _apply();
  }

  void wake() {
    ctrl.onWakeSignal();
    _apply();
  }

  void presence(bool present) {
    ctrl.onPresenceSensor(present);
    _apply();
  }

  void _onMotion(double area) {
    ctrl.onCameraMotion(area: area);
    _apply();
  }

  void _onLuma(double luma) {
    if (!_hasLightSensor) ctrl.onCameraLuma(luma);
  }

  void _apply() {
    if (ctrl.state != _lastState || ctrl.nightTheme != _lastNight) {
      _lastState = ctrl.state;
      _lastNight = ctrl.nightTheme;
      notifyListeners();
    }
  }

  /// Helligkeit sanft nachführen: aufwachen schnell, dimmen langsam.
  void _rampStep() {
    final target = ctrl.brightness;
    if (_current < 0) {
      _set(target);
      return;
    }
    final diff = target - _current;
    if (diff.abs() < 0.005) return;
    final step = diff > 0 ? 0.25 : 0.04;
    _set(diff.abs() <= step ? target : _current + step * diff.sign);
  }

  void _set(double v) {
    _current = v;
    ScreenBrightness().setApplicationScreenBrightness(v.clamp(0.0, 1.0)).catchError((_) {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      WakelockPlus.enable();
      if (ctrl.settings.useCamera) _motion.start();
      ctrl.onTouch();
      _apply();
    } else if (state == AppLifecycleState.paused) {
      _motion.stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    _ramp?.cancel();
    _lux?.cancel();
    _motion.stop();
    ScreenBrightness().resetApplicationScreenBrightness().catchError((_) {});
    super.dispose();
  }
}
