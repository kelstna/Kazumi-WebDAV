// SPDX-FileCopyrightText: Copyright (C) 2026 kelstna (AI-assisted modification, see NOTICE.md)
// SPDX-License-Identifier: GPL-3.0-only

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/openlist/openlist_service.dart';
import 'package:kazumi/services/player/subtitle/subtitle_entry.dart';
import 'package:kazumi/services/player/subtitle/subtitle_font_service.dart';
import 'package:kazumi/services/player/subtitle/subtitle_repository.dart';
import 'package:kazumi/services/player/subtitle/webdav_font_service.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;

/// 播放器字幕状态。
///
/// 负责三件事：
/// 1. 从 media_kit（mpv）拿到内封字幕轨道列表；
/// 2. 发现外挂字幕（本地同目录 / anime-server 侧）；
/// 3. 把用户选择写回播放器（`sid` / `sub-add`）、字幕延迟，以及开播时
///    「简体 → 繁体 → 默认字幕」的自动选择。
class PlayerSubtitleController extends ChangeNotifier {
  PlayerSubtitleController({SubtitleRepository? repository})
      : _repository = repository ?? SubtitleRepository();

  final SubtitleRepository _repository;
  final SubtitleFontService fontService = SubtitleFontService();

  Player? _player;
  StreamSubscription<Tracks>? _tracksSubscription;
  StreamSubscription<Track>? _trackSubscription;
  bool _disposed = false;

  /// 用户在本集内手动选过字幕（含「关闭」），之后不再自动干预。
  bool _userChosen = false;
  bool _autoApplied = false;
  bool _tracksSeen = false;
  bool _externalLoaded = false;

  String _videoUrl = '';
  bool _isLocalPlayback = false;
  Map<String, String> _headers = const {};

  List<SubtitleEntry> _embeddedEntries = const [];
  final List<SubtitleEntry> _externalEntries = [];

  SubtitleEntry? _selected;
  bool _loading = false;
  String? _error;
  int _delayMs = 0;

  List<SubtitleEntry> get embeddedEntries => _embeddedEntries;

  List<SubtitleEntry> get externalEntries => List.unmodifiable(_externalEntries);

  List<SubtitleEntry> get allEntries => [..._embeddedEntries, ..._externalEntries];

  SubtitleEntry? get selected => _selected;

  bool get enabled => _selected != null;

  bool get loading => _loading;

  String? get error => _error;

  int get delayMs => _delayMs;

  bool get hasAnySubtitle => allEntries.isNotEmpty;

  bool get isAttached => _player != null;

  /// 每次开播后调用：清空上一集的字幕状态并重新发现。
  Future<void> attach(
    Player player, {
    required String videoUrl,
    required bool isLocalPlayback,
    Map<String, String> headers = const {},
  }) async {
    await _teardownSubscriptions();
    _player = player;
    _videoUrl = videoUrl;
    _isLocalPlayback = isLocalPlayback;
    _headers = headers;
    _embeddedEntries = const [];
    _externalEntries.clear();
    _selected = null;
    _delayMs = 0;
    _userChosen = false;
    _autoApplied = false;
    _tracksSeen = false;
    _externalLoaded = false;
    _error = null;
    _loading = true;
    _notify();

    _tracksSubscription = player.stream.tracks.listen(_onTracks);
    _trackSubscription = player.stream.track.listen(_onCurrentTrackChanged);
    _onTracks(player.state.tracks);

    unawaited(_configureLibass(player));
    unawaited(_prepareFonts(player));
    unawaited(_loadExternalSubtitles(player));

    // 网络 MKV 的轨道列表可能比 open() 晚一点到，给自动选择一个兜底时机。
    unawaited(Future<void>.delayed(const Duration(seconds: 2),
        () => _autoSelectIfReady(fromTimer: true)));
  }

  /// libass 在 Android 上必须由 media_kit 提供内置字体（见 PlayerConfiguration），
  /// 这里只补一个开关：把 MKV 附件里的字体交给 libass。
  Future<void> _configureLibass(Player player) async {
    try {
      final nativePlayer = player.platform as NativePlayer;
      await nativePlayer.setProperty('embeddedfonts', 'yes');
    } catch (error) {
      KazumiLogger()
          .w('PlayerSubtitleController: failed to configure libass', error: error);
    }
  }

