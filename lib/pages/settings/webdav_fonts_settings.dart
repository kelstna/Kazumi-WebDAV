// SPDX-FileCopyrightText: Copyright (C) 2026 kelstna (AI-assisted modification, see NOTICE.md)
// SPDX-License-Identifier: GPL-3.0-only

import 'package:flutter/material.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/services/openlist/openlist_service.dart';
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

  @override
  void initState() {
    super.initState();
    _directory = TextEditingController(
      text: GStorage.getSetting<String>(SettingsKeys.webdavFontDirectory),
    );
    _reloadStatus();
  }

  @override
  void dispose() {
    _directory.dispose();
    super.dispose();
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
      _index = index.directory == service.fontDirectory
          ? index
          : WebDavFontIndex.empty;
      _cacheBytes = bytes;
      _cacheCount = count;
    });
  }

  Future<void> _saveAndBuild() async {
    final directory = _directory.text.trim();
    if (directory.isEmpty) {
      KazumiDialog.showToast(message: '请填写 WebDAV 字体目录');
      return;
    }
    await GStorage.putSetting<String>(
        SettingsKeys.webdavFontDirectory, directory);
    await _buildIndex();
  }

  Future<void> _buildIndex() async {
    if (_busy) {
      return;
    }
    setState(() {
      _busy = true;
      _progressDone = 0;
      _progressTotal = 0;
    });
    try {
      final count = await WebDavFontService.instance.buildIndex(
        onProgress: (done, total) {
          if (!mounted) {
            return;
          }
          setState(() {
            _progressDone = done;
            _progressTotal = total;
          });
        },
      );
      if (mounted) {
        KazumiDialog.showToast(message: '索引完成，共 $count 个字体');
      }
    } catch (error) {
      if (mounted) {
        KazumiDialog.showToast(message: '建立索引失败：$error');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        await _reloadStatus();
      }
    }
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
            '播放外挂 ASS 时缺哪个字体就下载哪个，不需要在 WebDAV 上放索引文件。',
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
              helperText: '字体文件直接放在这个目录里，支持子目录外的平铺文件',
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
                  : '正在列出字体目录…',
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
            '缓存只统计自动下载的字体；手动导入和 Download/KazumiFonts 里的字体不会被清理。'
            '超过 200MB 时按最久未使用自动淘汰。',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
