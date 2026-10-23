// SPDX-FileCopyrightText: Copyright (C) 2026 kelstna (AI-assisted modification, see NOTICE.md)
// SPDX-License-Identifier: GPL-3.0-only

import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:kazumi/pages/player/player_controller.dart';
import 'package:kazumi/services/storage/storage.dart';

class PlayerItemSurface extends StatefulWidget {
  const PlayerItemSurface({
    super.key,
    required this.playerController,
  });

  final PlayerController playerController;

  @override
  State<PlayerItemSurface> createState() => _PlayerItemSurfaceState();
}

class _PlayerItemSurfaceState extends State<PlayerItemSurface> {
  @override
  Widget build(BuildContext context) {
    final playerController = widget.playerController;
    return Observer(builder: (context) {
      if (playerController.playback.loading ||
          playerController.playback.videoController == null) {
        return Container(
          color: Colors.black,
          child: const Center(
            child: CircularProgressIndicator(),
          ),
        );
      }

      final aspectRatioMode = playerController.panel.aspectRatioMode;
      final video = Video(
        controller: playerController.playback.videoController!,
        controls: NoVideoControls,
        pauseUponEnteringBackgroundMode: false,
        fit: aspectRatioMode.fit,
        subtitleViewConfiguration: SubtitleViewConfiguration(
          // libass 模式下字幕由 mpv 画进视频帧（保留 ASS 特效、支持 PGS），
          // 这里必须关掉 Flutter 文本层，否则文字字幕会叠两层。
          visible:
              GStorage.getSetting(SettingsKeys.subtitleRenderMode) == 'simple',
          style: TextStyle(
            color: Colors.pink,
            fontSize: 48.0,
            background: Paint()..color = Colors.transparent,
            decoration: TextDecoration.none,
            fontWeight: FontWeight.bold,
            shadows: const [
              Shadow(
                offset: Offset(1.0, 1.0),
                blurRadius: 3.0,
                color: Color.fromARGB(255, 255, 255, 255),
              ),
              Shadow(
                offset: Offset(-1.0, -1.0),
                blurRadius: 3.0,
                color: Color.fromARGB(125, 255, 255, 255),
              ),
            ],
          ),
          textAlign: TextAlign.center,
          padding: const EdgeInsets.all(24.0),
        ),
      );

      final frameAspectRatio = aspectRatioMode.frameAspectRatio;
      if (frameAspectRatio == null) {
        return video;
      }
      return AspectRatio(
        aspectRatio: frameAspectRatio,
        child: video,
      );
    });
  }
}
