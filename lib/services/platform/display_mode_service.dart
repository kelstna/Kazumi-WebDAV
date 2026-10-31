import 'dart:io';

import 'package:flutter/services.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/utils/device.dart';
import 'package:window_manager/window_manager.dart';

class DisplayModeService {
  DisplayModeService._();

  static const _intentChannel = MethodChannel('com.predidit.kazumi/intent');
  static Future<void> _pendingFullscreen = Future.value();
  static Future<void>? _pendingSystemBars;

  /// Page level intent: the route wants an immersive window.
  static Object? _systemBarsOwner;
  static bool _systemBarsHidden = false;

  /// Player control layer: show the status bar without leaving immersion.
  static Object? _statusBarOverlayOwner;
  static bool _statusBarOverlay = false;

  /// Last state handed to the platform, used to skip redundant channel calls.
  static bool _appliedHidden = false;
  static bool _appliedStatusBarOverlay = false;

  static Future<void> applyVideoFullscreen(bool fullscreen) {
    return _pendingFullscreen = _pendingFullscreen.then((_) async {
      if (isDesktop()) {
        await _attempt(() => windowManager.setFullScreen(fullscreen));
        return;
      }

      // Restore system orientation on exit, including an existing landscape.
      await _attempt(() => SystemChrome.setPreferredOrientations(
            fullscreen
                ? [
                    DeviceOrientation.landscapeLeft,
                    DeviceOrientation.landscapeRight
                  ]
                : [],
          ));
    });
  }

  /// Outgoing pages cannot release chrome owned by the next visible page.
  static Future<void> setSystemBarsHidden({
    required Object owner,
    required bool hidden,
  }) {
    _systemBarsOwner = owner;
    _systemBarsHidden = hidden;
    return _applySystemBars();
  }

  static Future<void> releaseSystemBars(Object owner) {
    if (!identical(_systemBarsOwner, owner)) {
      return _pendingSystemBars ?? Future.value();
    }
    _systemBarsOwner = null;
    _systemBarsHidden = false;
    return _applySystemBars();
  }

  /// The player control layer is on screen, so the status bar comes back while
  /// the page itself stays immersive - the VLC behaviour. Only Android exposes
  /// the status bar alone; the layout reads the resulting inset back from
  /// MediaQuery, so no fixed height is hard coded here.
  static Future<void> setStatusBarOverlay({
    required Object owner,
    required bool visible,
  }) {
    if (!visible && !identical(_statusBarOverlayOwner, owner)) {
      return _pendingSystemBars ?? Future.value();
    }
    _statusBarOverlayOwner = visible ? owner : null;
    if (_statusBarOverlay == visible) {
      return _pendingSystemBars ?? Future.value();
    }
    _statusBarOverlay = visible;
    return _applySystemBars();
  }

  static Future<void> _applySystemBars() {
    final bool hidden = _systemBarsHidden;
    final bool overlay = hidden && _statusBarOverlay && Platform.isAndroid;
    if (hidden == _appliedHidden && overlay == _appliedStatusBarOverlay) {
      return _pendingSystemBars ?? Future.value();
    }
    _appliedHidden = hidden;
    _appliedStatusBarOverlay = overlay;
    // Rotation acknowledgements must not delay immersion or route cleanup.
    late final Future<void> request;
    request = (_pendingSystemBars ?? Future<void>.value())
        .then((_) => _attempt(() async {
              if (Platform.isAndroid) {
                await _intentChannel.invokeMethod('setSystemBarsState', {
                  'hidden': hidden,
                  'statusBarOverlay': overlay,
                });
              } else if (Platform.isIOS) {
                await SystemChrome.setEnabledSystemUIMode(
                  hidden
                      ? SystemUiMode.immersiveSticky
                      : SystemUiMode.edgeToEdge,
                );
              }
            }))
        .whenComplete(() {
      if (identical(_pendingSystemBars, request)) _pendingSystemBars = null;
    });
    return _pendingSystemBars = request;
  }

  static Future<void> _attempt(Future<void> Function() operation) async {
    try {
      await operation();
    } catch (error, stackTrace) {
      KazumiLogger().e('Display: failed to apply video display mode',
          error: error, stackTrace: stackTrace);
    }
  }
}
