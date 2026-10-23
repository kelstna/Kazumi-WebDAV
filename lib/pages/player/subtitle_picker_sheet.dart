// SPDX-FileCopyrightText: Copyright (C) 2026 kelstna (AI-assisted modification, see NOTICE.md)
// SPDX-License-Identifier: GPL-3.0-only

import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:kazumi/bean/dialog/adaptive_bottom_sheet.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/services/player/subtitle/player_subtitle_controller.dart';
import 'package:kazumi/services/player/subtitle/subtitle_entry.dart';
import 'package:kazumi/services/storage/storage.dart';

/// 字幕选择面板：左侧选字幕，右侧放添加/延迟/兼容等操作。
Future<void> showSubtitlePickerSheet(
  BuildContext context, {
  required PlayerSubtitleController controller,
}) {
  return showAdaptiveBottomSheet<void>(
    context: context,
    maxHeightFactor: 0.92,
    builder: (context) => _SubtitlePickerSheet(controller: controller),
  );
}

class _SubtitlePickerSheet extends StatefulWidget {
  const _SubtitlePickerSheet({required this.controller});

  final PlayerSubtitleController controller;

  @override
  State<_SubtitlePickerSheet> createState() => _SubtitlePickerSheetState();
}

class _SubtitlePickerSheetState extends State<_SubtitlePickerSheet> {
  PlayerSubtitleController get controller => widget.controller;

  bool get _libassMode =>
      GStorage.getSetting(SettingsKeys.subtitleRenderMode) != 'simple';

  Future<void> _pickExternalFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const [
        'ass',
        'ssa',
        'srt',
        'vtt',
        'sub',
        'sup',
        'idx',
        'smi',
        'ttml',
        'dfxp',
      ],
      withData: false,
    );
    final picked = result?.files;
    final path = (picked == null || picked.isEmpty) ? null : picked.first.path;
    if (path == null || path.isEmpty) {
      return;
    }
    await controller.addExternalFile(path);
  }

  Future<void> _switchToLibass() async {
    await GStorage.putSetting(SettingsKeys.subtitleRenderMode, 'libass');
    if (!mounted) {
      return;
    }
    setState(() {});
    KazumiDialog.showToast(message: '已切换到特效字幕渲染，重新打开本集生效');
  }

  String _formatDelay(int milliseconds) {
    if (milliseconds == 0) {
      return '0.0s';
    }
    final seconds = milliseconds / 1000;
    return '${seconds > 0 ? '+' : ''}${seconds.toStringAsFixed(1)}s';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 8, 4),
              child: Row(
                children: [
                  Icon(Icons.subtitles_rounded, color: colors.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '字幕',
                      style: theme.textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                  if (controller.loading)
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  else
                    IconButton(
                      tooltip: '重新扫描外挂字幕',
                      onPressed: controller.refresh,
                      icon: const Icon(Icons.refresh_rounded),
                    ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final list = _buildSubtitleList(context);
                  final actions = _buildActionPanel(context);
                  if (constraints.maxWidth >= 560) {
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(flex: 5, child: list),
                        const VerticalDivider(width: 1),
                        SizedBox(width: 216, child: actions),
                      ],
                    );
                  }
                  // 窄屏（竖屏手机）退化为上下布局，保证还能用。
                  return Column(
                    children: [
                      Expanded(child: list),
                      const Divider(height: 1),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 190),
                        child: actions,
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildSubtitleList(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final embedded = controller.embeddedEntries;
    final external = controller.externalEntries;
    final selected = controller.selected;

    return ListView(
      padding: const EdgeInsets.only(bottom: 8),
      children: [
        ListTile(
          leading: Icon(
            selected == null
                ? Icons.radio_button_checked_rounded
                : Icons.radio_button_unchecked_rounded,
            color: selected == null ? colors.primary : colors.onSurfaceVariant,
          ),
          title: const Text('关闭字幕'),
          onTap: () => controller.select(null),
        ),
        if (embedded.isNotEmpty) ...[
          _SectionHeader(label: '内封字幕', count: embedded.length),
          for (final entry in embedded)
            _SubtitleTile(
              entry: entry,
              selected: selected?.id == entry.id,
              onTap: () => controller.select(entry),
            ),
        ],
        if (external.isNotEmpty) ...[
          _SectionHeader(label: '外挂字幕', count: external.length),
          for (final entry in external)
            _SubtitleTile(
              entry: entry,
              selected: selected?.id == entry.id,
              onTap: () => controller.select(entry),
            ),
        ],
        if (embedded.isEmpty && external.isEmpty && !controller.loading)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
            child: Text(
              '这个视频没有内封字幕，也没有在视频旁边/服务器上找到外挂字幕。\n'
              '可以用右边的「添加字幕文件」手动指定。',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: colors.onSurfaceVariant),
            ),
          ),
      ],
    );
  }

  Widget _buildActionPanel(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      children: [
        OutlinedButton.icon(
          onPressed: _pickExternalFile,
          icon: const Icon(Icons.folder_open_rounded, size: 18),
          label: const Text('添加字幕文件'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: controller.refresh,
          icon: const Icon(Icons.refresh_rounded, size: 18),
          label: const Text('重新扫描外挂'),
        ),
        const Divider(height: 20),
        Text(
          '字幕延迟 ${_formatDelay(controller.delayMs)}',
          style: theme.textTheme.labelLarge,
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => controller.nudgeDelay(-500),
                child: const Text('-0.5s'),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: OutlinedButton(
                onPressed: () => controller.nudgeDelay(500),
                child: const Text('+0.5s'),
              ),
            ),
          ],
        ),
        TextButton(
          onPressed: controller.delayMs == 0 ? null : () => controller.setDelay(0),
          child: const Text('重置延迟'),
        ),
        if (!_libassMode) ...[
          const Divider(height: 20),
          Text(
            '当前是「简洁文本」字幕模式：特效样式、特殊字体和 PGS 图形字幕都不会显示。',
            style: theme.textTheme.bodySmall?.copyWith(color: colors.error),
          ),
          const SizedBox(height: 6),
          FilledButton.tonal(
            onPressed: _switchToLibass,
            child: const Text('切换到特效渲染'),
          ),
        ] else if (controller.selected?.image ?? false) ...[
          const Divider(height: 20),
          Text(
            '图形字幕（PGS/VobSub）：由 libass 直接绘制，可以正常显示，但字体样式改不了。',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      child: Row(
        children: [
          Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$count',
            style: theme.textTheme.labelMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _SubtitleTile extends StatelessWidget {
  const _SubtitleTile({
    required this.entry,
    required this.selected,
    required this.onTap,
  });

  final SubtitleEntry entry;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ListTile(
      selected: selected,
      dense: true,
      leading: Icon(
        selected
            ? Icons.radio_button_checked_rounded
            : Icons.radio_button_unchecked_rounded,
        color: selected ? colors.primary : colors.onSurfaceVariant,
      ),
      title: Text(
        entry.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: entry.image ? const Text('图形字幕') : null,
      onTap: onTap,
    );
  }
}
