// SPDX-FileCopyrightText: Copyright (C) 2026 kelstna (AI-assisted modification, see NOTICE.md)
// SPDX-License-Identifier: GPL-3.0-only

// ignore_for_file: library_private_types_in_public_api

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/pages/player/controller/player_debug_controller.dart';
import 'package:kazumi/pages/player/controller/player_super_resolution.dart';
import 'package:kazumi/services/shaders/shader_asset_service.dart';
import 'package:kazumi/utils/constants.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/network/proxy_utils.dart';
import 'package:kazumi/services/network/system_proxy_service.dart';
import 'package:kazumi/services/player/playback_cache_policy.dart';
import 'package:kazumi/services/player/player_error_mapper.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/video_source/video_source_format.dart';
import 'package:kazumi/utils/async_serial_queue.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:mobx/mobx.dart';
import 'package:kazumi/utils/device.dart';
import 'package:kazumi/utils/media.dart';
import 'package:kazumi/services/platform/platform_environment_service.dart';

part 'player_playback_controller.g.dart';

class PlayerPlaybackController = _PlayerPlaybackController
    with _$PlayerPlaybackController;

final class _OwnedPlayer {
  _OwnedPlayer(this.player);

  final Player player;
  Future<void>? _disposeFuture;

  Future<void> dispose() {
    return _disposeFuture ??= _dispose();
  }

  Future<void> _dispose() async {
    try {
      await player.dispose();
    } catch (error, stackTrace) {
      KazumiLogger().e(
        'PlayerPlaybackController: failed to dispose media player',
        error: error,
        stackTrace: stackTrace,
      );
      try {
        await player.stop();
      } catch (_) {}
    }
  }
}

abstract class _PlayerPlaybackController with Store {
  _PlayerPlaybackController({
    required this.shaderAssetService,
    required this.debug,
    required this.videoUrl,
    required this.isLocalPlayback,
  });

  final ShaderAssetService shaderAssetService;
  final PlayerDebugController debug;
  final String Function() videoUrl;
  final bool Function() isLocalPlayback;
  late final PlaybackCachePolicy cachePolicy = PlaybackCachePolicy(
    isLocalPlayback: isLocalPlayback,
    currentPlayer: () => mediaPlayer,
  );

  _OwnedPlayer? _ownedPlayer;
  Player? get mediaPlayer => _ownedPlayer?.player;
  VideoController? videoController;

  final AsyncSerialQueue _prefetchWrites = AsyncSerialQueue();
  bool _prefetchSuspendWanted = false;

  // ---- 起播兜底 / 「有声音没画面」探测 --------------------------------
  //
  // `loading` 原本只在 init() 末尾降为 false：只要打开流程里任何一个 await
  // 卡住、或被下一次切集顶掉，遮罩就永远盖在画面上（音频还在响，因为
  // player.open() 早已带 play 打开）。这里补三件事：
  //   1. 起播信号（首帧 / playing / position 前进）任一到达即收起遮罩；
  //   2. 绝对上限：到点仍无信号也收起遮罩，让用户看到真实状态；
  //   3. 有音无画：起播后仍拿不到首帧，且文件确实有视频轨，就提示一次
  //      并关掉硬件解码重开一次。
  static const Duration _startupDeadline = Duration(seconds: 8);
  static const Duration _videoFrameDeadline = Duration(seconds: 8);

  /// 首帧是否已到达（纯音频文件恒为 false）。
  bool videoReady = false;

  /// 起播阶段是否已超时收起遮罩（UI 不再停在「播放器加载中」）。
  bool startupStalled = false;

  bool _softDecodeRetryTried = false;
  bool _hasVideoTrack = false;
  Media? _currentMedia;
  Timer? _startupWatchdog;
  Timer? _videoWatchdog;
  StreamSubscription<VideoParams>? _videoParamsSubscription;
  StreamSubscription<Tracks>? _tracksSubscription;
  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<Duration>? _positionSubscription;

