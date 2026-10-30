// SPDX-FileCopyrightText: Copyright (C) 2026 kelstna (AI-assisted modification, see NOTICE.md)
// SPDX-License-Identifier: GPL-3.0-only

import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/bean/settings/settings_dropdown_tile.dart';
import 'package:kazumi/pages/player/controller/player_aspect_ratio.dart';
import 'package:kazumi/pages/settings/low_memory_mode_settings.dart';
import 'package:kazumi/services/player/subtitle/subtitle_font_service.dart';
import 'package:kazumi/services/player/track_memory.dart';
import 'package:kazumi/utils/constants.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/player/pip_utils.dart';
import 'package:kazumi/bean/settings/settings_list.dart';
import 'package:kazumi/utils/device.dart';

class PlayerSettingsPage extends StatefulWidget {
  const PlayerSettingsPage({super.key});

  @override
  State<PlayerSettingsPage> createState() => _PlayerSettingsPageState();
}

class _PlayerSettingsPageState extends State<PlayerSettingsPage> {
  static const double _minPlayerControllerLayerDisappearSeconds = 1;
  static const double _maxPlayerControllerLayerDisappearSeconds = 10;
  static const int _playerControllerLayerDisappearDivisions = 18;

  late double defaultPlaySpeed;
  late double defaultShortcutForwardPlaySpeed;
  late PlayerAspectRatio defaultAspectRatioMode;
  late bool hAenable;
  late bool androidEnableOpenSLES;
  late bool androidAutoEnterPIP;
  late bool playResume;
  late bool showPlayerError;
  late bool privateMode;
  late bool playerDebugMode;
  late bool playerDisableAnimations;
  late bool forceAdBlocker;
  late bool autoPlayNext;
  late bool backgroundPlayback;
  late bool brightnessVolumeGesture;
  late bool autoSelectSubtitle;
  late String subtitleRenderMode;
  late String autoSelectAudioTrack;
  late bool rememberTrackSelection;
  late int playerButtonSkipTime;
  late int playerArrowKeySkipTime;
  late int playerLogLevel;
  late int playerControllerLayerDisappearTime;

  @override
  void initState() {
    super.initState();
    _loadSettingsFromStorage();
  }

  void _loadSettingsFromStorage() {
    defaultPlaySpeed =
        GStorage.getSetting<double>(SettingsKeys.defaultPlaySpeed);
    defaultShortcutForwardPlaySpeed = GStorage.getSetting<double>(
        SettingsKeys.defaultShortcutForwardPlaySpeed);
    defaultAspectRatioMode = PlayerAspectRatio.fromStorageValue(
      GStorage.getSetting<int>(SettingsKeys.defaultAspectRatioType),
    );
    hAenable = GStorage.getSetting<bool>(SettingsKeys.hAenable);
    androidEnableOpenSLES =
        GStorage.getSetting<bool>(SettingsKeys.androidEnableOpenSLES);
    androidAutoEnterPIP =
        GStorage.getSetting<bool>(SettingsKeys.androidAutoEnterPIP);
    playResume = GStorage.getSetting<bool>(SettingsKeys.playResume);
    privateMode = GStorage.getSetting<bool>(SettingsKeys.privateMode);
    showPlayerError = GStorage.getSetting<bool>(SettingsKeys.showPlayerError);
    playerDebugMode = GStorage.getSetting<bool>(SettingsKeys.playerDebugMode);
    autoPlayNext = GStorage.getSetting<bool>(SettingsKeys.autoPlayNext);
    backgroundPlayback =
        GStorage.getSetting<bool>(SettingsKeys.backgroundPlayback);
    playerDisableAnimations =
        GStorage.getSetting<bool>(SettingsKeys.playerDisableAnimations);
    forceAdBlocker = GStorage.getSetting<bool>(SettingsKeys.forceAdBlocker);
    playerLogLevel = GStorage.getSetting<int>(SettingsKeys.playerLogLevel);

    brightnessVolumeGesture =
        GStorage.getSetting<bool>(SettingsKeys.brightnessVolumeGesture);
    autoSelectSubtitle =
        GStorage.getSetting<bool>(SettingsKeys.autoSelectSubtitle);
    subtitleRenderMode =
        GStorage.getSetting<String>(SettingsKeys.subtitleRenderMode);
    autoSelectAudioTrack =
        GStorage.getSetting<String>(SettingsKeys.autoSelectAudioTrack);
    rememberTrackSelection =
        GStorage.getSetting<bool>(SettingsKeys.rememberTrackSelection);

    playerButtonSkipTime =
        GStorage.getSetting<int>(SettingsKeys.buttonSkipTime);
    playerArrowKeySkipTime =
        GStorage.getSetting<int>(SettingsKeys.arrowKeySkipTime);

    playerControllerLayerDisappearTime = GStorage.getSetting<int>(
        SettingsKeys.playerControllerLayerDisappearTime);
  }

