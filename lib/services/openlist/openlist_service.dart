// SPDX-FileCopyrightText: Copyright (C) 2026 kelstna (AI-assisted modification, see NOTICE.md)
// SPDX-License-Identifier: GPL-3.0-only

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:kazumi/modules/roads/road_module.dart';
import 'package:kazumi/modules/search/plugin_search_module.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/player/subtitle/subtitle_entry.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:xml/xml.dart';

/// OpenList 里的一个条目。
class OpenListEntry {
  const OpenListEntry({
    required this.name,
    required this.path,
    required this.isDir,
    this.size = 0,
  });

  final String name;

  /// 解码后的 WebDAV 路径，如 `/dav/anime/xxx/01.mkv`。
  final String path;
  final bool isDir;
  final int size;
}

class OpenListException implements Exception {
  OpenListException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 通过 WebDAV（OpenList / NAS / alist 等）读本地番剧，替代 anime-server。
///
/// 所有请求都带 Basic Auth；播放交给 mpv 直连（HTTP Range），
/// 外挂字幕按同目录 WebDAV 列表下载。
///
/// 内部 id 仍保留 `OpenList`（历史记录/缓存键沿用它，改名会丢观看进度），
/// 界面上统一显示 [displayName]。
class OpenListService {
  OpenListService._();

  static final OpenListService instance = OpenListService._();

  static const String sourceName = 'OpenList';

  /// 界面显示名。
  static const String displayName = 'WebDAV';

  static String displayFor(String pluginName) =>
      pluginName == sourceName ? displayName : pluginName;

  static const Duration _timeout = Duration(seconds: 15);

  static const Set<String> videoExtensions = {
    '.mkv',
    '.mp4',
    '.m4v',
    '.webm',
    '.avi',
    '.mov',
    '.flv',
    '.wmv',
    '.ts',
    '.m2ts',
    '.mpg',
    '.mpeg',
    '.rmvb',
    '.rm',
  };

  String get baseUrl => GStorage.getSetting<String>(SettingsKeys.openListBaseUrl)
      .trim()
      .replaceAll(RegExp(r'/+$'), '');

  String get rootPath {
    final raw = GStorage.getSetting<String>(SettingsKeys.openListRootPath).trim();
    if (raw.isEmpty) {
      return '/dav';
    }
    return raw.startsWith('/') ? raw : '/$raw';
  }

  String get username => GStorage.getSetting<String>(SettingsKeys.openListUser).trim();

  String get password => GStorage.getSetting<String>(SettingsKeys.openListPassword);

  bool get configured => baseUrl.isNotEmpty;

  Map<String, String> get authHeaders {
    if (username.isEmpty) {
      return const {};
    }
    final token = base64Encode(utf8.encode('$username:$password'));
    return {'Authorization': 'Basic $token'};
  }

  bool isOpenListUrl(String url) {
    final base = Uri.tryParse(baseUrl);
    final target = Uri.tryParse(url);
    if (base == null || target == null || base.host.isEmpty) {
      return false;
    }
    return target.host == base.host &&
        target.port == base.port &&
        target.path.startsWith('/dav/');
  }

  Uri _uriFor(String path) => Uri.parse('$baseUrl${_encodePath(path)}');

  String _encodePath(String path) =>
      path.split('/').map(Uri.encodeComponent).join('/');

  /// 列目录（WebDAV PROPFIND depth=1）。
  Future<List<OpenListEntry>> list(String path) async {
    if (!configured) {
      throw OpenListException('还没有配置 OpenList 地址');
    }
    if (username.isEmpty) {
      throw OpenListException('还没有配置 OpenList 账号');
    }
    var target = path;
    if (!target.endsWith('/')) {
      target = '$target/';
    }
    final request = http.Request('PROPFIND', _uriFor(target));
    request.headers['Depth'] = '1';
    request.headers.addAll(authHeaders);
    final client = http.Client();
    try {
      final streamed = await client.send(request).timeout(_timeout);
      final body = await streamed.stream.bytesToString();
      if (streamed.statusCode != 207 && streamed.statusCode != 200) {
        throw OpenListException(
            'WebDAV 返回 ${streamed.statusCode}（检查账号/路径）');
      }
      return _parseMultiStatus(body, selfPath: target);
    } on TimeoutException {
      throw OpenListException('连接 WebDAV 超时');
    } finally {
      client.close();
    }
  }

  /// WebDAV 的 href 是百分号编码的，这里解码成可直接展示/拼接的路径。
  String _decodeHref(String href) {
    final segments = Uri.parse(href).pathSegments;
    return '/${segments.join('/')}';
  }

  List<OpenListEntry> _parseMultiStatus(String body, {required String selfPath}) {
    final document = XmlDocument.parse(body);
    final entries = <OpenListEntry>[];
    final self = _normalizePath(selfPath);
    for (final node in document.findAllElements('response', namespace: 'DAV:')) {
      final href = node.getElement('href', namespace: 'DAV:')?.innerText;
      if (href == null || href.isEmpty) {
        continue;
      }
      final decodedPath = _decodeHref(href);
      if (_normalizePath(decodedPath) == self) {
        continue;
      }
      final displayNodes = node.findAllElements('displayname', namespace: 'DAV:');
      final display = displayNodes.isEmpty ? null : displayNodes.first.innerText;
      final isDir = node
          .findAllElements('collection', namespace: 'DAV:')
          .isNotEmpty;
      final sizeNodes =
          node.findAllElements('getcontentlength', namespace: 'DAV:');
      final sizeText = sizeNodes.isEmpty ? null : sizeNodes.first.innerText;
      final name = (display == null || display.trim().isEmpty)
          ? decodedPath.split('/').last
          : display.trim();
      entries.add(OpenListEntry(
        name: name,
        path: decodedPath,
        isDir: isDir,
        size: int.tryParse(sizeText ?? '') ?? 0,
      ));
    }
    return entries;
  }

