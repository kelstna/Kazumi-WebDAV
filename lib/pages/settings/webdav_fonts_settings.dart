// SPDX-FileCopyrightText: Copyright (C) 2026 kelstna (AI-assisted modification, see NOTICE.md)
// SPDX-License-Identifier: GPL-3.0-only

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/services/openlist/openlist_service.dart';
import 'package:kazumi/services/player/subtitle/font_index_job.dart';
import 'package:kazumi/services/player/subtitle/webdav_font_service.dart';
import 'package:kazumi/services/storage/storage.dart';

/// WebDAV 字体库设置：目录、索引、缓存占用。
///
/// 索引完全由 Kazumi 扫描 WebDAV 字体文件生成，不需要 WebDAV 侧放索引文件。
class WebDavFontsSettingsPage extends StatefulWidget {
  const WebDavFontsSettingsPage({super.key});

  @override
  State<WebDavFontsSettingsPage> createState() => _WebDavFontsSettingsPageState();
}

class _WebDavFontsSettingsPageState extends State<WebDavFontsSettingsPage> {
  late final TextEditingController _directory;
  WebDavFontIndex _index = WebDavFontIndex.empty;
  int _cacheBytes = 0;
  int _cacheCount = 0;
  bool _busy = false;
  int _progressDone = 0;
  int _progressTotal = 0;
  int _listingDirs = 0;
  int _listingFiles = 0;
  Timer? _progressTimer;

  @override
  void initState() {
    super.initState();
    _directory = TextEditingController(
      text: GStorage.getSetting<String>(SettingsKeys.webdavFontDirectory),
    );
    final job = FontIndexJob.instance;
    job.phase.addListener(_onJobChanged);
    job.done.addListener(_onJobChanged);
    job.total.addListener(_onJobChanged);
    job.directories.addListener(_onJobChanged);
    job.files.addListener(_onJobChanged);
    _syncJob();
    _reloadStatus();
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    final job = FontIndexJob.instance;
    job.phase.removeListener(_onJobChanged);
    job.done.removeListener(_onJobChanged);
    job.total.removeListener(_onJobChanged);
    job.directories.removeListener(_onJobChanged);
    job.files.removeListener(_onJobChanged);
    _directory.dispose();
    super.dispose();
  }

  void _syncJob() {
    final job = FontIndexJob.instance;
    _busy = job.phase.value == FontIndexPhase.listing ||
        job.phase.value == FontIndexPhase.reading;
    _progressDone = job.done.value;
    _progressTotal = job.total.value;
    _listingDirs = job.directories.value;
    _listingFiles = job.files.value;
  }

  void _onJobChanged() {
    if (!mounted) {
      return;
    }
    final phase = FontIndexJob.instance.phase.value;
    final finished = phase == FontIndexPhase.idle ||
        phase == FontIndexPhase.done ||
        phase == FontIndexPhase.error;
    if (finished) {
      _progressTimer?.cancel();
      final wasRunning = _busy;
      setState(_syncJob);
      if (wasRunning && !_busy) {
        _reloadStatus();
      }
      return;
    }
    // 进度最多每 300ms 刷一次，避免整页频繁重建。
    if (_progressTimer?.isActive ?? false) {
      return;
    }
    _progressTimer = Timer(const Duration(milliseconds: 300), () {
      if (mounted) {
        setState(_syncJob);
      }
    });
  }

  Future<void> _reloadStatus() async {
    final service = WebDavFontService.instance;
    final index = await service.loadIndex();
    final bytes = await service.cacheBytes();
    final count = await service.cacheCount();
    if (!mounted) {
      return;
    }
    setState(() {
      _index = index.directory == service.normalizedDirectory
          ? index
          : WebDavFontIndex.empty;
      _cacheBytes = bytes;
      _cacheCount = count;
    });
  }

  Future<void> _saveAndBuild() async {
    final directory = WebDavFontService.normalizeDirectory(_directory.text);
    if (directory.isEmpty) {
      KazumiDialog.showToast(message: '请填写 WebDAV 字体目录');
      return;
    }
    await GStorage.putSetting<String>(
        SettingsKeys.webdavFontDirectory, directory);
    await _buildIndex();
  }

  Future<void> _buildIndex() async {
    if (FontIndexJob.instance.isRunning) {
      return;
    }
    // 丢给 App 级任务：离开这个页面也会继续建索引。
    unawaited(FontIndexJob.instance.start());
  
  }

  Future<void> _forceRebuild() async {
    if (FontIndexJob.instance.isRunning) {
      return;
    }
    unawaited(FontIndexJob.instance.start(force: true));
  }