  Future<void> resetPlayerSettings() async {
    final bool shouldReset = await KazumiDialog.show<bool>(
          builder: (context) => AlertDialog(
            title: const Text('恢复默认播放设置'),
            content: const Text('播放设置、硬件解码器、视频渲染器和超分辨率设置将恢复为默认值。'),
            actions: [
              TextButton(
                onPressed: () => KazumiDialog.dismiss(popWith: false),
                child: Text('取消'),
              ),
              TextButton(
                onPressed: () => KazumiDialog.dismiss(popWith: true),
                child: Text('恢复默认'),
              ),
            ],
          ),
        ) ??
        false;
    if (!shouldReset) return;

    await GStorage.resetPlayerSettings();
    if (Platform.isAndroid) {
      await PipUtils.setAndroidAutoEnterPIPEnabled(false);
    }
    if (!mounted) return;
    setState(_loadSettingsFromStorage);
    KazumiDialog.showToast(message: '已恢复默认播放设置');
  }

  void updateDefaultPlaySpeed(double speed) {
    GStorage.putSetting<double>(SettingsKeys.defaultPlaySpeed, speed);
    setState(() {
      defaultPlaySpeed = speed;
    });
  }

  void updateDefaultShortcutForwardPlaySpeed(double speed) {
    GStorage.putSetting<double>(
        SettingsKeys.defaultShortcutForwardPlaySpeed, speed);
    setState(() {
      defaultShortcutForwardPlaySpeed = speed;
    });
  }

  void updatePlayerLogLevel(int level) {
    GStorage.putSetting<int>(SettingsKeys.playerLogLevel, level);
    setState(() {
      playerLogLevel = level;
    });
  }

  void updateDefaultAspectRatioMode(PlayerAspectRatio mode) {
    GStorage.putSetting<int>(
      SettingsKeys.defaultAspectRatioType,
      mode.storageValue,
    );
    setState(() {
      defaultAspectRatioMode = mode;
    });
  }

  Future<void> updateButtonSkipTime() async {
    final int? newButtonSkipTime = await _showSkipTimeChangeDialog(
        title: '顶部按钮快进时长', initialValue: playerButtonSkipTime.toString());

    if (newButtonSkipTime != null &&
        newButtonSkipTime != playerButtonSkipTime) {
      GStorage.putSetting<int>(SettingsKeys.buttonSkipTime, newButtonSkipTime);
      setState(() {
        playerButtonSkipTime = newButtonSkipTime;
      });
    }
  }