  Future<void> _loadExternalSubtitles(Player player) async {
    final entries = await _repository.discover(
      videoUrl: _videoUrl,
      isLocalPlayback: _isLocalPlayback,
      headers: _headers,
    );
    if (!identical(_player, player) || _disposed) {
      return;
    }
    _externalEntries
      ..clear()
      ..addAll(entries);
    _externalLoaded = true;
    _loading = false;
    _notify();
    _autoSelectIfReady();
    unawaited(_applyExternalFonts(player));
  }

  /// 字体目录：内置 MiSans + 手机字体库（Download/KazumiFonts）。
  Future<void> _prepareFonts(Player player) async {
    try {
      await fontService.prepare();
      WebDavFontService.instance.invalidateLocalIndex();
      if (!identical(_player, player) || _disposed) {
        return;
      }
      await fontService.applyToPlayer(player);
    } catch (error) {
      KazumiLogger()
          .w('PlayerSubtitleController: failed to prepare fonts', error: error);
    }
  }

  /// 解析外挂 ASS 引用的字体，缺的从服务器字体库拉取，然后让 libass 重扫。
  Future<void> _applyExternalFonts(Player player) async {
    final files = _externalEntries
        .map((entry) => entry.uri)
        .whereType<String>()
        .toList(growable: false);
    if (files.isEmpty) {
      return;
    }
    try {
      final names = await fontService.assFontNames(files);
      if (names.isEmpty || !identical(_player, player) || _disposed) {
        return;
      }
      final base = _serverBase();
      var installed = 0;
      if (base != null) {
        installed += await fontService.ensureFontsFromServer(
          serverBase: base,
          names: names,
          headers: _headers,
        );
      } else if (OpenListService.instance.isOpenListUrl(_videoUrl)) {
        installed += await WebDavFontService.instance.ensureFonts(names);
      }
      if (!identical(_player, player) || _disposed) {
        return;
      }
      if (installed == 0) {
        // 没有新字体也执行一次 apply，确保 sub-fonts-dir 已经设上。
        await fontService.applyToPlayer(player);
        return;
      }
      await fontService.applyToPlayer(player);
      await fontService.reload(player);
      // 字体刚补齐，重新加载一次当前外挂字幕，让 libass 用新字体重新排版。
      final selected = _selected;
      if (selected != null && selected.isExternal) {
        await _applySelection(selected);
      }
    } catch (error) {
      KazumiLogger().w('PlayerSubtitleController: font sync failed',
          error: error);
    }
  }

  String? _serverBase() {
    if (_isLocalPlayback || !_videoUrl.contains('://')) {
      return null;
    }
    // OpenList 来源没有字体接口，别去它上面白跑一趟。
    if (OpenListService.instance.isOpenListUrl(_videoUrl)) {
      return null;
    }
    final uri = Uri.tryParse(_videoUrl);
    if (uri == null || uri.host.isEmpty) {
      return null;
    }
    return '${uri.scheme}://${uri.authority}';
  }

  void _onTracks(Tracks tracks) {
    final embedded = tracks.subtitle
        .where((track) => track.id != 'auto' && track.id != 'no')
        .map(SubtitleEntry.fromTrack)
        .toList(growable: false);
    _embeddedEntries = embedded;
    _tracksSeen = true;

    final player = _player;
    if (_selected == null && !_userChosen && player != null) {
      final current = player.state.track.subtitle;
      if (current.id != 'auto' && current.id != 'no') {
        for (final entry in embedded) {
          if (entry.id == current.id) {
            _selected = entry;
            break;
          }
        }
      }
    }
    _notify();
    _autoSelectIfReady();
  }

  void _onCurrentTrackChanged(Track track) {
    // 用户没手动选过时，跟随播放器实际选中的轨道（mpv 按 default 标记选的那条）。
    if (!_userChosen && _selected == null) {
      final id = track.subtitle.id;
      if (id != 'auto' && id != 'no') {
        for (final entry in allEntries) {
          if (entry.id == id) {
            _selected = entry;
            _notify();
            return;
          }
        }
      }
    }
    if (_selected != null && _selected!.isEmbedded) {
      final stillThere =
          _embeddedEntries.any((entry) => entry.id == _selected!.id);
      if (!stillThere) {
        _selected = null;
        _notify();
      }
    }
  }

