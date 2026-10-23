// SPDX-FileCopyrightText: Copyright (C) 2026 kelstna (AI-assisted modification, see NOTICE.md)
// SPDX-License-Identifier: GPL-3.0-only

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/player/subtitle/subtitle_entry.dart'
    show subtitleLanguageLabel;
import 'package:kazumi/services/storage/storage.dart';
import 'package:media_kit/media_kit.dart';

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
/// * `auto` —— 不干预，跟随文件里的 default 标记（mpv 的默认行为）；
/// * `jpn` / `chi` / `eng` —— 优先选对应语言的轨道，找不到再跟随默认。
class PlayerAudioTrackController extends ChangeNotifier {
  Player? _player;
  StreamSubscription<Tracks>? _tracksSubscription;
  StreamSubscription<Track>? _trackSubscription;
  bool _disposed = false;
  bool _userChosen = false;
  bool _autoApplied = false;

  List<AudioTrackEntry> _entries = const [];
  AudioTrackEntry? _selected;

  List<AudioTrackEntry> get entries => _entries;

  AudioTrackEntry? get selected => _selected;

  bool get hasMultiple => _entries.length > 1;

  bool get isAttached => _player != null;

  Future<void> attach(Player player) async {
    await _teardown();
    _player = player;
    _entries = const [];
    _selected = null;
    _userChosen = false;
    _autoApplied = false;
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

  void _autoSelect() {
    final preference =
        GStorage.getSetting<String>(SettingsKeys.autoSelectAudioTrack);
    if (preference.isEmpty || preference == 'auto') {
      _syncFromPlayer();
      return;
    }
    final keywords = switch (preference) {
      'jpn' => const ['jpn', 'ja', 'jp', '日'],
      'chi' => const ['chi', 'zho', 'zh', '中文', '中'],
      'eng' => const ['eng', 'en', '英'],
      _ => const <String>[],
    };
    if (keywords.isEmpty) {
      _syncFromPlayer();
      return;
    }
    for (final entry in _entries) {
      final language = (entry.language ?? '').toLowerCase();
      if (language.isNotEmpty && keywords.any(language.contains)) {
        unawaited(_apply(entry, userInitiated: false));
        return;
      }
    }
    _syncFromPlayer();
  }

  /// 用户手动选择音轨。
  Future<void> select(AudioTrackEntry entry) async {
    _userChosen = true;
    await _apply(entry, userInitiated: true);
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

  @override
  void dispose() {
    _disposed = true;
    unawaited(_teardown());
    _player = null;
    super.dispose();
  }
}
