// SPDX-FileCopyrightText: Copyright (C) 2026 kelstna (AI-assisted modification, see NOTICE.md)
// SPDX-License-Identifier: GPL-3.0-only

/// 单集字幕/音轨选择的记忆。
///
/// 只按「这一个视频」记：同一个文件下次打开恢复上次的手动选择；
/// 换集不沿用（避免把第 1 集选的繁体字幕带到第 2 集）。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:kazumi/services/storage/storage.dart';

/// 字幕选择的三种状态。
enum SubtitleMemoryKind { off, embedded, external }

class SubtitleMemory {
  const SubtitleMemory({
    required this.kind,
    this.name,
    this.language,
    this.candidates,
  });

  final SubtitleMemoryKind kind;

  /// 外挂字幕的文件名 / 内封轨道的标题（用于重新定位）。
  final String? name;
  final String? language;

  /// 同名候选的序号（同一文件里有多条同语言同标题的轨道时兜底）。
  final List<String>? candidates;

  Map<String, Object?> toJson() => {
        'k': kind.name,
        if (name != null) 'n': name,
        if (language != null) 'l': language,
        if (candidates != null) 'c': candidates,
      };

  static SubtitleMemory? fromJson(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final kindName = '${raw['k'] ?? ''}';
    SubtitleMemoryKind? kind;
    for (final value in SubtitleMemoryKind.values) {
      if (value.name == kindName) {
        kind = value;
        break;
      }
    }
    if (kind == null) {
      return null;
    }
    final candidates = raw['c'];
    return SubtitleMemory(
      kind: kind,
      name: raw['n'] as String?,
      language: raw['l'] as String?,
      candidates: candidates is List ? candidates.map((e) => '$e').toList() : null,
    );
  }
}

class AudioMemory {
  const AudioMemory({this.language, this.title, this.candidates});

  final String? language;
  final String? title;
  final List<String>? candidates;

  Map<String, Object?> toJson() => {
        if (language != null) 'l': language,
        if (title != null) 't': title,
        if (candidates != null) 'c': candidates,
      };

  static AudioMemory? fromJson(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final candidates = raw['c'];
    return AudioMemory(
      language: raw['l'] as String?,
      title: raw['t'] as String?,
      candidates: candidates is List ? candidates.map((e) => '$e').toList() : null,
    );
  }
}

class _Entry {
  const _Entry({this.subtitle, this.audio, required this.timestamp});

  final SubtitleMemory? subtitle;
  final AudioMemory? audio;
  final int timestamp;

  _Entry copyWith({
    SubtitleMemory? subtitle,
    bool clearSubtitle = false,
    AudioMemory? audio,
    bool clearAudio = false,
    int? timestamp,
  }) {
    return _Entry(
      subtitle: clearSubtitle ? null : (subtitle ?? this.subtitle),
      audio: clearAudio ? null : (audio ?? this.audio),
      timestamp: timestamp ?? this.timestamp,
    );
  }

  Map<String, Object?> toJson() => {
        if (subtitle != null) 's': subtitle!.toJson(),
        if (audio != null) 'a': audio!.toJson(),
        't': timestamp,
      };

  static _Entry? fromJson(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    return _Entry(
      subtitle: SubtitleMemory.fromJson(raw['s']),
      audio: AudioMemory.fromJson(raw['a']),
      timestamp: (raw['t'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 读写入口。数据存在设置箱的一个 JSON 字段里，最多 [_maxEntries] 条。
class TrackMemoryStore {
  TrackMemoryStore._();

  static final TrackMemoryStore instance = TrackMemoryStore._();

  static const int _maxEntries = 300;

  Map<String, _Entry>? _cache;

  /// 统一的视频标识：URL 去掉查询串/账号信息，本地路径直接用。
  static String keyFor(String videoUrl) {
    var identity = videoUrl.trim();
    final uri = Uri.tryParse(identity);
    if (uri != null && uri.hasScheme) {
      identity = uri
          .replace(query: '', fragment: '', userInfo: '')
          .toString();
    }
    final digest = sha1.convert(utf8.encode(identity)).toString();
    return digest.substring(0, 16);
  }

  bool get enabled => GStorage.getSetting(SettingsKeys.rememberTrackSelection);

  int get count => _load().length;

  SubtitleMemory? readSubtitle(String key) => _load()[key]?.subtitle;

  AudioMemory? readAudio(String key) => _load()[key]?.audio;

  Future<void> writeSubtitle(String key, SubtitleMemory? memory) async {
    if (!enabled) {
      return;
    }
    final map = _load();
    final existing = map[key];
    if (memory == null) {
      if (existing == null) {
        return;
      }
      map[key] = existing.copyWith(clearSubtitle: true, timestamp: _now());
    } else {
      map[key] = (existing ?? const _Entry(timestamp: 0))
          .copyWith(subtitle: memory, timestamp: _now());
    }
    await _commit(map);
  }

  Future<void> writeAudio(String key, AudioMemory? memory) async {
    if (!enabled) {
      return;
    }
    final map = _load();
    final existing = map[key];
    if (memory == null) {
      if (existing == null) {
        return;
      }
      map[key] = existing.copyWith(clearAudio: true, timestamp: _now());
    } else {
      map[key] = (existing ?? const _Entry(timestamp: 0))
          .copyWith(audio: memory, timestamp: _now());
    }
    await _commit(map);
  }

  Future<void> clear(String key) async {
    final map = _load();
    if (map.remove(key) == null) {
      return;
    }
    await _commit(map);
  }

  Future<void> clearAll() async {
    _cache = {};
    try {
      await GStorage.putSetting<String>(SettingsKeys.trackMemory, '{}');
    } catch (_) {
      // 忽略写盘失败。
    }
  }

  Map<String, _Entry> _load() {
    final cached = _cache;
    if (cached != null) {
      return cached;
    }
    final map = <String, _Entry>{};
    try {
      final raw = GStorage.getSetting(SettingsKeys.trackMemory);
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        decoded.forEach((key, value) {
          final entry = _Entry.fromJson(value);
          if (entry != null) {
            map['$key'] = entry;
          }
        });
      }
    } catch (_) {
      // 数据损坏就当作空。
    }
    _cache = map;
    return map;
  }

  Future<void> _commit(Map<String, _Entry> map) async {
    if (map.length > _maxEntries) {
      final sorted = map.entries.toList()
        ..sort((a, b) => a.value.timestamp.compareTo(b.value.timestamp));
      for (final item in sorted.take(map.length - _maxEntries)) {
        map.remove(item.key);
      }
    }
    _cache = map;
    try {
      await GStorage.putSetting<String>(
        SettingsKeys.trackMemory,
        jsonEncode(map.map((key, value) => MapEntry(key, value.toJson()))),
      );
    } catch (_) {
      // 忽略写盘失败。
    }
  }

  int _now() => DateTime.now().millisecondsSinceEpoch;
}