  bool hAenable = true;
  late String hardwareDecoder;
  bool androidEnableOpenSLES = true;
  bool autoPlay = true;
  bool playerDebugMode = false;
  int buttonSkipTime = 80;
  int arrowKeySkipTime = 10;

  /// 历史记录传入的 offset
  int startOffset = 0;

  /// 当前超分辨率模式
  @observable
  SuperResolutionMode superResolutionMode = SuperResolutionMode.off;

  @observable
  double volume = -1;

  /// 手势调节时的精确音量，避免 UI 节流导致累计误差
  double preciseVolume = -1;

  @observable
  bool loading = true;
  @observable
  bool playing = false;
  @observable
  bool isBuffering = true;
  @observable
  bool completed = false;
  @observable
  Duration currentPosition = Duration.zero;
  @observable
  Duration buffer = Duration.zero;
  @observable
  Duration duration = Duration.zero;
  @observable
  double playerSpeed = 1.0;

  bool isCurrentPlayer(Player player) {
    return identical(mediaPlayer, player);
  }

  Future<Player?> _discardIfNotCurrent(_OwnedPlayer candidate) async {
    if (identical(_ownedPlayer, candidate)) {
      return candidate.player;
    }
    await candidate.dispose();
    return null;
  }

  Future<void> _cancelDebugInfo() async {
    try {
      await debug.cancel();
    } catch (_) {}
  }

  /// 起播探针：首帧、轨道列表、起播信号，外加一个绝对上限的兜底计时器。
  /// 每次新建播放器时挂一次，[stop] / [resetForInit] 时拆掉。
  void _armStartupProbes(Player player) {
    _teardownStartupProbes();
    videoReady = false;
    startupStalled = false;
    _hasVideoTrack = false;
    _softDecodeRetryTried = false;

    _videoParamsSubscription = player.stream.videoParams.listen((params) {
      final int width = params.w ?? 0;
      final int height = params.h ?? 0;
      // 换文件/停止时 mpv 会广播一个空 VideoParams，别把它当首帧。
      if (width <= 0 || height <= 0 || videoReady) {
        return;
      }
      videoReady = true;
      KazumiLogger().i(
          'PlayerController: first video frame ${width}x$height, releasing loading');
      _finishStartup(reason: 'first-frame');
    });

    _tracksSubscription = player.stream.tracks.listen((tracks) {
      _hasVideoTrack = _hasUsableVideoTrack(tracks);
    });

    _playingSubscription = player.stream.playing.listen((playing) {
      if (!playing) {
        return;
      }
      _finishStartup(reason: 'playing');
      _armVideoWatchdog();
    });

    _positionSubscription = player.stream.position.listen((position) {
      if (position <= Duration.zero) {
        return;
      }
      _finishStartup(reason: 'position');
      _armVideoWatchdog();
    });

    _startupWatchdog?.cancel();
    _startupWatchdog = Timer(_startupDeadline, () {
      _startupWatchdog = null;
      if (!loading) {
        return;
      }
      startupStalled = true;
      KazumiLogger().w(
          'PlayerController: startup stalled ${_startupDeadline.inSeconds}s, '
          'releasing loading overlay');
      _setLoading(false);
    });
  }

  void _teardownStartupProbes() {
    _startupWatchdog?.cancel();
    _startupWatchdog = null;
    _videoWatchdog?.cancel();
    _videoWatchdog = null;
    unawaited(_videoParamsSubscription?.cancel());
    _videoParamsSubscription = null;
    unawaited(_tracksSubscription?.cancel());
    _tracksSubscription = null;
    unawaited(_playingSubscription?.cancel());
    _playingSubscription = null;
    unawaited(_positionSubscription?.cancel());
    _positionSubscription = null;
  }

  static bool _hasUsableVideoTrack(Tracks tracks) => tracks.video
      .any((track) => track.id != 'auto' && track.id != 'no');

  /// 起播信号到达：收起加载遮罩。
  void _finishStartup({required String reason}) {
    _startupWatchdog?.cancel();
    _startupWatchdog = null;
    // position 事件每秒来很多次，起播信号拿到后就退订，播放期间不空转。
    unawaited(_positionSubscription?.cancel());
    _positionSubscription = null;
    if (!loading) {
      return;
    }
    KazumiLogger().i('PlayerController: loading released by $reason');
    _setLoading(false);
  }

