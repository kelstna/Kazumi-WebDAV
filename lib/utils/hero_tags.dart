// SPDX-FileCopyrightText: Copyright (C) 2026 kelstna (AI-assisted modification, see NOTICE.md)
// SPDX-License-Identifier: GPL-3.0-only

import 'package:flutter/foundation.dart';

/// 各 tab 页「回到顶部」FAB 的 Hero tag。
///
/// 每个页面用独立 tag，避免多页面同时存在时同一个 tag 冲突；
/// 详情页的「开始观看」通过 [activeStartWatchingHeroTag] 动态匹配
/// 当前 tab 的 tag，从而保留形变动画。
const String kPopularBackToTopHero = 'kazumi-back-to-top-popular';
const String kTimelineBackToTopHero = 'kazumi-back-to-top-timeline';
const String kCollectBackToTopHero = 'kazumi-back-to-top-collect';

/// 当前可见的「回到顶部」FAB 的 Hero tag；没有可见按钮时为 null。
final ValueNotifier<String?> activeStartWatchingHeroTag =
    ValueNotifier<String?>(null);

/// 页面滚动时维护当前可见的 FAB tag。
void updateStartWatchingHero(String tag, bool visible) {
  if (visible) {
    activeStartWatchingHeroTag.value = tag;
  } else if (activeStartWatchingHeroTag.value == tag) {
    activeStartWatchingHeroTag.value = null;
  }
}