  String _normalizePath(String path) {
    var value = path;
    if (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  String _normalizeName(String value) {
    return value
        .toLowerCase()
        .replaceAll(RegExp(r'[\s\-_\[\]()（）【】.,!?:;_]+'), '');
  }

  /// 在 OpenList 根目录里按番剧名找文件夹。
  Future<List<SearchItem>> search(String keyword) async {
    final entries = await list(rootPath);
    final dirs = entries.where((entry) => entry.isDir).toList();
    final query = _normalizeName(keyword);
    if (query.isEmpty) {
      return const [];
    }
    final scored = <({int score, OpenListEntry entry})>[];
    for (final entry in dirs) {
      final name = _normalizeName(entry.name);
      var score = 0;
      if (name == query) {
        score = 100;
      } else if (name.contains(query)) {
        score = 80;
      } else if (query.contains(name) && name.length >= 2) {
        score = 60;
      } else {
        final tokens = entry.name
            .toLowerCase()
            .split(RegExp(r'[\s\-_\[\]()（）【】.,!?:;_]+'))
            .where((token) => token.length >= 2)
            .toList();
        if (tokens.isNotEmpty) {
          final hit = tokens.where((token) => query.contains(token)).length;
          if (hit * 2 >= tokens.length) {
            score = 40 + hit;
          }
        }
      }
      if (score > 0) {
        scored.add((score: score, entry: entry));
      }
    }
    scored.sort((a, b) {
      if (a.score != b.score) {
        return b.score.compareTo(a.score);
      }
      return a.entry.name.compareTo(b.entry.name);
    });
    return [
      for (final item in scored.take(10))
        SearchItem(name: item.entry.name, src: item.entry.path),
    ];
  }

  /// 打开一个番剧文件夹，把视频文件当作集数。
  Future<List<Road>> chapters(String folderPath, {String? folderName}) async {
    final entries = await list(folderPath);
    final videos = entries
        .where((entry) => !entry.isDir && _isVideo(entry.name))
        .toList();
    if (videos.isEmpty) {
      return const [];
    }
    videos.sort((a, b) {
      final na = _episodeNumber(a.name);
      final nb = _episodeNumber(b.name);
      if (na != null && nb != null && na != nb) {
        return na.compareTo(nb);
      }
      if (na != null && nb == null) {
        return -1;
      }
      if (na == null && nb != null) {
        return 1;
      }
      return a.name.compareTo(b.name);
    });
    final segments =
        folderPath.split('/').where((segment) => segment.isNotEmpty).toList();
    final roadName =
        folderName ?? (segments.isEmpty ? sourceName : segments.last);
    return [
      Road(
        name: roadName,
        data: [for (final entry in videos) _uriFor(entry.path).toString()],
        identifier: [for (final entry in videos) entry.name],
      ),
    ];
  }

  bool _isVideo(String name) {
    final lower = name.toLowerCase();
    return videoExtensions.any(lower.endsWith);
  }

  bool _isSubtitle(String name) => isSubtitleFileName(name);

  int? _episodeNumber(String name) {
    final match = RegExp(r'(\d{1,4})(?!.*\d)').firstMatch(name);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  /// 视频同目录的外挂字幕：列 WebDAV、下载到缓存，交给播放器。
  Future<List<SubtitleEntry>> sidecarSubtitles(String videoUrl) async {
    final target = Uri.tryParse(videoUrl);
    if (target == null) {
      return const [];
    }
    final segments = target.pathSegments;
    if (segments.length < 2) {
      return const [];
    }
    final folder = '/${segments.sublist(0, segments.length - 1).join('/')}';
    final entries = await list(folder);
    final subs = entries
        .where((entry) => !entry.isDir && _isSubtitle(entry.name))
        .toList();
    if (subs.isEmpty) {
      return const [];
    }
    final temp = await getTemporaryDirectory();
    final dir = Directory(p.join(
      temp.path,
      'openlist_subs',
      _stableId(folder),
    ));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final result = <SubtitleEntry>[];
    for (final sub in subs) {
      try {
        final file = File(p.join(dir.path, _safeName(sub.name)));
        if (!await file.exists() || await file.length() == 0) {
          final response = await http
              .get(_uriFor(sub.path), headers: authHeaders)
              .timeout(const Duration(seconds: 30));
          if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
            continue;
          }
          await file.writeAsBytes(response.bodyBytes, flush: true);
        }
        result.add(SubtitleEntry(
          id: file.path,
          title: sub.name,
          rawTitle: sub.name,
          kind: SubtitleEntryKind.external,
          uri: file.path,
          codec: p.extension(sub.name).replaceFirst('.', '').toUpperCase(),
        ));
      } catch (error) {
        KazumiLogger()
            .w('OpenListService: failed to fetch subtitle ${sub.name}',
                error: error);
      }
    }
    return result;
  }

  String _stableId(String value) =>
      base64Url.encode(utf8.encode(value)).replaceAll('=', '');

  String _safeName(String value) =>
      value.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
}