  void _setLoading(bool value) {
    if (loading == value) {
      return;
    }
    loading = value;
  }

  /// 播放器已就绪（open 成功）：立刻收起遮罩，字幕/音轨/音量都算后台收尾。
  void markStartupComplete() {
    if (startupStalled) {
      KazumiLogger().i('PlayerController: startup recovered after stall');
      startupStalled = false;
    }
    _finishStartup(reason: 'open-complete');
  }

  /// 起播失败：收起遮罩，由上层决定显示哪种错误。
  void markStartupFailed() {
    _teardownStartupProbes();
    _setLoading(false);
  }

  /// 有声音没画面探测：起播后 [_videoFrameDeadline] 内仍无首帧就处理一次。
  void _armVideoWatchdog() {
    if (_videoWatchdog != null || videoReady) {
      return;
    }
    _videoWatchdog = Timer(_videoFrameDeadline, () {
      _videoWatchdog = null;
      final player = mediaPlayer;
      if (player == null || videoReady) {
        return;
      }
      var hasVideo = _hasVideoTrack;
      if (!hasVideo) {
        // 轨道列表可能比计时器晚，这里直接读当前状态兜底；播放器已释放时忽略。
        try {
          hasVideo = _hasUsableVideoTrack(player.state.tracks);
        } catch (_) {
          hasVideo = false;
        }
      }
      if (!hasVideo) {
        // 纯音频文件，或轨道列表压根没到（不是"画面没出来"），不打扰用户。
        KazumiLogger().i(
            'PlayerController: no video track reported, skip frame watchdog');
        return;
      }
      startupStalled = true;
      _setLoading(false);
      KazumiLogger().w(
          'PlayerController: audio is playing but no video frame in '
          '${_videoFrameDeadline.inSeconds}s');
      if (_softDecodeRetryTried || !hAenable) {
        // 已经试过软解（或本来就是软解）：只给可操作的提示。
        KazumiDialog.showToast(
          message: '画面没有出来，可尝试关闭硬件解码或换一个视频来源',
          duration: const Duration(seconds: 5),
          showActionButton: true,
        );
        return;
      }
      unawaited(_retryWithSoftwareDecoder());
    });
  }

  /// 关掉硬件解码后重开同一份媒体，每集只尝试一次。
  Future<void> _retryWithSoftwareDecoder() async {
    if (_softDecodeRetryTried) {
      return;
    }
    final player = mediaPlayer;
    final media = _currentMedia;
    if (player == null || media == null) {
      return;
    }
    _softDecodeRetryTried = true;
    KazumiLogger().w(
        'PlayerController: retrying with hardware decoding disabled');
    KazumiDialog.showToast(
      message: '画面未就绪，已切换软解重试',
      duration: const Duration(seconds: 4),
    );
    try {
      final pp = player.platform as NativePlayer;
      await pp.setProperty('hwdec', 'no');
      if (!isCurrentPlayer(player)) {
        return;
      }
      videoReady = false;
      _hasVideoTrack = false;
      final Duration position = player.state.position;
      final replay = Media(
        media.uri,
        start: position > Duration.zero ? position : media.start,
        httpHeaders: media.httpHeaders,
      );
      _currentMedia = replay;
      await player.open(replay, play: autoPlay);
      if (!isCurrentPlayer(player)) {
        return;
      }
      _armVideoWatchdog();
    } catch (error) {
      KazumiLogger().e(
          'PlayerController: software decode retry failed', error: error);
    }
  }

  @action
  void resetForInit() {
    _teardownStartupProbes();
    videoReady = false;
    startupStalled = false;
    _hasVideoTrack = false;
    _softDecodeRetryTried = false;
    _currentMedia = null;
    playing = false;
    loading = true;
    isBuffering = true;
    currentPosition = Duration.zero;
    buffer = Duration.zero;
    duration = Duration.zero;
    completed = false;
    startOffset = 0;
  }

