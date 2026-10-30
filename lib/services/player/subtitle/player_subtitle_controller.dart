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
import 'package:kazumi/services/player/track_memory.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/utils/episode_number.dart';
import 'package:kazumi/utils/track_matching.dart';
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

  /// 本集记忆：只按这一个视频恢复，不跨集沿用。
  String _videoKey = '';
  bool _memoryChecked = false;
  bool _hasMemory = false;

  String _videoUrl = '';
  bool _isLocalPlayback = false;
  Map<String, String> _headers = const {};

  List<SubtitleEntry> _embeddedEntries = const [];
  final List<SubtitleEntry> _externalEntries = [];

  /// mpv 原始字幕轨（含 `sub-add` 加进来的外挂轨）。
  List<SubtitleEntry> _rawTrackEntries = const [];

  /// mpv `track-list` 里每条字幕轨的附加信息。
  Map<String, _MpvSubtitleTrack> _trackMeta = const {};
  String _lastTrackListRaw = '';
  bool _trackMetaLoading = false;

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

  /// 本集是否有记住的手动选择。
  bool get hasRememberedSelection => _hasMemory;

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
    _videoKey = TrackMemoryStore.keyFor(videoUrl);
    _memoryChecked = false;
    _hasMemory = false;
    _rawTrackEntries = const [];
    _trackMeta = const {};
    _lastTrackListRaw = '';
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
    unawaited(_refreshTrackMeta());

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
    _sortExternalEntries();
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
    // 只解析「与当前视频匹配」的字幕，避免把同目录其它集的字体也下载一遍。
    final files = <String>{};
    final selected = _selected;
    if (selected != null && selected.isExternal && selected.uri != null) {
      files.add(selected.uri!);
    }
    for (final entry in _matchingExternalEntries()) {
      if (entry.uri != null) {
        files.add(entry.uri!);
      }
    }
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
    _rawTrackEntries = tracks.subtitle
        .where((track) => track.id != 'auto' && track.id != 'no')
        .map(SubtitleEntry.fromTrack)
        .toList(growable: false);
    _applyTrackFilter();
    _tracksSeen = true;

    final player = _player;
    if (_selected == null && !_userChosen && player != null) {
      final current = player.state.track.subtitle;
      if (current.id != 'auto' && current.id != 'no') {
        for (final entry in _embeddedEntries) {
          if (entry.id == current.id) {
            _selected = entry;
            break;
          }
        }
      }
    }
    _notify();
    unawaited(_refreshTrackMeta());
    _autoSelectIfReady();
  }

  /// 按 mpv 的 `external` 标记把播放器自己加载的外挂轨从「内封」里剔掉。
  ///
  /// 选外挂字幕时 media_kit 走的是 `sub-add`，mpv 会把它当成一条新轨道，
  /// 而 `player.stream.tracks` 不区分内外，不过滤就会出现同一个文件
  /// 在「内封」和「外挂」里各出现一次。
  void _applyTrackFilter() {
    final meta = _trackMeta;
    if (meta.isEmpty) {
      _embeddedEntries = _rawTrackEntries;
      return;
    }
    final embedded = <SubtitleEntry>[];
    for (final entry in _rawTrackEntries) {
      final info = meta[entry.id];
      if (info != null && info.external) {
        continue;
      }
      embedded.add(entry.copyWith(
        forced: info?.forced ?? entry.forced,
        image: info?.image ?? entry.image,
      ));
    }
    _embeddedEntries = embedded;

    final selected = _selected;
    if (selected != null && selected.isEmbedded) {
      final info = meta[selected.id];
      if (info != null && info.external) {
        _selected = _externalEntryForTrack(info, selected);
      }
    }
  }

  Future<void> _refreshTrackMeta() async {
    final player = _player;
    if (player == null || _disposed || _trackMetaLoading) {
      return;
    }
    final platform = player.platform;
    if (platform is! NativePlayer) {
      return;
    }
    _trackMetaLoading = true;
    try {
      final raw = await platform.getProperty('track-list');
      if (_disposed || !identical(_player, player)) {
        return;
      }
      if (raw == _lastTrackListRaw) {
        return;
      }
      _lastTrackListRaw = raw;
      _trackMeta = _parseTrackList(raw);
      _applyTrackFilter();
      _notify();
      _autoSelectIfReady();
    } catch (error) {
      KazumiLogger().w(
        'PlayerSubtitleController: failed to read mpv track-list',
        error: error,
      );
    } finally {
      _trackMetaLoading = false;
    }
  }

  Map<String, _MpvSubtitleTrack> _parseTrackList(String raw) {
    final result = <String, _MpvSubtitleTrack>{};
    if (raw.isEmpty) {
      return result;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return result;
      }
      for (final item in decoded) {
        if (item is! Map || item['type'] != 'sub') {
          continue;
        }
        final id = item['id']?.toString() ?? '';
        if (id.isEmpty) {
          continue;
        }
        result[id] = _MpvSubtitleTrack(
          external: item['external'] == true,
          forced: item['forced'] == true,
          image: item['image'] == true,
          filename: item['external-filename']?.toString(),
        );
      }
    } catch (_) {
      // 解析失败就当作没有附加信息。
    }
    return result;
  }

  SubtitleEntry? _externalEntryForTrack(
    _MpvSubtitleTrack info,
    SubtitleEntry fallback,
  ) {
    final filename = info.filename;
    if (filename == null || filename.isEmpty) {
      return null;
    }
    final path = filename.startsWith('file://')
        ? Uri.parse(filename).toFilePath()
        : filename;
    final base = p.basename(path);
    for (final entry in _externalEntries) {
      final entryName = entry.uri != null ? p.basename(entry.uri!) : entry.title;
      if (entryName.toLowerCase() == base.toLowerCase()) {
        return entry;
      }
    }
    return SubtitleEntry(
      id: path,
      title: base,
      rawTitle: base,
      kind: SubtitleEntryKind.external,
      uri: path,
      codec: p.extension(base).replaceFirst('.', '').toUpperCase(),
    );
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

  /// 自动挑字幕：有外挂就用外挂（中文优先），没有外挂才走内封规则。
  ///
  /// 和旧版的区别：
  /// * 外挂匹配不上时不再关字幕，改为「候选里没有中文就按名称拿第一条」；
  /// * 有外挂时不再退回内封（用户的片库习惯是外挂优先）；
  /// * 自动选择跳过 forced 轨（只翻译外语对白的字幕）。
  void _autoSelectIfReady({bool fromTimer = false}) {
    if (_autoApplied || _userChosen || _disposed) {
      return;
    }
    if (!_tracksSeen || (!_externalLoaded && !fromTimer)) {
      return;
    }
    // 本集记忆优先于任何自动规则；只恢复一次。
    if (!_memoryChecked && _externalLoaded) {
      _memoryChecked = true;
      if (_restoreFromMemory()) {
        return;
      }
    }
    if (!GStorage.getSetting(SettingsKeys.autoSelectSubtitle)) {
      _autoApplied = true;
      return;
    }
    if (allEntries.isEmpty) {
      // 轨道/外挂字幕可能来得晚，先不落锁。
      return;
    }
    if (_externalEntries.isNotEmpty) {
      final pick = _pickExternalForVideo();
      _autoApplied = true;
      if (pick != null) {
        unawaited(_applySelection(pick));
        KazumiLogger().i(
            'PlayerSubtitleController: auto-selected external subtitle "${pick.title}"');
      } else {
        unawaited(_applySelection(null));
        KazumiLogger().i(
            'PlayerSubtitleController: no external subtitle available, subtitle off');
      }
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
    // 没匹配到中文：唯一轨道就用它；否则退回「文件默认字幕」，不会把字幕关掉。
    if (allEntries.length == 1) {
      unawaited(_applySelection(allEntries.first));
    } else {
      unawaited(_applyDefaultWhenNoChinese());
    }
  }

  /// 恢复本集上次手动选择的字幕。
  bool _restoreFromMemory() {
    if (_videoKey.isEmpty || !TrackMemoryStore.instance.enabled) {
      return false;
    }
    final memory = TrackMemoryStore.instance.readSubtitle(_videoKey);
    if (memory == null) {
      return false;
    }
    switch (memory.kind) {
      case SubtitleMemoryKind.off:
        _userChosen = true;
        _autoApplied = true;
        _hasMemory = true;
        unawaited(_applySelection(null));
        KazumiLogger().i(
            'PlayerSubtitleController: restored "off" from memory ($_videoKey)');
        return true;
      case SubtitleMemoryKind.external:
        final entry = _findExternalByMemory(memory);
        if (entry == null) {
          return false;
        }
        _userChosen = true;
        _autoApplied = true;
        _hasMemory = true;
        unawaited(_applySelection(entry));
        KazumiLogger().i(
            'PlayerSubtitleController: restored external "${entry.title}" from memory');
        return true;
      case SubtitleMemoryKind.embedded:
        final entry = _findEmbeddedByMemory(memory);
        if (entry == null) {
          return false;
        }
        _userChosen = true;
        _autoApplied = true;
        _hasMemory = true;
        unawaited(_applySelection(entry));
        KazumiLogger().i(
            'PlayerSubtitleController: restored embedded "${entry.title}" from memory');
        return true;
    }
  }

  SubtitleEntry? _findExternalByMemory(SubtitleMemory memory) {
    final name = (memory.name ?? '').toLowerCase();
    if (name.isEmpty) {
      return null;
    }
    for (final entry in _externalEntries) {
      final title = entry.title.toLowerCase();
      final file = entry.uri == null ? '' : p.basename(entry.uri!).toLowerCase();
      if (title == name || file == name) {
        return entry;
      }
    }
    final candidates = memory.candidates ?? const [];
    for (final entry in _externalEntries) {
      if (candidates.contains(entry.title)) {
        return entry;
      }
    }
    return null;
  }

  SubtitleEntry? _findEmbeddedByMemory(SubtitleMemory memory) {
    final language = _normalizeLanguage(memory.language);
    final name = (memory.name ?? '').toLowerCase();
    for (final entry in _embeddedEntries) {
      if (_normalizeLanguage(entry.language) != language) {
        continue;
      }
      final title = (entry.rawTitle ?? entry.title).toLowerCase();
      if (name.isEmpty || title == name) {
        return entry;
      }
    }
    for (final entry in _embeddedEntries) {
      final title = (entry.rawTitle ?? entry.title).toLowerCase();
      if (name.isNotEmpty && title == name) {
        return entry;
      }
    }
    final candidates = memory.candidates ?? const [];
    for (final entry in _embeddedEntries) {
      if (candidates.contains(entry.title)) {
        return entry;
      }
    }
    return null;
  }

  String _normalizeLanguage(String? language) {
    final value = (language ?? '').trim().toLowerCase();
    if (value == 'chi' || value == 'zho' || value.startsWith('zh')) {
      return 'zh';
    }
    return value;
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
                Map target = subtitles.first;
                for (final track in subtitles) {
                  if (track['default'] == true) {
                    target = track;
                    break;
                  }
                }
                // 文件把 forced 轨标成默认时，优先换一条非 forced 的。
                if (target['forced'] == true) {
                  for (final track in subtitles) {
                    if (track['forced'] != true) {
                      target = track;
                      break;
                    }
                  }
                }
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
      if (entry.isEmbedded && !entry.forced) {
        return entry;
      }
    }
    for (final entry in allEntries) {
      if (entry.isEmbedded) {
        return entry;
      }
    }
    return allEntries.isEmpty ? null : allEntries.first;
  }

  String get _videoFileName {
    final uri = Uri.tryParse(_videoUrl);
    final segments =
        uri?.pathSegments.where((segment) => segment.isNotEmpty).toList() ??
            const <String>[];
    if (segments.isEmpty) {
      return '';
    }
    return Uri.decodeComponent(segments.last);
  }

  /// 去掉最后一个扩展名（视频的 .mkv 和字幕的 .ass 都要去掉），
  /// 不猜语言后缀：`foo.sc.ass` 只去掉 `.ass`，保留 `.sc`。
  static String _subtitleBaseName(String name) {
    var value = name.toLowerCase().trim();
    final dot = value.lastIndexOf('.');
    if (dot > 0) {
      value = value.substring(0, dot);
    }
    return value.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// 选集面板按「当前视频」排序：同文件名 → 同集数 → 简体 → 繁体 → 其它。
  void _sortExternalEntries() {
    final videoName = _videoFileName;
    if (videoName.isEmpty) {
      return;
    }
    final videoBase = _subtitleBaseName(videoName);
    final videoEpisode = parseEpisodeNumber(videoName);
    int rank(SubtitleEntry entry) {
      if (_subtitleBaseName(entry.title) == videoBase) {
        return 0;
      }
      if (videoEpisode != null) {
        final episode = parseEpisodeNumber(entry.title);
        if (episode != null && episode == videoEpisode) {
          return 1;
        }
      }
      return 2;
    }

    _externalEntries.sort((a, b) {
      final rankDiff = rank(a).compareTo(rank(b));
      if (rankDiff != 0) {
        return rankDiff;
      }
      final languageA = _chineseRank(a) ?? 3;
      final languageB = _chineseRank(b) ?? 3;
      if (languageA != languageB) {
        return languageA.compareTo(languageB);
      }
      return a.title.compareTo(b.title);
    });
  }

  /// 与当前视频匹配的外挂字幕，按档位取最近的一档：
  /// 文件名完全相同 → 集数相同 → 同片不同压制。
  List<SubtitleEntry> _matchingExternalEntries() {
    final candidates = _externalCandidates();
    if (candidates.isNotEmpty) {
      return candidates;
    }
    final selected = _selected;
    if (selected != null && selected.isExternal) {
      return [selected];
    }
    return const [];
  }

  List<SubtitleEntry> _externalCandidates() {
    final videoName = _videoFileName;
    if (videoName.isEmpty || _externalEntries.isEmpty) {
      return const [];
    }
    final videoBase = _subtitleBaseName(videoName);
    final videoEpisode = parseEpisodeNumber(videoName);
    final exact = <SubtitleEntry>[];
    final sameEpisode = <SubtitleEntry>[];
    final sameTitle = <SubtitleEntry>[];
    for (final entry in _externalEntries) {
      if (_subtitleBaseName(entry.title) == videoBase) {
        exact.add(entry);
        continue;
      }
      if (videoEpisode != null) {
        final episode = parseEpisodeNumber(entry.title);
        if (episode != null && episode == videoEpisode) {
          sameEpisode.add(entry);
          continue;
        }
      }
      // 同片不同压制：标题词重合，且两边集数不冲突（电影没有集数）。
      if (!episodesConflict(videoName, entry.title) &&
          titleSimilarity(videoName, entry.title) >= 0.55) {
        sameTitle.add(entry);
      }
    }
    if (exact.isNotEmpty) {
      return exact;
    }
    if (sameEpisode.isNotEmpty) {
      return sameEpisode;
    }
    return sameTitle;
  }

  /// 自动选外挂字幕：候选里中文优先（简 → 繁 → 中文）；
  /// 候选里没有中文就按名称选第一条；一档都没匹配上就全目录按名称第一条。
  SubtitleEntry? _pickExternalForVideo() {
    if (_externalEntries.isEmpty) {
      return null;
    }
    final candidates = _externalCandidates();
    final pool = candidates.isEmpty ? _externalEntries : candidates;
    final chinese = pool.where((entry) => _chineseRank(entry) != null).toList();
    if (chinese.isEmpty) {
      return _firstByTitle(pool);
    }
    final videoName = _videoFileName;
    chinese.sort((a, b) {
      final rankA = _chineseRank(a)!;
      final rankB = _chineseRank(b)!;
      if (rankA != rankB) {
        return rankA.compareTo(rankB);
      }
      final technicalA = technicalOverlap(videoName, a.title);
      final technicalB = technicalOverlap(videoName, b.title);
      if (technicalA != technicalB) {
        return technicalB.compareTo(technicalA);
      }
      final similarityA = titleSimilarity(videoName, a.title);
      final similarityB = titleSimilarity(videoName, b.title);
      if (similarityA != similarityB) {
        return similarityB.compareTo(similarityA);
      }
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });
    return chinese.first;
  }

  SubtitleEntry? _firstByTitle(List<SubtitleEntry> entries) {
    if (entries.isEmpty) {
      return null;
    }
    final sorted = [...entries]
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return sorted.first;
  }

  SubtitleEntry? _pickPreferredEntry() {
    int? bestRank;
    SubtitleEntry? best;
    // forced 轨只翻译外语对白，自动选择时跳过；只有全是 forced 才用它。
    final usable = allEntries.where((entry) => !entry.forced).toList();
    final pool = usable.isEmpty ? allEntries : usable;
    for (final entry in pool) {
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
    _rememberSelection(entry);
  }

  /// 记住本集手动选择；关字幕记为 `off`。
  void _rememberSelection(SubtitleEntry? entry) {
    final key = _videoKey;
    if (key.isEmpty) {
      return;
    }
    _hasMemory = true;
    if (entry == null) {
      unawaited(TrackMemoryStore.instance.writeSubtitle(
        key,
        const SubtitleMemory(kind: SubtitleMemoryKind.off),
      ));
      return;
    }
    if (entry.isExternal) {
      unawaited(TrackMemoryStore.instance.writeSubtitle(
        key,
        SubtitleMemory(
          kind: SubtitleMemoryKind.external,
          name: entry.title,
          language: entry.language,
          candidates: _externalEntries.map((item) => item.title).toList(),
        ),
      ));
      return;
    }
    final candidates = _embeddedEntries
        .where((item) =>
            _normalizeLanguage(item.language) ==
            _normalizeLanguage(entry.language))
        .map((item) => item.title)
        .toList();
    unawaited(TrackMemoryStore.instance.writeSubtitle(
      key,
      SubtitleMemory(
        kind: SubtitleMemoryKind.embedded,
        name: entry.rawTitle ?? entry.title,
        language: entry.language,
        candidates: candidates,
      ),
    ));
  }

  /// 清掉本集的字幕记忆（面板里「清除记忆」用）。
  Future<void> clearRememberedSelection() async {
    if (_videoKey.isEmpty) {
      return;
    }
    await TrackMemoryStore.instance.clear(_videoKey);
    _hasMemory = false;
    _userChosen = false;
    _autoApplied = false;
    _memoryChecked = true;
    _notify();
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
    _rawTrackEntries = const [];
    _trackMeta = const {};
    _lastTrackListRaw = '';
    _videoKey = '';
    _memoryChecked = false;
    _hasMemory = false;
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

/// mpv `track-list` 里一条字幕轨的附加信息。
class _MpvSubtitleTrack {
  const _MpvSubtitleTrack({
    required this.external,
    required this.forced,
    required this.image,
    this.filename,
  });

  /// 由 `sub-add` 加进来的外挂轨。
  final bool external;
  final bool forced;
  final bool image;

  /// 外挂轨对应的本地文件（mpv `external-filename`）。
  final String? filename;
}
