// SPDX-FileCopyrightText: Copyright (C) 2026 kelstna (AI-assisted modification, see NOTICE.md)
// SPDX-License-Identifier: GPL-3.0-only

import 'package:flutter/material.dart';
import 'package:kazumi/bean/dialog/adaptive_bottom_sheet.dart';
import 'package:kazumi/services/player/audio_track/player_audio_track_controller.dart';

/// 音轨选择面板。
Future<void> showAudioTrackPickerSheet(
  BuildContext context, {
  required PlayerAudioTrackController controller,
}) {
  return showAdaptiveBottomSheet<void>(
    context: context,
    maxHeightFactor: 0.6,
    builder: (context) => _AudioTrackPickerSheet(controller: controller),
  );
}

class _AudioTrackPickerSheet extends StatelessWidget {
  const _AudioTrackPickerSheet({required this.controller});

  final PlayerAudioTrackController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final entries = controller.entries;
        final selected = controller.selected;

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 8, 4),
              child: Row(
                children: [
                  Icon(Icons.audiotrack_rounded, color: colors.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '音轨',
                      style: theme.textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: 12),
                children: [
                  if (entries.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
                      child: Text(
                        '正在读取音轨，或这个视频只有一条音轨。',
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: colors.onSurfaceVariant),
                      ),
                    ),
                  for (final entry in entries)
                    ListTile(
                      dense: true,
                      selected: selected?.id == entry.id,
                      leading: Icon(
                        selected?.id == entry.id
                            ? Icons.radio_button_checked_rounded
                            : Icons.radio_button_unchecked_rounded,
                        color: selected?.id == entry.id
                            ? colors.primary
                            : colors.onSurfaceVariant,
                      ),
                      title: Text(
                        entry.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => controller.select(entry),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