  /// 自动挑字幕：简体 → 繁体 → 唯一/默认。不会把字幕关掉。
  void _autoSelectIfReady({bool fromTimer = false}) {
    if (_autoApplied || _userChosen || _disposed) {
      return;
    }
    if (!_tracksSeen || (!_externalLoaded && !fromTimer)) {
      return;
    }
    if (!GStorage.getSetting(SettingsKeys.autoSelectSubtitle)) {
      _autoApplied = true;
      return;
    }
    if (allEntries.isEmpty) {
      // 还没有任何字幕（轨道/外挂字幕可能来得晚），先不落锁。
      return;
    }
    final pick = _pickPreferredEntry();
    _autoApplied = true;
    if (pick != null) {
      unawaited(_applySelection(pick));
      KazumiLogger().i(
          'PlayerSubtitleController: auto-selected subtitle "${pick.title}"');
      return;
    }
    // 没匹配到中文：唯一轨道就用它；否则退回「文件默认字幕」（mpv 的
    // default 标记，没有标记时用第一条字幕轨），不会把字幕关掉。
    if (allEntries.length == 1) {
      unawaited(_applySelection(allEntries.first));
    } else {
      unawaited(_applyDefaultWhenNoChinese());
    }
  }

  Future<void> _applyDefaultWhenNoChinese() async {
    final entry = await _pickDefaultEntry();
    if (entry == null || _userChosen || _disposed) {
      return;
    }
    await _applySelection(entry);
    KazumiLogger().i(
        'PlayerSubtitleController: auto-selected default subtitle "${entry.title}"');
  }

  /// 找到「默认字幕」：优先 mpv `track-list` 里 `default=yes` 的字幕轨，
  /// 其次第一条字幕轨、第一条内封轨，最后第一条外挂。
  Future<SubtitleEntry?> _pickDefaultEntry() async {
    final player = _player;
    if (player != null) {
      try {
        final platform = player.platform;
        if (platform is NativePlayer) {
          final raw = await platform.getProperty('track-list');
          if (raw.isNotEmpty) {
            final decoded = jsonDecode(raw);
            if (decoded is List) {
              final subtitles = decoded
                  .whereType<Map>()
                  .where((track) => track['type'] == 'sub')
                  .toList(growable: false);
              if (subtitles.isNotEmpty) {
                Map? target;
                for (final track in subtitles) {
                  if (track['default'] == true) {
                    target = track;
                    break;
                  }
                }
                target ??= subtitles.first;
                final id = target['id']?.toString();
                for (final entry in allEntries) {
                  if (entry.isEmbedded && entry.id == id) {
                    return entry;
                  }
                }
              }
            }
          }
        }
      } catch (error) {
        KazumiLogger().w(
          'PlayerSubtitleController: failed to read mpv track-list',
          error: error,
        );
      }
    }
    for (final entry in allEntries) {
      if (entry.isEmbedded) {
        return entry;
      }
    }
    return allEntries.isEmpty ? null : allEntries.first;
  }

  SubtitleEntry? _pickPreferredEntry() {
    int? bestRank;
    SubtitleEntry? best;
    for (final entry in allEntries) {
      final rank = _chineseRank(entry);
      if (rank == null) {
        continue;
      }
      if (best == null || _isBetter(entry, rank, best, bestRank!)) {
        best = entry;
        bestRank = rank;
      }
    }
    return best;
  }

  bool _isBetter(SubtitleEntry candidate, int rank, SubtitleEntry best, int bestRank) {
    if (rank != bestRank) {
      return rank < bestRank;
    }
    // 同档优先外挂字幕（一般是 ASS，可读性和样式都比内封 PGS 好）。
    if (candidate.isExternal != best.isExternal) {
      return candidate.isExternal;
    }
    return false;
  }

