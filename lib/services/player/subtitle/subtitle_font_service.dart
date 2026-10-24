// SPDX-FileCopyrightText: Copyright (C) 2026 kelstna (AI-assisted modification, see NOTICE.md)
// SPDX-License-Identifier: GPL-3.0-only

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:kazumi/services/logging/logger.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 字幕字体管理：
/// * A：手机本地字体库（`Download/KazumiFonts` 自动扫描 + 设置里手动导入）；
/// * B：服务器字体库按需拉取（解析 ASS 里的字体名，缺哪个向 anime-server 要）。
///
/// 所有字体最终都落在 App 私有目录 `subtitle_fonts/`，再交给 mpv 的
/// `sub-fonts-dir`。Android 上 media_kit 会先放一份内置 MiSans，这里也复制一份，
/// 保证我们接管目录后仍有兜底字体。
class SubtitleFontService {
  static const String _bundledFontAsset = 'assets/fonts/MiSans-Regular.ttf';
  static const List<String> _deviceFolders = [
    '/storage/emulated/0/Download/KazumiFonts',
    '/sdcard/Download/KazumiFonts',
  ];
  static const Set<String> _fontExtensions = {'.ttf', '.otf', '.ttc'};

  Directory? _directory;
  final Set<String> _known = {};
  bool _prepared = false;

  Future<Directory> directory() async {
    final existing = _directory;
    if (existing != null) {
      return existing;
    }
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'subtitle_fonts'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _directory = dir;
    await _loadManifest(dir);
    return dir;
  }

  Future<void> _loadManifest(Directory dir) async {
    try {
      final file = File(p.join(dir.path, 'manifest.json'));
      if (!await file.exists()) {
        return;
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map) {
        for (final key in decoded.keys) {
          _known.add(key.toString());
        }
      }
    } catch (_) {
      // 清单坏了不影响使用，只是可能重复下载字体。
    }
  }

  Future<void> _saveManifest(Directory dir, Map<String, String> manifest) async {
    try {
      final file = File(p.join(dir.path, 'manifest.json'));
      await file.writeAsString(jsonEncode(manifest), flush: true);
    } catch (error) {
      KazumiLogger()
          .w('SubtitleFontService: failed to save manifest', error: error);
    }
  }

