// SPDX-FileCopyrightText: Copyright (C) 2026 kelstna (AI-assisted modification, see NOTICE.md)
// SPDX-License-Identifier: GPL-3.0-only

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:kazumi/modules/roads/road_module.dart';
import 'package:kazumi/modules/search/plugin_search_module.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/openlist/openlist_index_codec.dart';
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
    this.modified = '',
  });

  final String name;

  /// 解码后的 WebDAV 路径，如 `/dav/anime/xxx/01.mkv`。
  final String path;
  final bool isDir;
  final int size;

  /// WebDAV 的 getlastmodified 原样字符串，用于判断字体是否变化。
  final String modified;
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
  static const Duration _folderIndexTtl = Duration(minutes: 5);

  /// 单目录 PROPFIND 的超时（比整表 `_timeout` 短，慢目录不该拖死整次扫描）。
  static const Duration _dirTimeout = Duration(seconds: 8);

  /// 目录扫描上限（与原实现一致），防止超大网盘扫到天荒地老。
  static const int _maxFolders = 800;
  static const int _maxDepth = 6;

  /// 同时在飞的 PROPFIND 数量。串行扫 800 个目录要几十秒，并发 4 路快得多，
  /// 又不至于把 NAS / 路由器打满。
  static const int _scanConcurrency = 4;

  List<OpenListEntry>? _folderIndex;
  DateTime? _folderIndexAt;
  bool _folderIndexRefreshing = false;
  Future<List<OpenListEntry>>? _scanInFlight;

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

  /// 给字体库等模块用的完整 URI（已带 Basic Auth 由调用方加）。
  Uri uriFor(String path) => _uriFor(path);

  String _encodePath(String path) =>
      path.split('/').map(Uri.encodeComponent).join('/');

  /// 列目录（WebDAV PROPFIND depth=1）。
  Future<List<OpenListEntry>> list(String path, {Duration? timeout}) async {
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
      final streamed =
          await client.send(request).timeout(timeout ?? _timeout);
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
      final modifiedNodes =
          node.findAllElements('getlastmodified', namespace: 'DAV:');
      final modified =
          modifiedNodes.isEmpty ? '' : modifiedNodes.first.innerText.trim();
      final name = (display == null || display.trim().isEmpty)
          ? decodedPath.split('/').last
          : display.trim();
      entries.add(OpenListEntry(
        name: name,
        path: decodedPath,
        isDir: isDir,
        size: int.tryParse(sizeText ?? '') ?? 0,
        modified: modified,
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

  /// 让下一次搜索重新扫描目录（修改 WebDAV 设置后调用）。
  void invalidateFolderIndex() {
    _folderIndex = null;
    _folderIndexAt = null;
    unawaited(OpenListIndexCache.instance.clear());
  }

  bool _isHiddenDir(String name) {
    final lower = name.toLowerCase();
    return name.startsWith('.') ||
        name.startsWith('@') ||
        lower == '#recycle' ||
        lower == '\$recycle.bin' ||
        lower == 'system volume information';
  }

  bool _isIgnoredDir(String path, String name) {
    final raw =
        GStorage.getSetting<String>(SettingsKeys.openListIgnoredDirs).trim();
    if (raw.isEmpty) {
      return false;
    }
    for (final line in raw.split(RegExp(r'[\r\n,]+'))) {
      final item = line.trim();
      if (item.isEmpty) {
        continue;
      }
      if (item.startsWith('/')) {
        final normalized = item.endsWith('/') && item.length > 1
            ? item.substring(0, item.length - 1)
            : item;
        if (path == normalized || path.startsWith('$normalized/')) {
          return true;
        }
      } else if (name.toLowerCase().contains(item.toLowerCase())) {
        return true;
      }
    }
    return false;
  }

  /// 目录索引的缓存 key（换地址/换根目录要各算各的）。
  String get _cacheKey => base64Url
      .encode(utf8.encode('$baseUrl|$rootPath'))
      .replaceAll('=', '');

  /// 递归收集根目录下的所有文件夹，供搜索使用。
  ///
  /// 分两级缓存：进程内 [_folderIndex]（5 分钟）→ 磁盘快照
  /// [OpenListIndexCache]。冷启动第一次搜索直接用上次的索引，
  /// 后台再刷一遍，不必每次都把整棵目录树扫一遍。
  Future<List<OpenListEntry>> _collectFolders() async {
    final cached = _folderIndex;
    final cachedAt = _folderIndexAt;
    if (cached != null &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt) < _folderIndexTtl) {
      return cached;
    }
    final disk = await OpenListIndexCache.instance.read(_cacheKey);
    if (disk != null) {
      final folders = [
        for (final folder in disk.folders)
          OpenListEntry(
            name: folder.name,
            path: folder.path,
            isDir: true,
            modified: folder.modified,
          ),
      ];
      _folderIndex = folders;
      _folderIndexAt = disk.savedAt;
      KazumiLogger().i(
          'OpenListService: folder index from disk (${folders.length} dirs, '
          'age ${DateTime.now().difference(disk.savedAt).inMinutes}min)');
      unawaited(_refreshFolderIndexInBackground());
      return folders;
    }
    final folders = await _scanFolders();
    _folderIndex = folders;
    _folderIndexAt = DateTime.now();
    unawaited(OpenListIndexCache.instance.write(_cacheKey, folders));
    return folders;
  }

  Future<void> _refreshFolderIndexInBackground() async {
    if (_folderIndexRefreshing) {
      return;
    }
    _folderIndexRefreshing = true;
    try {
      final folders = await _scanFolders();
      _folderIndex = folders;
      _folderIndexAt = DateTime.now();
      await OpenListIndexCache.instance.write(_cacheKey, folders);
    } catch (error) {
      KazumiLogger()
          .w('OpenListService: failed to refresh folder index', error: error);
    } finally {
      _folderIndexRefreshing = false;
    }
  }

  /// 同一时刻只跑一次扫描：边输入边搜索时不要反复扫整棵目录树。
  Future<List<OpenListEntry>> _scanFolders() {
    final inFlight = _scanInFlight;
    if (inFlight != null) {
      return inFlight;
    }
    final future = _scanFoldersInner();
    _scanInFlight = future;
    return future.whenComplete(() {
      _scanInFlight = null;
    });
  }

  /// 并发 BFS：最多 [_scanConcurrency] 个 PROPFIND 同时在飞。
  Future<List<OpenListEntry>> _scanFoldersInner() async {
    final stopwatch = Stopwatch()..start();
    final folders = <OpenListEntry>[];
    final scanned = <String>{};
    final queue = <({String path, int depth})>[(path: rootPath, depth: 0)];
    final completer = Completer<void>();
    var active = 0;

    Future<void> scanOne(({String path, int depth}) current) async {
      try {
        final entries = await list(current.path, timeout: _dirTimeout);
        for (final entry in entries) {
          if (!entry.isDir) {
            continue;
          }
          if (_isHiddenDir(entry.name) ||
              _isIgnoredDir(entry.path, entry.name)) {
            continue;
          }
          folders.add(entry);
          if (current.depth < _maxDepth) {
            queue.add((path: entry.path, depth: current.depth + 1));
          }
        }
      } catch (error) {
        KazumiLogger()
            .w('OpenListService: failed to list ${current.path}', error: error);
      }
    }

    void pump() {
      while (active < _scanConcurrency &&
          queue.isNotEmpty &&
          folders.length < _maxFolders) {
        final current = queue.removeAt(0);
        if (!scanned.add(current.path)) {
          continue;
        }
        active++;
        unawaited(scanOne(current).whenComplete(() {
          active--;
          pump();
        }));
      }
      if (active == 0 &&
          (queue.isEmpty || folders.length >= _maxFolders) &&
          !completer.isCompleted) {
        completer.complete();
      }
    }

    pump();
    await completer.future;
    stopwatch.stop();
    KazumiLogger().i(
        'OpenListService: folder scan finished in ${stopwatch.elapsedMilliseconds}ms '
        '(${folders.length} dirs)');
    return folders;
  }

  /// 在 WebDAV 根目录及其子目录里按番剧名找文件夹。
  Future<List<SearchItem>> search(String keyword) async {
    final query = _normalizeName(keyword);
    if (query.isEmpty) {
      return const [];
    }
    final folders = await _collectFolders();
    final rootSegments = rootPath.split('/').where((s) => s.isNotEmpty).length;
    final scored = <({int score, int depth, OpenListEntry entry})>[];
    for (final entry in folders) {
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
        final depth = entry.path.split('/').where((s) => s.isNotEmpty).length -
            rootSegments;
        scored.add((score: score, depth: depth, entry: entry));
      }
    }
    scored.sort((a, b) {
      if (a.score != b.score) {
        return b.score.compareTo(a.score);
      }
      if (a.depth != b.depth) {
        return a.depth.compareTo(b.depth);
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

/// WebDAV 目录索引的磁盘缓存：冷启动第一次搜索不用再全量扫目录。
///
/// 只存文件夹名字/路径/修改时间（约几十 KB），按 `baseUrl|rootPath` 分 key，
/// 换地址或改根目录会自动失效。编码/解析在 `openlist_index_codec.dart`。
class OpenListIndexCache {
  OpenListIndexCache._();

  static final OpenListIndexCache instance = OpenListIndexCache._();

  static const String _fileName = 'openlist_folder_index.json';

  File? _file;

  Future<File> _resolveFile() async {
    final cached = _file;
    if (cached != null) {
      return cached;
    }
    final dir = await getApplicationSupportDirectory();
    return _file = File(p.join(dir.path, _fileName));
  }

  Future<DecodedOpenListIndex?> read(String key) async {
    try {
      final file = await _resolveFile();
      if (!await file.exists()) {
        return null;
      }
      return decodeOpenListIndex(await file.readAsString(), key: key);
    } catch (error) {
      KazumiLogger()
          .w('OpenListService: failed to read folder index cache', error: error);
      return null;
    }
  }

  Future<void> write(String key, List<OpenListEntry> folders) async {
    try {
      final file = await _resolveFile();
      final payload = encodeOpenListIndex(
        key: key,
        savedAt: DateTime.now(),
        folders: [
          for (final entry in folders)
            OpenListIndexFolder(
              name: entry.name,
              path: entry.path,
              modified: entry.modified,
            ),
        ],
      );
      await file.parent.create(recursive: true);
      await file.writeAsString(payload, flush: true);
    } catch (error) {
      KazumiLogger().w('OpenListService: failed to write folder index cache',
          error: error);
    }
  }

  Future<void> clear() async {
    try {
      final file = await _resolveFile();
      if (await file.exists()) {
        await file.delete();
      }
    } catch (error) {
      KazumiLogger().w('OpenListService: failed to clear folder index cache',
          error: error);
    }
  }
}
