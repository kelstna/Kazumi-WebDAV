// SPDX-FileCopyrightText: Copyright (C) 2026 kelstna (AI-assisted modification, see NOTICE.md)
// SPDX-License-Identifier: GPL-3.0-only

import 'package:flutter/material.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/services/openlist/openlist_service.dart';
import 'package:kazumi/services/storage/storage.dart';

/// WebDAV 片库连接设置。
///
/// 任何标准 WebDAV 服务都能用（OpenList / NAS / alist / Nextcloud 等）。
/// 作为 `/settings/plugin/webdav` 子路由挂在规则模块下，
/// 返回时和「播放设置 → 解码器」一样回到规则管理。
class WebDavSettingsPage extends StatefulWidget {
  const WebDavSettingsPage({super.key});

  @override
  State<WebDavSettingsPage> createState() => _WebDavSettingsPageState();
}

class _WebDavSettingsPageState extends State<WebDavSettingsPage> {
  late final TextEditingController _baseUrl;
  late final TextEditingController _rootPath;
  late final TextEditingController _user;
  late final TextEditingController _password;
  late final TextEditingController _ignoredDirs;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _baseUrl = TextEditingController(
        text: GStorage.getSetting<String>(SettingsKeys.openListBaseUrl));
    _rootPath = TextEditingController(
        text: GStorage.getSetting<String>(SettingsKeys.openListRootPath));
    _user = TextEditingController(
        text: GStorage.getSetting<String>(SettingsKeys.openListUser));
    _password = TextEditingController(
        text: GStorage.getSetting<String>(SettingsKeys.openListPassword));
    _ignoredDirs = TextEditingController(
        text: GStorage.getSetting<String>(SettingsKeys.openListIgnoredDirs));
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _rootPath.dispose();
    _user.dispose();
    _password.dispose();
    _ignoredDirs.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await GStorage.putSetting<String>(
        SettingsKeys.openListBaseUrl, _baseUrl.text.trim());
    await GStorage.putSetting<String>(
        SettingsKeys.openListRootPath, _rootPath.text.trim());
    await GStorage.putSetting<String>(
        SettingsKeys.openListUser, _user.text.trim());
    await GStorage.putSetting<String>(
        SettingsKeys.openListPassword, _password.text);
    await GStorage.putSetting<String>(
        SettingsKeys.openListIgnoredDirs, _ignoredDirs.text.trim());
    OpenListService.instance.invalidateFolderIndex();
  }

  Future<void> _test() async {
    await _save();
    if (!mounted) {
      return;
    }
    setState(() => _busy = true);
    try {
      final entries = await OpenListService.instance.list(
        OpenListService.instance.rootPath,
      );
      if (mounted) {
        KazumiDialog.showToast(message: '连接成功，根目录有 ${entries.length} 项');
      }
    } catch (error) {
      if (mounted) {
        KazumiDialog.showToast(message: '连接失败：$error');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SettingsDetailScaffold(
      title: const Text('WebDAV 片库'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          Text(
            'Kazumi 通过 WebDAV 直接播放原始文件，不需要 anime-server。'
            'OpenList / NAS / alist / Nextcloud 等标准 WebDAV 服务都能用。',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _baseUrl,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: '服务地址',
              hintText: 'http://nas.local:5244',
              helperText: '只填协议 + IP + 端口，不要带 /dav',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _rootPath,
            decoration: const InputDecoration(
              labelText: '片库根路径（WebDAV 路径）',
              hintText: '/dav/anime',
              helperText: '浏览从这里开始，番剧文件夹放在这一层',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _ignoredDirs,
            minLines: 2,
            maxLines: 5,
            decoration: const InputDecoration(
              labelText: '屏蔽搜索的目录',
              hintText: '/dav/anime/特摄\n字幕\n超级字体整合包 XZ',
              helperText: '每行一个：绝对 WebDAV 路径，或文件夹名（包含即跳过）',
              border: OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _user,
            decoration: const InputDecoration(
              labelText: '用户名',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _password,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: '密码',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _busy ? null : _test,
            child: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('测试连接并保存'),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _busy ? null : _save,
            child: const Text('仅保存'),
          ),
        ],
      ),
    );
  }
}
