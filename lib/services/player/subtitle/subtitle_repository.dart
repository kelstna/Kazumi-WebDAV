// SPDX-FileCopyrightText: Copyright (C) 2026 kelstna (AI-assisted modification, see NOTICE.md)
// SPDX-License-Identifier: GPL-3.0-only

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/openlist/openlist_service.dart';
import 'package:kazumi/services/player/subtitle/subtitle_entry.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 发现「外挂字幕」：
/// * 本地文件：扫描视频同目录下的字幕文件；
/// * 局域网 anime-server：请求 `/api/subs/<video_id>`，把字幕缓存到本地再交给 mpv。
class SubtitleRepository {
  static const Duration _timeout = Duration(seconds: 8);

  Future<List<SubtitleEntry>> discover({
    required String videoUrl,
    required bool isLocalPlayback,
    Map<String, String> headers = const {},
  }) async {
    try {
      if (isLocalPlayback || !videoUrl.contains('://')) {
        return await _scanLocalDirectory(videoUrl);
      }
      if (OpenListService.instance.isOpenListUrl(videoUrl)) {
        return await OpenListService.instance.sidecarSubtitles(videoUrl);
      }
      return await _fetchSidecarSubtitles(videoUrl, headers);
    } catch (error) {
      KazumiLogger().w('SubtitleRepository: discover failed', error: error);
      return const [];
    }
  }

  Future<List<SubtitleEntry>> _scanLocalDirectory(String videoPath) async {
    final video = File(videoPath);
    if (!await video.exists()) {
      return const [];
    }
    final directory = video.parent;
    if (!await directory.exists()) {
      return const [];
    }
    final entries = <SubtitleEntry>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) {
        continue;
      }
      final name = p.basename(entity.path);
      if (!isSubtitleFileName(name)) {
        continue;
      }
      entries.add(_externalEntry(name: name, path: entity.path));
    }
    return _sorted(entries);
  }

  Future<List<SubtitleEntry>> _fetchSidecarSubtitles(
    String videoUrl,
    Map<String, String> headers,
  ) async {
    final uri = Uri.tryParse(videoUrl);
    if (uri == null || uri.host.isEmpty) {
      return const [];
    }
    final base = '${uri.scheme}://${uri.authority}';
    final videoId = videoIdFromUrl(videoUrl);
    if (videoId.isEmpty) {
      return const [];
    }

    final manifest = await http
        .get(Uri.parse('$base/api/subs/$videoId'), headers: headers)
        .timeout(_timeout);
    if (manifest.statusCode != 200) {
      return const [];
    }
    final decoded = jsonDecode(utf8.decode(manifest.bodyBytes));
    if (decoded is! Map<String, dynamic>) {
      return const [];
    }
    final rawList = decoded['subtitles'];
    if (rawList is! List || rawList.isEmpty) {
      return const [];
    }

    final cacheDir = await _cacheDirectory(videoId);
    final entries = <SubtitleEntry>[];
    for (final raw in rawList) {
      if (raw is! Map) {
        continue;
      }
      final name = (raw['name'] ?? '').toString();
      final url = (raw['url'] ?? '').toString();
      if (name.isEmpty || url.isEmpty) {
        continue;
      }
      try {
        final resolved = url.startsWith('http') ? url : '$base$url';
        final localFile = File(p.join(cacheDir.path, _safeName(name)));
        if (!await localFile.exists() || await localFile.length() == 0) {
          final response = await http
              .get(Uri.parse(resolved), headers: headers)
              .timeout(const Duration(seconds: 30));
          if (response.statusCode != 200) {
            continue;
          }
          await localFile.writeAsBytes(response.bodyBytes, flush: true);
        }
        entries.add(_externalEntry(
          name: name,
          path: localFile.path,
          language: (raw['lang'] ?? '').toString(),
        ));
      } catch (error) {
        KazumiLogger().w('SubtitleRepository: failed to fetch sidecar $name',
            error: error);
      }
    }
    return _sorted(entries);
  }

  SubtitleEntry _externalEntry({
    required String name,
    required String path,
    String? language,
  }) {
    return SubtitleEntry(
      id: path,
      title: name,
      rawTitle: name,
      kind: SubtitleEntryKind.external,
      uri: path,
      language: (language ?? '').isEmpty ? null : language,
      codec: p.extension(name).replaceFirst('.', '').toUpperCase(),
    );
  }

  List<SubtitleEntry> _sorted(List<SubtitleEntry> entries) {
    final seen = <String>{};
    final unique = <SubtitleEntry>[];
    for (final entry in entries) {
      if (seen.add(entry.id)) {
        unique.add(entry);
      }
    }
    unique.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return unique;
  }

  Future<Directory> _cacheDirectory(String videoId) async {
    final temp = await getTemporaryDirectory();
    final dir =
        Directory(p.join(temp.path, 'kazumi_subtitles', _safeName(videoId)));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  String _safeName(String value) {
    return value.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  }
}

/// 从播放地址里取出视频 id：`http://host/raw/abc.mkv` -> `abc`。
String videoIdFromUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) {
    return '';
  }
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segments.isEmpty) {
    return '';
  }
  return p.basenameWithoutExtension(segments.last);
}