  /// 本次会话是否从距结尾 [nearEndWatchedThreshold] 以内的位置起播。
  /// 这样的"播放完成"并非真正看完，应从头重播而非切下一集
  bool get resumedNearEnd {
    if (startOffset <= 0 || duration <= Duration.zero) {
      return false;
    }
    return Duration(seconds: startOffset) >= duration - nearEndWatchedThreshold;
  }

  /// 从头重播当前视频。[startOffset] 在重播落地后才归零，
  /// 避免自动连播在此期间抢先触发
  Future<void> restartFromBeginning() async {
    final player = mediaPlayer;
    if (player == null) {
      return;
    }
    try {
      await player.seek(Duration.zero);
      if (!isCurrentPlayer(player)) {
        return;
      }
      await player.play();
      startOffset = 0;
    } catch (e) {
      KazumiLogger()
          .w('PlayerController: failed to restart from beginning', error: e);
    }
  }

  bool get playerPlaying {
    try {
      return mediaPlayer?.state.playing ?? false;
    } catch (_) {
      return false;
    }
  }

  bool get playerBuffering {
    try {
      return mediaPlayer?.state.buffering ?? false;
    } catch (_) {
      return false;
    }
  }

  bool get playerCompleted {
    try {
      return mediaPlayer?.state.completed ?? false;
    } catch (_) {
      return false;
    }
  }

  double get playerVolume {
    try {
      return mediaPlayer?.state.volume ?? volume;
    } catch (_) {
      return volume;
    }
  }

  Duration get playerPosition {
    try {
      return mediaPlayer?.state.position ?? currentPosition;
    } catch (_) {
      return currentPosition;
    }
  }

  Duration get playerBuffer {
    try {
      return mediaPlayer?.state.buffer ?? buffer;
    } catch (_) {
      return buffer;
    }
  }

  Duration get playerDuration {
    try {
      return mediaPlayer?.state.duration ?? duration;
    } catch (_) {
      return duration;
    }
  }

  /// Android blocks network access for backgrounded apps; a prefetching
  /// demuxer then burns through ffmpeg's reconnect/segment retries and marks
  /// the stream EOF, leaving playback permanently stuck once foregrounded.
  /// Suspending zeroes the readahead window so no new requests are issued
  /// while buffered data stays available; restore values are mpv defaults,
  /// which media_kit leaves untouched. Writes are serialized and apply the
  /// latest requested state, so rapid lifecycle flips cannot reorder.
  Future<void> setPrefetchSuspended(bool suspended) async {
    if (!Platform.isAndroid) {
      return;
    }
    _prefetchSuspendWanted = suspended;
    await _prefetchWrites.run(() async {
      final wanted = _prefetchSuspendWanted;
      final player = mediaPlayer;
      if (player == null) {
        return;
      }
      try {
        final pp = player.platform as NativePlayer;
        await pp.setProperty('cache-secs', wanted ? '0' : '36000');
        if (!isCurrentPlayer(player)) {
          return;
        }
        await pp.setProperty('demuxer-readahead-secs', wanted ? '0' : '1');
      } catch (e) {
        KazumiLogger().w(
          'PlayerController: failed to ${wanted ? 'suspend' : 'resume'} demuxer prefetch',
          error: e,
        );
      }
    });
  }

