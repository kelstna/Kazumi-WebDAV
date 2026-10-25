// SPDX-FileCopyrightText: Copyright (C) 2026 kelstna (AI-assisted modification, see NOTICE.md)
// SPDX-License-Identifier: GPL-3.0-only

import 'package:flutter/foundation.dart';
import 'package:kazumi/services/player/subtitle/webdav_font_service.dart';

enum FontIndexPhase { idle, listing, reading, done, error }

/// App 级字体索引任务：离开设置页后继续运行，页面只监听进度。
class FontIndexJob {
  FontIndexJob._();

  static final FontIndexJob instance = FontIndexJob._();

  final ValueNotifier<FontIndexPhase> phase =
      ValueNotifier<FontIndexPhase>(FontIndexPhase.idle);
  final ValueNotifier<int> done = ValueNotifier<int>(0);
  final ValueNotifier<int> total = ValueNotifier<int>(0);
  final ValueNotifier<int> directories = ValueNotifier<int>(0);
  final ValueNotifier<int> files = ValueNotifier<int>(0);
  final ValueNotifier<String> message = ValueNotifier<String>('');

  bool _running = false;
  bool _cancelRequested = false;

  bool get isRunning => _running;

  Future<void> start({bool force = false}) async {
    if (_running) {
      return;
    }
    _running = true;
    _cancelRequested = false;
    phase.value = FontIndexPhase.listing;
    done.value = 0;
    total.value = 0;
    directories.value = 0;
    files.value = 0;
    message.value = '正在扫描目录…';
    try {
      final count = await WebDavFontService.instance.buildIndex(
        onListing: (dirs, count) {
          directories.value = dirs;
          files.value = count;
          phase.value = FontIndexPhase.listing;
        },
        onProgress: (finished, count) {
          done.value = finished;
          total.value = count;
          phase.value = FontIndexPhase.reading;
        },
        shouldCancel: () => _cancelRequested,
        force: force,
      );
      _running = false;
      if (_cancelRequested) {
        phase.value = FontIndexPhase.idle;
        message.value = '已取消';
      } else {
        phase.value = FontIndexPhase.done;
        message.value = '索引完成：$count 个字体';
      }
    } on FontIndexCancelled {
      _running = false;
      phase.value = FontIndexPhase.idle;
      message.value = '已取消';
    } catch (error) {
      _running = false;
      phase.value = FontIndexPhase.error;
      message.value = '建立索引失败：$error';
    } finally {
      _running = false;
    }
  }

  void cancel() {
    if (_running) {
      _cancelRequested = true;
    }
  }
}
