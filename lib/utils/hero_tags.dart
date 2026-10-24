// SPDX-FileCopyrightText: Copyright (C) 2026 kelstna (AI-assisted modification, see NOTICE.md)
// SPDX-License-Identifier: GPL-3.0-only

/// 「开始观看」和首页「回到顶部」共用的 Hero tag。
///
/// 两个页面都用同一个 tag，返回时 FAB 会在两个位置之间平滑形变；
/// 首页在顶部时「回到顶部」不构建（floatingActionButton 为 null），
/// 没有目标 Hero，就不会出现空飞的箭头。
const String kStartWatchingHeroTag = 'kazumi-start-watching';