  Future<Map<String, String>> _readManifest(Directory dir) async {
    try {
      final file = File(p.join(dir.path, 'manifest.json'));
      if (!await file.exists()) {
        return <String, String>{};
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value.toString()));
      }
    } catch (_) {}
    return <String, String>{};
  }

  /// 开播前准备：内置字体 + 扫描手机字体目录。
  Future<void> prepare() async {
    if (_prepared) {
      return;
    }
    _prepared = true;
    final dir = await directory();
    await _ensureBundledFont(dir);
    await scanDeviceFolder();
  }

  Future<void> _ensureBundledFont(Directory dir) async {
    try {
      final target = File(p.join(dir.path, 'MiSans-Regular.ttf'));
      if (await target.exists() && await target.length() > 0) {
        return;
      }
      final data = await rootBundle.load(_bundledFontAsset);
      await target.writeAsBytes(data.buffer.asUint8List(), flush: true);
    } catch (error) {
      KazumiLogger()
          .w('SubtitleFontService: failed to copy bundled font', error: error);
    }
  }

  /// 扫描 `Download/KazumiFonts`（无权限时静默跳过）。
  ///
  /// 优先用软链接把文件挂进 `sub-fonts-dir`，这样不复制字体、不占 App 缓存；
  /// 文件系统不支持软链接时再退回复制。
  Future<int> scanDeviceFolder() async {
    final dir = await directory();
    var linked = 0;
    for (final folder in _deviceFolders) {
      final source = Directory(folder);
      try {
        if (!await source.exists()) {
          continue;
        }
        await for (final entity in source.list(followLinks: false)) {
          if (entity is! File) {
            continue;
          }
          if (!_fontExtensions.contains(p.extension(entity.path).toLowerCase())) {
            continue;
          }
          if (await _linkOrCopy(entity, dir)) {
            linked++;
          }
        }
      } catch (_) {
        // 没有存储权限时会抛异常，跳过即可。
      }
    }
    if (linked > 0) {
      KazumiLogger().i('SubtitleFontService: linked $linked fonts from device');
    }
    return linked;
  }

  Future<bool> _linkOrCopy(File source, Directory dir) async {
    final name = p.basename(source.path);
    final targetPath = p.join(dir.path, name);
    if (await File(targetPath).exists() || await Link(targetPath).exists()) {
      return false;
    }
    try {
      await Link(targetPath).create(source.path);
      return true;
    } catch (_) {
      try {
        await source.copy(targetPath);
        return true;
      } catch (_) {
        return false;
      }
    }
  }

  /// 手动导入字体文件（多选）。
  Future<int> importFiles(List<String> paths) async {
    final dir = await directory();
    var copied = 0;
    for (final path in paths) {
      try {
        if (await _copyIfMissing(File(path), dir)) {
          copied++;
        }
      } catch (error) {
        KazumiLogger()
            .w('SubtitleFontService: failed to import $path', error: error);
      }
    }
    return copied;
  }

  Future<bool> _copyIfMissing(File source, Directory dir) async {
    final name = p.basename(source.path);
    final target = File(p.join(dir.path, name));
    if (await target.exists()) {
      return false;
    }
    await source.copy(target.path);
    return true;
  }

  Future<int> installedCount() async {
    final dir = await directory();
    try {
      var count = 0;
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File &&
            _fontExtensions.contains(p.extension(entity.path).toLowerCase())) {
          count++;
        }
      }
      return count;
    } catch (_) {
      return 0;
    }
  }

  /// 解析 ASS/SSA 里引用到的字体名：样式表 Fontname + 行内 \fn。
  Future<Set<String>> assFontNames(Iterable<String> paths) async {
    final names = <String>{};
    for (final path in paths) {
      final lower = path.toLowerCase();
      if (!lower.endsWith('.ass') && !lower.endsWith('.ssa')) {
        continue;
      }
      try {
        final file = File(path);
        if (!await file.exists()) {
          continue;
        }
        // 老字幕可能是 GBK，直接 readAsString 会抛 FormatException；
        // 字体名基本都是 ASCII，用允许损坏的 UTF-8 解码即可。
        final bytes = await file.readAsBytes();
        final content = utf8.decode(bytes, allowMalformed: true);
        names.addAll(parseAssFontNames(content));
      } catch (error) {
        KazumiLogger()
            .w('SubtitleFontService: failed to read $path', error: error);
      }
    }
    names.removeWhere((name) => name.isEmpty || name.startsWith('@'));
    return names;
  }

  static final RegExp _styleFontPattern =
      RegExp(r'^\s*Style:\s*[^,]*,([^,]*),', multiLine: true);
  static final RegExp _inlineFontPattern = RegExp(r'\\fn([^\\}]+)');

  static Set<String> parseAssFontNames(String content) {
    final names = <String>{};
    for (final match in _styleFontPattern.allMatches(content)) {
      final name = match.group(1)?.trim() ?? '';
      if (name.isNotEmpty) {
        names.add(name.startsWith('@') ? name.substring(1) : name);
      }
    }
    for (final match in _inlineFontPattern.allMatches(content)) {
      final name = match.group(1)?.trim() ?? '';
      if (name.isNotEmpty) {
        names.add(name.startsWith('@') ? name.substring(1) : name);
      }
    }
    return names;
  }

  static String _normalize(String name) =>
      name.replaceAll(RegExp(r'[\s_\-]+'), '').toLowerCase();

  /// 向服务器字体库要缺失的字体，返回成功下载的数量。
  Future<int> ensureFontsFromServer({
    required String serverBase,
    required Set<String> names,
    Map<String, String> headers = const {},
  }) async {
    if (names.isEmpty || serverBase.isEmpty) {
      return 0;
    }
    final dir = await directory();
    final manifest = await _readManifest(dir);
    var downloaded = 0;
    for (final name in names) {
      final key = _normalize(name);
      if (key.isEmpty || _known.contains(key) || manifest.containsKey(key)) {
        continue;
      }
      try {
        final lookup = await http
            .get(
              Uri.parse(
                  '$serverBase/api/fonts?name=${Uri.encodeQueryComponent(name)}'),
              headers: headers,
            )
            .timeout(const Duration(seconds: 8));
        if (lookup.statusCode != 200) {
          continue;
        }
        final decoded = jsonDecode(utf8.decode(lookup.bodyBytes));
        if (decoded is! Map || decoded['ok'] != true) {
          continue;
        }
        final url = (decoded['url'] ?? '').toString();
        if (url.isEmpty) {
          continue;
        }
        final response = await http
            .get(Uri.parse('$serverBase$url'), headers: headers)
            .timeout(const Duration(seconds: 30));
        if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
          continue;
        }
        final file = File(p.join(dir.path, 'srv_$key.ttf'));
        await file.writeAsBytes(response.bodyBytes, flush: true);
        manifest[key] = p.basename(file.path);
        _known.add(key);
        downloaded++;
        KazumiLogger().i('SubtitleFontService: downloaded font "$name"');
      } catch (error) {
        KazumiLogger()
            .w('SubtitleFontService: failed to fetch font "$name"', error: error);
      }
    }
    if (downloaded > 0) {
      await _saveManifest(dir, manifest);
    }
    return downloaded;
  }

  Future<void> applyToPlayer(Player player) async {
    try {
      final dir = await directory();
      final nativePlayer = player.platform as NativePlayer;
      await nativePlayer.setProperty('sub-fonts-dir', dir.path);
    } catch (error) {
      KazumiLogger()
          .w('SubtitleFontService: failed to set sub-fonts-dir', error: error);
    }
  }

  /// 字体是新加进目录的，libass/fontconfig 不会自动重扫：
  /// 重启一次 libass 渲染再 reload 当前外挂字幕。
  Future<void> reload(Player player) async {
    try {
      final nativePlayer = player.platform as NativePlayer;
      await nativePlayer.setProperty('sub-ass', 'no');
      await nativePlayer.setProperty('sub-ass', 'yes');
      await nativePlayer.command(['sub-reload']);
    } catch (error) {
      KazumiLogger()
          .w('SubtitleFontService: failed to reload subtitles', error: error);
    }
  }
}