  Future<Player?> createVideoController(
    Map<String, String> httpHeaders,
    bool adBlockerEnabled, {
    required bool Function() canInstall,
    int offset = 0,
    VideoSourceFormat videoSourceFormat = VideoSourceFormat.auto,
  }) async {
    startOffset = offset;
    superResolutionMode = SuperResolutionMode.fromStorageValue(
      GStorage.getSetting(SettingsKeys.defaultSuperResolutionMode),
    );
    hAenable = GStorage.getSetting(SettingsKeys.hAenable);
    androidEnableOpenSLES =
        GStorage.getSetting(SettingsKeys.androidEnableOpenSLES);
    hardwareDecoder = GStorage.getSetting(SettingsKeys.hardwareDecoder);
    autoPlay = GStorage.getSetting(SettingsKeys.autoPlay);
    playerDebugMode = GStorage.getSetting(SettingsKeys.playerDebugMode);

    final bool useLibass =
        GStorage.getSetting(SettingsKeys.subtitleRenderMode) != 'simple';

    if (!canInstall()) {
      return null;
    }
    final candidate = _OwnedPlayer(
      Player(
        configuration: PlayerConfiguration(
          bufferSize: cachePolicy.bufferSize,
          osc: false,
          logLevel: MPVLogLevel.values[debug.playerLogLevel],
          adBlocker: adBlockerEnabled,
          // 默认走 libass：保留 ASS 特效/字体，并能渲染 PGS 等图形字幕。
          // Android 上 libass 必须提供一个内置字体才能初始化 fontconfig。
          libass: useLibass,
          libassAndroidFont:
              useLibass ? 'assets/fonts/MiSans-Regular.ttf' : null,
          libassAndroidFontName: useLibass ? 'MiSans' : null,
        ),
      ),
    );
    final player = candidate.player;
    if (!canInstall()) {
      await candidate.dispose();
      return null;
    }
    _ownedPlayer = candidate;
    cachePolicy.startWatching();
    _armStartupProbes(player);

    try {
      debug.playerLog.clear();
      await debug.setup(
        player,
        isCurrentPlayer: isCurrentPlayer,
        playerDebugMode: playerDebugMode,
      );
      if (!isCurrentPlayer(player)) {
        return await _discardIfNotCurrent(candidate);
      }

      var pp = player.platform as NativePlayer;
      // media-kit 默认启用硬盘作为双重缓存，这可以维持大缓存的前提下减轻内存压力
      // media-kit 内部硬盘缓存目录按照 Linux 配置，这导致该功能在其他平台上被损坏
      // 该设置可以在所有平台上正确启用双重缓存
      await pp.setProperty("demuxer-cache-dir", await getPlayerTempPath());
      if (!isCurrentPlayer(player)) {
        return await _discardIfNotCurrent(candidate);
      }
      await cachePolicy.apply();
      if (!isCurrentPlayer(player)) {
        return await _discardIfNotCurrent(candidate);
      }
      await pp.setProperty("af", "scaletempo2=max-speed=8");
      if (!isCurrentPlayer(player)) {
        return await _discardIfNotCurrent(candidate);
      }
      if (Platform.isAndroid) {
        await pp.setProperty("volume-max", "100");
        if (!isCurrentPlayer(player)) {
          return await _discardIfNotCurrent(candidate);
        }
        if (androidEnableOpenSLES) {
          await pp.setProperty("ao", "opensles");
        } else {
          await pp.setProperty("ao", "audiotrack");
        }
        if (!isCurrentPlayer(player)) {
          return await _discardIfNotCurrent(candidate);
        }
      }

      final bool proxyEnable = GStorage.getSetting(SettingsKeys.proxyEnable);
      if (proxyEnable) {
        final String proxyUrl = GStorage.getSetting(SettingsKeys.proxyUrl);
        final formattedProxy = ProxyUtils.getFormattedProxyUrl(proxyUrl);
        if (formattedProxy != null) {
          await pp.setProperty("http-proxy", formattedProxy);
          if (!isCurrentPlayer(player)) {
            return await _discardIfNotCurrent(candidate);
          }
          KazumiLogger().i('Player: HTTP 代理设置成功 $formattedProxy');
        }
      } else if (SystemProxyService.isActive) {
        final proxy = SystemProxyService.proxyFor('https');
        if (proxy != null) {
          await pp.setProperty("http-proxy", 'http://${proxy.$1}:${proxy.$2}');
          if (!isCurrentPlayer(player)) {
            return await _discardIfNotCurrent(candidate);
          }
          KazumiLogger().i('Player: 跟随系统代理 http://${proxy.$1}:${proxy.$2}');
        }
      }

      await player.setAudioTrack(
        AudioTrack.auto(),
      );
      if (!isCurrentPlayer(player)) {
        return await _discardIfNotCurrent(candidate);
      }

      String? videoRenderer;
      if (Platform.isAndroid) {
        final String androidVideoRenderer =
            GStorage.getSetting(SettingsKeys.androidVideoRenderer);

        if (androidVideoRenderer == 'auto') {
          // Android 14 及以上使用基于 Vulkan 的 MPV GPU-NEXT 视频输出，着色器性能更好
          // GPU-NEXT 需要 Vulkan 1.2 支持
          // 避免 Android 13 及以下设备上部分机型 Vulkan 支持不佳导致的黑屏问题
          final int androidSdkVersion =
              await PlatformEnvironmentService.getAndroidSdkVersion();
          if (!isCurrentPlayer(player)) {
            return await _discardIfNotCurrent(candidate);
          }
          if (androidSdkVersion >= 34) {
            videoRenderer = 'gpu-next';
          } else {
            videoRenderer = 'gpu';
          }
        } else {
          videoRenderer = androidVideoRenderer;
        }
      }

      if (videoRenderer == 'mediacodec_embed') {
        hAenable = true;
        hardwareDecoder = 'mediacodec';
        superResolutionMode = SuperResolutionMode.off;
      }

      videoController ??= VideoController(
        player,
        configuration: VideoControllerConfiguration(
          vo: videoRenderer,
          enableHardwareAcceleration: hAenable,
          enableAndroidSurfaceProducer: false,
          hwdec: hAenable ? hardwareDecoder : 'no',
          androidAttachSurfaceAfterVideoParameters: false,
        ),
      );
      player.setPlaylistMode(PlaylistMode.none);
      if (!isCurrentPlayer(player)) {
        return await _discardIfNotCurrent(candidate);
      }

      bool showPlayerError = GStorage.getSetting(SettingsKeys.showPlayerError);
      player.stream.error.listen((event) {
        if (isCurrentPlayer(player)) {
          final actionableMessage = PlayerErrorMapper.toActionableMessage(
            event,
            isBuffering: playerBuffering,
          );
          if (actionableMessage != null) {
            KazumiDialog.showToast(
                message: actionableMessage, showActionButton: true);
          } else if (showPlayerError) {
            KazumiDialog.showToast(
                message: '播放器内部错误 ${event.toString()} ${videoUrl()}',
                duration: const Duration(seconds: 5),
                showActionButton: true);
          }
        }
        KazumiLogger().e('PlayerController: Player intent error ${videoUrl()}',
            error: event);
      });

      if (superResolutionMode != SuperResolutionMode.off) {
        await setShader(superResolutionMode, player: player);
        if (!isCurrentPlayer(player)) {
          return await _discardIfNotCurrent(candidate);
        }
      }

      if (videoSourceFormat == VideoSourceFormat.hls) {
        await pp.setProperty('demuxer-lavf-format', 'hls');
        if (!isCurrentPlayer(player)) {
          return await _discardIfNotCurrent(candidate);
        }
      }

      final media = Media(videoUrl(),
          start: Duration(seconds: offset), httpHeaders: httpHeaders);
      _currentMedia = media;
      await player.open(media, play: autoPlay);
      if (!isCurrentPlayer(player)) {
        return await _discardIfNotCurrent(candidate);
      }

      if (cachePolicy.networkAutomatic) {
        KazumiDialog.showToast(message: '移动数据下已自动开启低内存模式，可在播放设置中改为始终关闭');
      }

      return player;
    } catch (error, stackTrace) {
      if (identical(_ownedPlayer, candidate)) {
        cachePolicy.stopWatching();
        _ownedPlayer = null;
        videoController = null;
        // 只拆自己的探针，别把已经开始的下一次开播的探针拆掉。
        _teardownStartupProbes();
      }
      await candidate.dispose();
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> setShader(SuperResolutionMode mode, {Player? player}) async {
    final currentPlayer = player ?? mediaPlayer;
    if (currentPlayer == null) return;
    try {
      var pp = currentPlayer.platform as NativePlayer;
      await pp.waitForPlayerInitialization;
      await pp.waitForVideoControllerInitializationIfAttached;
      if (!identical(mediaPlayer, currentPlayer)) {
        return;
      }
      switch (mode) {
        case SuperResolutionMode.efficiency:
          await pp.command([
            'change-list',
            'glsl-shaders',
            'set',
            buildShadersAbsolutePath(
              shaderAssetService.shadersDirectory.path,
              mpvAnime4KShadersLite,
            ),
          ]);
          break;
        case SuperResolutionMode.quality:
          await pp.command([
            'change-list',
            'glsl-shaders',
            'set',
            buildShadersAbsolutePath(
              shaderAssetService.shadersDirectory.path,
              mpvAnime4KShaders,
            ),
          ]);
          break;
        case SuperResolutionMode.off:
          await pp.command(['change-list', 'glsl-shaders', 'clr', '']);
          break;
      }
      superResolutionMode = mode;
    } catch (e) {
      KazumiLogger().w('PlayerController: failed to set shader', error: e);
    }
  }

  Future<void> setPlaybackSpeed(double playerSpeed) async {
    this.playerSpeed = playerSpeed;
    try {
      mediaPlayer!.setRate(playerSpeed);
    } catch (e) {
      KazumiLogger()
          .e('PlayerController: failed to set playback speed', error: e);
    }
  }

  Future<void> setVolume(double value) async {
    updateVolume(value);
    await syncVolumeToDevice(preciseVolume >= 0 ? preciseVolume : volume);
  }

  @action
  void updateVolume(double value) {
    value = value.clamp(0.0, 100.0);
    preciseVolume = value;
    if (volume.toInt() == value.toInt()) {
      return;
    }
    volume = value;
  }

  /// 外部来源（硬件键、系统面板等）变更音量时同步，并清除手势缓存
  @action
  void applyExternalVolume(double value) {
    value = value.clamp(0.0, 100.0);
    preciseVolume = -1;
    volume = value;
  }

  void invalidatePreciseVolume() {
    preciseVolume = -1;
  }

  Future<void> syncVolumeToDevice([double? value]) async {
    final vol = (value ?? volume).clamp(0.0, 100.0);
    try {
      if (isDesktop()) {
        await mediaPlayer!.setVolume(vol);
      } else {
        await FlutterVolumeController.setVolume(vol / 100);
      }
    } catch (_) {}
  }

  @action
  void syncPlaybackState() {
    final player = mediaPlayer;
    if (player == null) return;

    final PlayerState state;
    try {
      state = player.state;
    } catch (_) {
      return;
    }
    if (playing != state.playing) {
      playing = state.playing;
    }
    if (isBuffering != state.buffering) {
      isBuffering = state.buffering;
    }
    if (currentPosition != state.position) {
      currentPosition = state.position;
    }
    if (buffer != state.buffer) {
      buffer = state.buffer;
    }
    if (duration != state.duration) {
      duration = state.duration;
    }
    if (completed != state.completed) {
      completed = state.completed;
    }
  }

  Future<void> playOrPause({
    required Future<void> Function() pause,
    required Future<void> Function() play,
  }) async {
    if (playerPlaying) {
      await pause();
    } else {
      await play();
    }
  }

  Future<void> stop() async {
    cachePolicy.stopWatching();
    _teardownStartupProbes();
    videoReady = false;
    startupStalled = false;
    _hasVideoTrack = false;
    _softDecodeRetryTried = false;
    _currentMedia = null;
    final ownedPlayer = _ownedPlayer;
    _ownedPlayer = null;
    videoController = null;
    playing = false;
    loading = true;
    // media_kit stops playback as part of disposal before releasing native
    // resources. Debug subscriptions can be cancelled concurrently.
    await Future.wait([
      ownedPlayer?.dispose() ?? Future<void>.value(),
      _cancelDebugInfo(),
    ]);
  }

  Future<Uint8List?> screenshotPng() async {
    final player = mediaPlayer;
    if (player == null) {
      return null;
    }
    // Encode the captured frame natively; PlayerState dimensions may be stale.
    return player.safeScreenshot(format: 'image/png');
  }
}
