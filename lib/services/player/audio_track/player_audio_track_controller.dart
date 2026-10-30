// SPDX-FileCopyrightText: Copyright (C) 2026 kelstna (AI-assisted modification, see NOTICE.md)
// SPDX-License-Identifier: GPL-3.0-only

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:kazumi/services/bangumi/subject_language.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/player/subtitle/subtitle_entry.dart'
    show subtitleLanguageLabel;
import 'package:kazumi/services/player/track_memory.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;

/// 一条内封音轨。
class AudioTrackEntry {
  const AudioTrackEntry({
    required this.id,
    required this.title,
    this.language,
    this.codec,
    this.channels,
  });

  factory AudioTrackEntry.fromTrack(AudioTrack track) {
    final parts = <String>[];
    final language = subtitleLanguageLabel(track.language);
    final title = (track.title ?? '').trim();
    if (title.isNotEmpty && title.toLowerCase() != (track.language ?? '')) {
      parts.add(title);
    }
    if (language.isNotEmpty && language != title) {
      parts.add(language);
    }
    final channels = track.channels;
    if (channels != null && channels.isNotEmpty) {
      parts.add(channels);
    }
    final codec = (track.codec ?? '').trim().toUpperCase();
    if (codec.isNotEmpty) {
      parts.add(codec);
    }
    if (parts.isEmpty) {
      parts.add('音轨 ${track.id}');
    }
    return AudioTrackEntry(
      id: track.id,
      title: parts.join(' · '),
      language: track.language,
      codec: track.codec,
      channels: track.channels,
    );
  }

  final String id;
  final String title;
  final String? language;
  final String? codec;
  final String? channels;

  AudioTrack toTrack() => AudioTrack(id, title, language);
}

/// 多音轨选择 + 开播自动选轨。
///
/// 自动策略（设置项 `autoSelectAudioTrack`）：
/// * `meta` —— 按作品原声语言（bgm 元信息 → 文件名标签 → 文件默认）；
/// * `auto` —— 不干预，跟随文件里的 default 标记（mpv 的默认行为）；
/// * `jpn` / `chi` / `eng` —— 优先选对应语言的轨道。
class PlayerAudioTrackController extends ChangeNotifier {
  Player? _player;
  StreamSubscription<Tracks>? _tracksSubscription;
  StreamSubscription<Track>? _trackSubscription;
  bool _disposed = false;
  bool _userChosen = false;
  bool _autoApplied = false;

  /// 本集记忆（只按这一个视频恢复）。
  String _videoKey = '';
  String _videoName = '';
  String? _expectedLanguage;
  bool _memoryChecked = false;
  bool _hasMemory = false;

  List<AudioTrackEntry> _entries = const [];
  AudioTrackEntry? _selected;

  List<AudioTrackEntry> get entries => _entries;

  AudioTrackEntry? get selected => _selected;

  bool get hasMultiple => _entries.length > 1;

  bool get isAttached => _player != null;

  /// 本集是否有记住的手动选择。
  bool get hasRememberedSelection => _hasMemory;

  Future<void> attach(
    Player player, {
    required String videoUrl,
    String? expectedLanguage,
  }) async {
    await _teardown();
    _player = player;
    _videoKey = TrackMemoryStore.keyFor(videoUrl);
    _videoName = _fileNameOf(videoUrl);
    _expectedLanguage = expectedLanguage;
    _entries = const [];
    _selected = null;
    _userChosen = false;
    _autoApplied = false;
    _memoryChecked = false;
    _hasMemory = false;
    _tracksSubscription = player.stream.tracks.listen(_onTracks);
    _trackSubscription = player.stream.track.listen(_onCurrentTrackChanged);
    _onTracks(player.state.tracks);
    _notify();

    // mpv 的轨道选择有时比 track-list 晚一拍，补一次同步。
    unawaited(Future<void>.delayed(const Duration(seconds: 1), () {
      if (_disposed || !identical(_player, player) || _selected != null) {
        return;
      }
      _syncFromPlayer();
      _notify();
    }));
  }