  Future<int?> _showSkipTimeChangeDialog(
      {required String title, required String initialValue}) async {
    return KazumiDialog.show<int>(builder: (context) {
      String input = "";
      return AlertDialog(
        title: Text(title),
        content: StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) {
          return TextField(
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
            ],
            decoration: InputDecoration(
              floatingLabelBehavior: FloatingLabelBehavior.never,
              labelText: initialValue,
            ),
            onChanged: (value) {
              input = value;
            },
          );
        }),
        actions: <Widget>[
          TextButton(
            onPressed: () => KazumiDialog.dismiss(),
            child: Text(
              '取消',
              style: TextStyle(color: Theme.of(context).colorScheme.outline),
            ),
          ),
          TextButton(
            onPressed: () async {
              final int? newValue = int.tryParse(input);

              if (newValue == null) {
                KazumiDialog.showToast(message: '请输入数字');
                return;
              }

              if (newValue <= 0) {
                KazumiDialog.showToast(message: '请输入大于0的数字');
                return;
              }
              KazumiDialog.dismiss(popWith: newValue);
            },
            child: const Text('确定'),
          ),
        ],
      );
    });
  }

  Future<void> _importFonts() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: const ['ttf', 'otf', 'ttc'],
      withData: false,
    );
    final paths = (result?.files ?? const [])
        .map((file) => file.path)
        .whereType<String>()
        .toList(growable: false);
    if (paths.isEmpty) {
      return;
    }
    final service = SubtitleFontService();
    await service.prepare();
    final count = await service.importFiles(paths);
    if (!mounted) {
      return;
    }
    KazumiDialog.showToast(message: '已导入 $count 个字体，重新打开视频生效');
  }

  double get playerControllerLayerDisappearSeconds =>
      (playerControllerLayerDisappearTime / Duration.millisecondsPerSecond)
          .clamp(_minPlayerControllerLayerDisappearSeconds,
              _maxPlayerControllerLayerDisappearSeconds)
          .toDouble();

  String formatPlayerControllerLayerDisappearSeconds(double seconds) {
    if (seconds == seconds.roundToDouble()) {
      return '${seconds.toInt()} 秒';
    }
    return '${seconds.toStringAsFixed(1)} 秒';
  }

  void updatePlayerControllerLayerDisappearSeconds(double seconds) {
    final int newDisappearTime =
        (seconds * Duration.millisecondsPerSecond).round();
    if (newDisappearTime == playerControllerLayerDisappearTime) {
      return;
    }
    GStorage.putSetting<int>(
        SettingsKeys.playerControllerLayerDisappearTime, newDisappearTime);
    setState(() {
      playerControllerLayerDisappearTime = newDisappearTime;
    });
  }

  @override
  Widget build(BuildContext context) {
    return SettingsDetailScaffold(
      title: const Text('播放设置'),
      body: SettingsList(
        sections: [
          SettingsSection(
            title: Text('解码与渲染'),
            tiles: [
              SettingsTile.switchTile(
                leading: Icons.memory_rounded,
                onToggle: (value) async {
                  hAenable = value ?? !hAenable;
                  await GStorage.putSetting<bool>(
                      SettingsKeys.hAenable, hAenable);
                  setState(() {});
                },
                title: Text('硬件解码'),
                initialValue: hAenable,
              ),
              SettingsTile(
                leading: Icons.developer_board_rounded,
                onPressed: (_) async {
                  await context.pushNamed('/settings/player/decoder');
                },
                title: Text('硬件解码器'),
                description: Text('仅在硬件解码启用时生效'),
              ),
              if (Platform.isAndroid) ...[
                SettingsTile(
                  leading: Icons.tv_rounded,
                  onPressed: (_) async {
                    await context.pushNamed('/settings/player/renderer');
                  },
                  title: Text('视频渲染器'),
                  description: Text('选择视频输出方式'),
                ),
              ],
              const LowMemoryModeSettingsTile(),
              if (Platform.isAndroid) ...[
                SettingsTile.switchTile(
                  leading: Icons.graphic_eq_rounded,
                  onToggle: (value) async {
                    androidEnableOpenSLES = value ?? !androidEnableOpenSLES;
                    await GStorage.putSetting<bool>(
                        SettingsKeys.androidEnableOpenSLES,
                        androidEnableOpenSLES);
                    setState(() {});
                  },
                  title: Text('低延迟音频'),
                  description: Text('启用OpenSLES音频输出以降低延时'),
                  initialValue: androidEnableOpenSLES,
                ),
              ],
              SettingsTile(
                leading: Icons.auto_awesome_rounded,
                onPressed: (_) async {
                  context.pushNamed('/settings/player/super');
                },
                title: Text('超分辨率'),
              ),
            ],
          ),
          SettingsSection(
            title: Text('字幕与音轨'),
            tiles: [
              SettingsTile.switchTile(
                leading: Icons.translate_rounded,
                onToggle: (value) async {
                  autoSelectSubtitle = value ?? !autoSelectSubtitle;
                  await GStorage.putSetting<bool>(
                      SettingsKeys.autoSelectSubtitle, autoSelectSubtitle);
                  setState(() {});
                },
                title: Text('自动选择中文字幕'),
                description: Text(
                    '开播时优先用外挂字幕：简体 → 繁体；候选里没有中文就按名称取第一条外挂，不再退回内封'),
                initialValue: autoSelectSubtitle,
              ),
              SettingsDropdownTile<String>(
                leading: Icons.subtitles_rounded,
                title: const Text('字幕渲染方式'),
                description: const Text('特效渲染保留 ASS 样式/字体并支持 PGS 图形字幕；简洁文本是兼容兜底'),
                value: subtitleRenderMode,
                options: const {
                  'libass': '特效渲染（推荐）',
                  'simple': '简洁文本（兼容）',
                },
                onChanged: (value) async {
                  subtitleRenderMode = value;
                  await GStorage.putSetting<String>(
                      SettingsKeys.subtitleRenderMode, value);
                  if (mounted) setState(() {});
                  KazumiDialog.showToast(message: '重新打开视频后生效');
                },
              ),
              SettingsDropdownTile<String>(
                leading: Icons.audiotrack_rounded,
                title: const Text('自动选择音轨'),
                description: const Text(
                    '「按作品语言」用 bgm 元信息判断原声语言（真人影视）或日语/国产（动画），取不到再看文件名标签'),
                value: autoSelectAudioTrack,
                options: const {
                  'meta': '按作品语言（推荐）',
                  'auto': '跟随文件默认',
                  'jpn': '日语优先',
                  'chi': '中文优先',
                  'eng': '英语优先',
                },
                onChanged: (value) async {
                  autoSelectAudioTrack = value;
                  await GStorage.putSetting<String>(
                      SettingsKeys.autoSelectAudioTrack, value);
                  if (mounted) setState(() {});
                  KazumiDialog.showToast(message: '下一集开始生效');
                },
              ),
              SettingsTile.switchTile(
                leading: Icons.bookmark_added_rounded,
                onToggle: (value) async {
                  rememberTrackSelection = value ?? !rememberTrackSelection;
                  await GStorage.putSetting<bool>(
                      SettingsKeys.rememberTrackSelection,
                      rememberTrackSelection);
                  if (!rememberTrackSelection) {
                    await TrackMemoryStore.instance.clearAll();
                  }
                  if (mounted) setState(() {});
                },
                title: Text('记住每集的字幕/音轨选择'),
                description: Text('只记当前这一个视频；换集不沿用。关闭会清空已记住的选择'),
                initialValue: rememberTrackSelection,
              ),
              SettingsTile(
                leading: Icons.font_download_rounded,
                title: const Text('导入字幕字体'),
                description: const Text(
                    '支持 .ttf/.otf/.ttc；也可把字体放进 Download/KazumiFonts 自动扫描。'
                    '服务器字体库会按字幕引用的字体名自动补齐'),
                onPressed: (_) => _importFonts(),
              ),
              SettingsTile(
                leading: Icons.cloud_download_rounded,
                title: const Text('WebDAV 字体库'),
                description: const Text(
                    '从 WebDAV 字体目录自动补齐外挂字幕缺的字体；'
                    '索引由 Kazumi 扫描字体文件生成，缓存上限 200MB'),
                onPressed: (context) =>
                    context.pushNamed('/settings/player/fonts'),
              ),
            ],
          ),
          SettingsSection(
            title: Text('播放行为'),
            tiles: [
              SettingsTile.switchTile(
                leading: Icons.headphones_rounded,
                onToggle: (value) async {
                  backgroundPlayback = value ?? !backgroundPlayback;
                  await GStorage.putSetting<bool>(
                      SettingsKeys.backgroundPlayback, backgroundPlayback);
                  setState(() {});
                },
                title: Text('后台播放'),
                description: Text('应用退到后台或熄屏时继续播放音频'),
                initialValue: backgroundPlayback,
              ),
              SettingsTile.switchTile(
                leading: Icons.history_rounded,
                onToggle: (value) async {
                  playResume = value ?? !playResume;
                  await GStorage.putSetting<bool>(
                      SettingsKeys.playResume, playResume);
                  setState(() {});
                },
                title: Text('自动跳转'),
                description: Text('跳转到上次播放位置'),
                initialValue: playResume,
              ),
              SettingsTile.switchTile(
                leading: Icons.playlist_play_rounded,
                onToggle: (value) async {
                  autoPlayNext = value ?? !autoPlayNext;
                  await GStorage.putSetting<bool>(
                      SettingsKeys.autoPlayNext, autoPlayNext);
                  setState(() {});
                },
                title: Text('自动连播'),
                description: Text('当前视频播放完毕后自动播放下一集'),
                initialValue: autoPlayNext,
              ),
              if (Platform.isAndroid)
                SettingsTile.switchTile(
                  leading: Icons.picture_in_picture_alt_rounded,
                  onToggle: (value) async {
                    androidAutoEnterPIP = value ?? !androidAutoEnterPIP;
                    await GStorage.putSetting<bool>(
                        SettingsKeys.androidAutoEnterPIP, androidAutoEnterPIP);
                    await PipUtils.setAndroidAutoEnterPIPEnabled(
                        androidAutoEnterPIP);
                    setState(() {});
                  },
                  title: Text('自动进入画中画'),
                  description: Text('切到后台时，自动进入画中画'),
                  initialValue: androidAutoEnterPIP,
                ),
              SettingsTile.switchTile(
                leading: Icons.block_rounded,
                onToggle: (value) async {
                  forceAdBlocker = value ?? !forceAdBlocker;
                  await GStorage.putSetting<bool>(
                      SettingsKeys.forceAdBlocker, forceAdBlocker);
                  setState(() {});
                },
                title: Text('广告过滤'),
                description: Text('强制启用HLS广告过滤，忽略规则设置'),
                initialValue: forceAdBlocker,
              ),
              SettingsTile.switchTile(
                leading: Icons.animation_rounded,
                onToggle: (value) async {
                  playerDisableAnimations = value ?? !playerDisableAnimations;
                  await GStorage.putSetting<bool>(
                      SettingsKeys.playerDisableAnimations,
                      playerDisableAnimations);
                  setState(() {});
                },
                title: Text('禁用动画'),
                description: Text('禁用播放器内的过渡动画'),
                initialValue: playerDisableAnimations,
              ),
              if (!isDesktop())
                SettingsTile.switchTile(
                  leading: Icons.swipe_vertical_rounded,
                  onToggle: (value) async {
                    brightnessVolumeGesture = value ?? !brightnessVolumeGesture;
                    await GStorage.putSetting<bool>(
                        SettingsKeys.brightnessVolumeGesture,
                        brightnessVolumeGesture);
                    setState(() {});
                  },
                  title: Text('滑动手势'),
                  description: Text('竖向滑动调节音量和亮度'),
                  initialValue: brightnessVolumeGesture,
                ),
              SettingsTile.switchTile(
                leading: Icons.visibility_off_rounded,
                onToggle: (value) async {
                  privateMode = value ?? !privateMode;
                  await GStorage.putSetting<bool>(
                      SettingsKeys.privateMode, privateMode);
                  setState(() {});
                },
                title: Text('隐身模式'),
                description: Text('不保留观看记录'),
                initialValue: privateMode,
              ),
            ],
          ),
          SettingsSection(
            title: Text('诊断'),
            tiles: [
              SettingsTile.switchTile(
                leading: Icons.error_outline_rounded,
                onToggle: (value) async {
                  showPlayerError = value ?? !showPlayerError;
                  await GStorage.putSetting<bool>(
                      SettingsKeys.showPlayerError, showPlayerError);
                  setState(() {});
                },
                title: Text('错误提示'),
                description: Text('显示播放器内部错误提示'),
                initialValue: showPlayerError,
              ),
              SettingsTile.switchTile(
                leading: Icons.bug_report_rounded,
                onToggle: (value) async {
                  playerDebugMode = value ?? !playerDebugMode;
                  await GStorage.putSetting<bool>(
                      SettingsKeys.playerDebugMode, playerDebugMode);
                  setState(() {});
                },
                title: Text('调试模式'),
                description: Text('记录播放器内部日志'),
                initialValue: playerDebugMode,
              ),
              SettingsDropdownTile<int>(
                leading: Icons.receipt_long_rounded,
                title: const Text('日志等级'),
                description: const Text('播放器内部日志等级'),
                value: playerLogLevel,
                options: playerLogLevelMap,
                fallbackLabel: '???',
                onChanged: updatePlayerLogLevel,
              ),
            ],
          ),
          SettingsSection(
            title: Text('播放参数'),
            tiles: [
              SettingsSliderTile(
                leading: Icons.speed_rounded,
                title: Text('默认倍速'),
                value: defaultPlaySpeed,
                min: 0.25,
                max: 3,
                divisions: 11,
                valueLabel: '${defaultPlaySpeed}x',
                onChanged: (value) => updateDefaultPlaySpeed(
                    double.parse(value.toStringAsFixed(2))),
              ),
              SettingsSliderTile(
                leading: Icons.fast_forward_rounded,
                title: Text('长按倍速'),
                description: Text('长按屏幕或按住方向键时的倍速'),
                value: defaultShortcutForwardPlaySpeed,
                min: 1.25,
                max: 3,
                divisions: 7,
                valueLabel: '${defaultShortcutForwardPlaySpeed}x',
                onChanged: (value) => updateDefaultShortcutForwardPlaySpeed(
                    double.parse(value.toStringAsFixed(2))),
              ),
              SettingsSliderTile(
                leading: Icons.swap_horiz_rounded,
                title: Text('方向键跳转'),
                description: Text('左右方向键的快进/快退秒数'),
                value: playerArrowKeySkipTime.toDouble(),
                min: 0,
                max: 15,
                divisions: 15,
                valueLabel: '$playerArrowKeySkipTime 秒',
                onChanged: (value) {
                  final newArrowKeySkipTime = value.toInt();
                  if (newArrowKeySkipTime == playerArrowKeySkipTime) {
                    return;
                  }
                  GStorage.putSetting<int>(
                      SettingsKeys.arrowKeySkipTime, newArrowKeySkipTime);
                  setState(() {
                    playerArrowKeySkipTime = newArrowKeySkipTime;
                  });
                },
              ),
              SettingsTile(
                leading: Icons.skip_next_rounded,
                onPressed: (_) async {
                  await updateButtonSkipTime();
                },
                title: Text('跳过时长'),
                description: Text('顶栏跳过按钮的秒数'),
                value: Text('$playerButtonSkipTime 秒'),
              ),
              SettingsSliderTile(
                leading: Icons.timer_rounded,
                title: Text('控制栏消失时间'),
                description: Text('播放控制器自动隐藏前的停留时长'),
                value: playerControllerLayerDisappearSeconds,
                min: _minPlayerControllerLayerDisappearSeconds,
                max: _maxPlayerControllerLayerDisappearSeconds,
                divisions: _playerControllerLayerDisappearDivisions,
                valueLabel: formatPlayerControllerLayerDisappearSeconds(
                    playerControllerLayerDisappearSeconds),
                onChanged: updatePlayerControllerLayerDisappearSeconds,
              ),
              SettingsDropdownTile<PlayerAspectRatio>(
                leading: Icons.aspect_ratio_rounded,
                title: const Text('默认视频比例'),
                value: defaultAspectRatioMode,
                options: {
                  for (final mode in PlayerAspectRatio.values) mode: mode.label,
                },
                onChanged: updateDefaultAspectRatioMode,
              ),
            ],
          ),
          SettingsSection(
            tiles: [
              SettingsTile(
                leading: Icons.settings_backup_restore_rounded,
                onPressed: (_) => resetPlayerSettings(),
                title: Text('恢复默认设置'),
                description: Text('将播放相关设置恢复为默认值'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