  void _showIndexPreview() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => _FontIndexPreview(faces: _index.faces),
    );
  }

  Future<void> _clearCache() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除字体缓存？'),
        content: const Text('自动下载的字体将被删除，下次播放会重新下载。手动导入的字体不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    await WebDavFontService.instance.clearCache();
    if (mounted) {
      KazumiDialog.showToast(message: '字体缓存已清除');
      await _reloadStatus();
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final configured = OpenListService.instance.baseUrl.isNotEmpty;
    final builtAt = _index.builtAt;
    return SettingsDetailScaffold(
      title: const Text('WebDAV 字体库'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          Text(
            'Kazumi 会扫描这个 WebDAV 目录里的 .ttf/.otf/.ttc，读取字体名建立本地索引；'
            '播放外挂 ASS/SSA 时按「手动导入 → Download/KazumiFonts → WebDAV」的顺序找字体，'
            '都没有才下载。WebDAV 上不需要放索引文件。',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          if (!configured)
            Card(
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  '还没有配置 WebDAV 服务地址。请先在「我的 → 规则设置 → WebDAV 片库」里填好地址和账号。',
                  style: TextStyle(color: theme.colorScheme.onErrorContainer),
                ),
              ),
            ),
          const SizedBox(height: 8),
          TextField(
            controller: _directory,
            enabled: !_busy,
            decoration: const InputDecoration(
              labelText: '字体目录（WebDAV 路径）',
              hintText: '/dav/Fonts',
              helperText: '会递归扫描子目录里的字体文件',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _busy ? null : _saveAndBuild,
            icon: const Icon(Icons.manage_search_rounded),
            label: const Text('保存并建立索引'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _busy ? null : _buildIndex,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('用当前目录重建索引'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _busy ? null : _forceRebuild,
            icon: const Icon(Icons.cleaning_services_rounded),
            label: const Text('强制重建（忽略缓存）'),
          ),
          if (_busy) ...[
            const SizedBox(height: 16),
            LinearProgressIndicator(
              value: _progressTotal > 0
                  ? (_progressDone / _progressTotal).clamp(0.0, 1.0)
                  : null,
            ),
            const SizedBox(height: 6),
            Text(
              _progressTotal > 0
                  ? '正在读取字体信息 $_progressDone / $_progressTotal'
                  : '正在扫描目录… 已扫描 $_listingDirs 个目录 / $_listingFiles 个字体',
              style: theme.textTheme.bodySmall,
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: FontIndexJob.instance.cancel,
                child: const Text('取消'),
              ),
            ),
          ],
          if (!_busy && FontIndexJob.instance.message.value.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              FontIndexJob.instance.message.value,
              style: theme.textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 24),
          Card(
            child: ListTile(
              leading: const Icon(Icons.format_list_bulleted_rounded),
              title: const Text('字体索引'),
              subtitle: Text(_index.faces.isEmpty
                  ? '还没有索引'
                  : '${_index.faces.length} 个字体'
                      '${builtAt == null ? '' : ' · ${builtAt.toString().substring(0, 16)}'}'),
              trailing: _index.faces.isEmpty
                  ? null
                  : const Icon(Icons.chevron_right_rounded),
              onTap: _index.faces.isEmpty ? null : _showIndexPreview,
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.sd_storage_rounded),
              title: const Text('字体缓存'),
              subtitle: Text(
                '$_cacheCount 个字体 · ${_formatBytes(_cacheBytes)} / '
                '${_formatBytes(WebDavFontService.cacheLimitBytes)}',
              ),
              trailing: TextButton(
                onPressed: _busy || _cacheCount == 0 ? null : _clearCache,
                child: const Text('清除'),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '缓存统计 App 字体目录里的字体（手动导入 + 自动下载）；Download/KazumiFonts '
            '直接以软链接使用，不复制、不计入缓存。超过 200MB 时自动淘汰最早下载的字体，'
            '手动导入的字体不会被清理。',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// 字体索引预览：搜索 family / 文件名 / 别名。
class _FontIndexPreview extends StatefulWidget {
  const _FontIndexPreview({required this.faces});

  final List<WebDavFontFace> faces;

  @override
  State<_FontIndexPreview> createState() => _FontIndexPreviewState();
}

class _FontIndexPreviewState extends State<_FontIndexPreview> {
  String _query = '';

  String _formatBytes(int bytes) {
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  List<WebDavFontFace> get _filtered {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) {
      return widget.faces;
    }
    return widget.faces
        .where((face) =>
            face.family.toLowerCase().contains(query) ||
            face.file.toLowerCase().contains(query) ||
            face.aliases.any((alias) => alias.toLowerCase().contains(query)))
        .toList(growable: false);
  }

  void _showDetail(WebDavFontFace face) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(face.family),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('文件：${face.file}'),
              const SizedBox(height: 4),
              Text('大小：${_formatBytes(face.size)}'),
              const SizedBox(height: 12),
              const Text('别名（字幕里可能用的名字）：'),
              const SizedBox(height: 4),
              for (final alias in face.aliases) Text('· $alias'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filtered = _filtered;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.82,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Row(
                children: [
                  Text('字体索引', style: theme.textTheme.titleLarge),
                  const Spacer(),
                  Text(
                    '${widget.faces.length} 个',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: TextField(
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search_rounded),
                  hintText: '搜索字体名 / 文件名 / 别名',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (value) => setState(() => _query = value),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: filtered.isEmpty
                  ? const Center(child: Text('没有匹配的字体'))
                  : ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        final face = filtered[index];
                        return ListTile(
                          title: Text(face.family),
                          subtitle: Text(
                            '${face.file} · ${_formatBytes(face.size)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => _showDetail(face),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