  void _onTracks(Tracks tracks) {
    final entries = tracks.audio
        .where((track) => track.id != 'auto' && track.id != 'no')
        .map(AudioTrackEntry.fromTrack)
        .toList(growable: false);
    _entries = entries;
    if (!_memoryChecked) {
      _memoryChecked = true;
      if (_restoreFromMemory()) {
        _notify();
        return;
      }
    }
    if (!_userChosen && !_autoApplied && entries.isNotEmpty) {
      _autoApplied = true;
      _autoSelect();
    }
    if (_selected == null) {
      _syncFromPlayer();
    }
    if (_selected == null && entries.length == 1) {
      // 只有一条音轨时直接标为选中，UI 不再显示空白。
      _selected = entries.first;
    }
    _notify();
  }

  void _onCurrentTrackChanged(Track track) {
    _syncFromPlayer();
    _notify();
  }

  void _syncFromPlayer() {
    final player = _player;
    if (player == null) {
      return;
    }
    final current = player.state.track.audio;
    if (current.id == 'auto' || current.id == 'no') {
      return;
    }
    for (final entry in _entries) {
      if (entry.id == current.id) {
        _selected = entry;
        return;
      }
    }
  }

  /// 自动选轨：设置的语言 → 作品语言 → 文件名标签 → 文件默认。
  void _autoSelect() {
    final preference =
        GStorage.getSetting<String>(SettingsKeys.autoSelectAudioTrack);
    if (preference == 'auto') {
      _syncFromPlayer();
      return;
    }
    final targets = <String>[];
    if (preference == 'meta') {
      final expected = _expectedLanguage;
      if (expected != null && expected.isNotEmpty) {
        targets.add(expected);
      }
      targets.addAll(filenameLanguageCodes(_videoName));
    } else {
      targets.add(preference);
    }
    for (final target in targets) {
      final entry = _pickByLanguage(target);
      if (entry != null) {
        unawaited(_apply(entry, userInitiated: false));
        return;
      }
    }
    _syncFromPlayer();
  }

  /// 作品语言晚到（bgm 请求返回）时补一次自动选择。
  void applyExpectedLanguage(String? language) {
    final code = (language ?? '').trim();
    if (code.isEmpty || code == _expectedLanguage) {
      return;
    }
    _expectedLanguage = code;
    if (_userChosen || _hasMemory || _disposed) {
      return;
    }
    if (GStorage.getSetting<String>(SettingsKeys.autoSelectAudioTrack) !=
        'meta') {
      return;
    }
    _autoApplied = false;
    _autoSelect();
  }

  AudioTrackEntry? _pickByLanguage(String language) {
    final target = normalizeLanguageCode(language);
    if (target.isEmpty) {
      return null;
    }
    final byCode = _entries
        .where((entry) => normalizeLanguageCode(entry.language) == target)
        .toList();
    final candidates = byCode.isNotEmpty ? byCode : _byLabel(target);
    if (candidates.isEmpty) {
      return null;
    }
    candidates.sort((a, b) => _qualityScore(b).compareTo(_qualityScore(a)));
    return candidates.first;
  }

  /// 轨道没写语言代码时，用标题里的语言名兜底（「英语 · EAC3」）。
  List<AudioTrackEntry> _byLabel(String target) {
    final keywords = switch (target) {
      'ja' => const ['日语', '日文', 'japanese'],
      'zh' => const ['中文', '汉语', '国语', '简体', '繁体', 'chinese'],
      'en' => const ['英语', '英文', 'english'],
      'it' => const ['意大利', 'italian'],
      'fr' => const ['法语', 'french'],
      'de' => const ['德语', 'german'],
      'es' => const ['西班牙', 'spanish'],
      'ko' => const ['韩语', 'korean'],
      _ => const <String>[],
    };
    if (keywords.isEmpty) {
      return const [];
    }
    return _entries
        .where((entry) => keywords.any(entry.title.toLowerCase().contains))
        .toList();
  }

  /// 同语言多条时挑质量更好的：编码优先于声道，两边都没有就取第一条。
  int _qualityScore(AudioTrackEntry entry) {
    final codec = (entry.codec ?? '').toLowerCase();
    final channels = (entry.channels ?? '').toLowerCase();
    var score = 0;
    if (codec.contains('truehd') || codec.contains('flac')) {
      score += 15;
    } else if (codec.contains('dts')) {
      score += 14;
    } else if (codec.contains('eac3') || codec.contains('e-ac3')) {
      score += 12;
    } else if (codec.contains('ac3')) {
      score += 8;
    } else if (codec.contains('aac')) {
      score += 6;
    } else if (codec.contains('opus')) {
      score += 5;
    }
    if (channels.contains('7.1') || channels.contains('8')) {
      score += 6;
    } else if (channels.contains('5.1') || channels.contains('6')) {
      score += 4;
    } else if (channels.contains('2.0') || channels.contains('stereo')) {
      score += 1;
    }
    return score;
  }