  /// 0=简体，1=繁体，2=中文（未标注简繁），null=不是中文。
  ///
  /// 只用**原始标题/语言/文件名**判断，不能用中文化后的展示名，
  /// 否则 `chi` 会被统一翻成「简体中文」，繁体轨也变成简体优先了。
  int? _chineseRank(SubtitleEntry entry) {
    final raw = '${entry.rawTitle ?? ''} ${entry.language ?? ''}'.toLowerCase();
    final name = entry.isExternal && (entry.uri ?? '').isNotEmpty
        ? p.basename(entry.uri!).toLowerCase()
        : '';
    final text = '$raw $name';

    bool cjk(List<String> keys) => keys.any(text.contains);
    bool token(List<String> keys) => keys.any((key) => RegExp(
            '(^|[^a-z0-9])${RegExp.escape(key)}([^a-z0-9]|\$)')
        .hasMatch(text));

    if (cjk(const ['简体', '简中', '簡體', '简']) ||
        token(const [
          'chs',
          'sc',
          'jpsc',
          'gb',
          'gbk',
          'zhs',
          'hans',
          'simplified',
        ])) {
      return 0;
    }
    if (cjk(const ['繁體', '繁体', '繁中', '繁']) ||
        token(const [
          'cht',
          'tc',
          'jptc',
          'big5',
          'zht',
          'hant',
          'traditional',
        ])) {
      return 1;
    }
    final language = (entry.language ?? '').toLowerCase();
    if (language == 'chi' ||
        language == 'zho' ||
        language == 'zh' ||
        language.startsWith('zh-') ||
        text.contains('中文') ||
        text.contains('中字')) {
      return 2;
    }
    return null;
  }

  Future<void> select(SubtitleEntry? entry) async {
    _userChosen = true;
    await _applySelection(entry);
  }

  Future<void> _applySelection(SubtitleEntry? entry) async {
    final player = _player;
    if (player == null) {
      return;
    }
    try {
      if (entry == null) {
        await player.setSubtitleTrack(SubtitleTrack.no());
      } else {
        await player.setSubtitleTrack(entry.toTrack());
      }
      _selected = entry;
      _notify();
      await _applyDelay();
    } catch (error) {
      KazumiLogger()
          .e('PlayerSubtitleController: failed to select subtitle', error: error);
      _error = '字幕切换失败';
      _notify();
    }
  }

  /// 手动添加一个字幕文件（外挂）。
  Future<void> addExternalFile(String path) async {
    final entry = SubtitleEntry(
      id: path,
      title: p.basename(path),
      rawTitle: p.basename(path),
      kind: SubtitleEntryKind.external,
      uri: path,
      codec: p.extension(path).replaceFirst('.', '').toUpperCase(),
    );
    if (!_externalEntries.any((item) => item.id == entry.id)) {
      _externalEntries.add(entry);
    }
    _notify();
    await select(entry);
    final player = _player;
    if (player != null) {
      unawaited(_applyExternalFonts(player));
    }
  }

  Future<void> refresh() async {
    final player = _player;
    if (player == null) {
      return;
    }
    _loading = true;
    _notify();
    await _loadExternalSubtitles(player);
  }

  /// 字幕延迟，正数表示字幕延后出现。
  Future<void> setDelay(int milliseconds) async {
    _delayMs = milliseconds.clamp(-600000, 600000);
    _notify();
    await _applyDelay();
  }

  Future<void> nudgeDelay(int deltaMs) => setDelay(_delayMs + deltaMs);

  Future<void> _applyDelay() async {
    final player = _player;
    if (player == null) {
      return;
    }
    try {
      final nativePlayer = player.platform as NativePlayer;
      await nativePlayer.setProperty(
        'sub-delay',
        (_delayMs / 1000).toStringAsFixed(3),
      );
    } catch (error) {
      KazumiLogger()
          .w('PlayerSubtitleController: failed to set sub-delay', error: error);
    }
  }

  Future<void> detach() async {
    await _teardownSubscriptions();
    _player = null;
    _embeddedEntries = const [];
    _externalEntries.clear();
    _selected = null;
    _loading = false;
    _error = null;
    _delayMs = 0;
    _userChosen = false;
    _autoApplied = false;
    _tracksSeen = false;
    _externalLoaded = false;
    _notify();
  }

  Future<void> _teardownSubscriptions() async {
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
    unawaited(_teardownSubscriptions());
    _player = null;
    super.dispose();
  }
}