  /// 用户手动选择音轨。
  Future<void> select(AudioTrackEntry entry) async {
    _userChosen = true;
    await _apply(entry, userInitiated: true);
    _rememberSelection(entry);
  }

  void _rememberSelection(AudioTrackEntry entry) {
    final key = _videoKey;
    if (key.isEmpty) {
      return;
    }
    _hasMemory = true;
    unawaited(TrackMemoryStore.instance.writeAudio(
      key,
      AudioMemory(
        language: entry.language,
        title: entry.title,
        candidates: _entries
            .where((item) =>
                normalizeLanguageCode(item.language) ==
                normalizeLanguageCode(entry.language))
            .map((item) => item.title)
            .toList(),
      ),
    ));
  }

  /// 清掉本集的音轨记忆。
  Future<void> clearRememberedSelection() async {
    if (_videoKey.isEmpty) {
      return;
    }
    await TrackMemoryStore.instance.clear(_videoKey);
    _hasMemory = false;
    _notify();
  }

  bool _restoreFromMemory() {
    if (_videoKey.isEmpty || !TrackMemoryStore.instance.enabled) {
      return false;
    }
    final memory = TrackMemoryStore.instance.readAudio(_videoKey);
    if (memory == null) {
      return false;
    }
    final entry = _findByMemory(memory);
    if (entry == null) {
      return false;
    }
    _userChosen = true;
    _autoApplied = true;
    _hasMemory = true;
    unawaited(_apply(entry, userInitiated: true));
    KazumiLogger().i(
        'PlayerAudioTrackController: restored "${entry.title}" from memory');
    return true;
  }

  AudioTrackEntry? _findByMemory(AudioMemory memory) {
    final language = normalizeLanguageCode(memory.language);
    final name = (memory.title ?? '').toLowerCase();
    for (final entry in _entries) {
      if (normalizeLanguageCode(entry.language) == language &&
          entry.title.toLowerCase() == name) {
        return entry;
      }
    }
    for (final entry in _entries) {
      if (name.isNotEmpty && entry.title.toLowerCase() == name) {
        return entry;
      }
    }
    final candidates = memory.candidates ?? const [];
    for (final entry in _entries) {
      if (candidates.contains(entry.title)) {
        return entry;
      }
    }
    for (final entry in _entries) {
      if (language.isNotEmpty &&
          normalizeLanguageCode(entry.language) == language) {
        return entry;
      }
    }
    return null;
  }

  Future<void> _apply(AudioTrackEntry entry,
      {required bool userInitiated}) async {
    final player = _player;
    if (player == null) {
      return;
    }
    try {
      await player.setAudioTrack(entry.toTrack());
      _selected = entry;
      _notify();
      KazumiLogger().i(
          'PlayerAudioTrackController: ${userInitiated ? 'selected' : 'auto-selected'} audio "${entry.title}"');
    } catch (error) {
      KazumiLogger()
          .e('PlayerAudioTrackController: failed to set audio', error: error);
    }
  }

  Future<void> detach() async {
    await _teardown();
    _player = null;
    _entries = const [];
    _selected = null;
    _userChosen = false;
    _autoApplied = false;
    _videoKey = '';
    _videoName = '';
    _expectedLanguage = null;
    _memoryChecked = false;
    _hasMemory = false;
    _notify();
  }

  Future<void> _teardown() async {
    await _tracksSubscription?.cancel();
    _tracksSubscription = null;
    await _trackSubscription?.cancel();
    _trackSubscription = null;
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  static String _fileNameOf(String videoUrl) {
    final uri = Uri.tryParse(videoUrl);
    final segments =
        uri?.pathSegments.where((segment) => segment.isNotEmpty).toList() ??
            const <String>[];
    if (segments.isEmpty) {
      return p.basename(videoUrl);
    }
    return Uri.decodeComponent(segments.last);
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_teardown());
    _player = null;
    super.dispose();
  }
}
