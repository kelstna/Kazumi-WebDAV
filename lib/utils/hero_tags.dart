// SPDX-FileCopyrightText: Copyright (C) 2026 kelstna (AI-assisted modification, see NOTICE.md)
// SPDX-License-Identifier: GPL-3.0-only

import 'package:flutter/material.dart';

/// 「回到顶部」FAB 与详情页「开始观看」共用的 Hero tag。
///
/// 推荐 / 时间表 / 追番 是同一嵌套 Navigator 里的不同路由，
/// 每个路由各有一个 FAB，所以可以安全地共用同一个 tag；
/// 详情页用同一个 tag 就能和任意来源页的 FAB 对接。
const String kBackToTopHeroTag = 'kazumi-back-to-top';

/// 显式 Hero：统一控制 push/pop 的飞行 widget。
///
/// 默认 FAB Hero 在 pop 时会把「回到顶部」箭头画出来；
/// 这里 push 和 pop 都使用「开始观看」按钮本身：
/// - push：从小矩形长成「开始观看」；
/// - pop：从「开始观看」缩回小矩形，结束后目标才可见。
class StartWatchingHero extends StatelessWidget {
  const StartWatchingHero({
    super.key,
    required this.tag,
    required this.child,
  });

  final Object tag;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Hero(
      tag: tag,
      flightShuttleBuilder: (flightContext, animation, direction,
          fromHeroContext, toHeroContext) {
        final from = (fromHeroContext.widget as Hero).child;
        final to = (toHeroContext.widget as Hero).child;
        // push/pop 都显示「开始观看」按钮本身，并整体等比缩放，
        // 这样文字和三角图标会和按钮一起变小/变大，而不是只缩放背景。
        final button = direction == HeroFlightDirection.push ? to : from;
        return FittedBox(
          fit: BoxFit.contain,
          alignment: Alignment.center,
          child: button,
        );
      },
      child: child,
    );
  }
}

/// 右下角「回到顶部」按钮。
///
/// - 顶部时缩放到 0（不可见、不可点），但 Hero 目标仍保留；
/// - 离开顶部时从 0 放大到 1，回到顶部时缩回 0。
///
/// 缩放放在 Hero 外面，Hero 的目标矩形始终是 40×40，形变时不会忽大忽小。
class BackToTopHeroFab extends StatelessWidget {
  const BackToTopHeroFab({
    super.key,
    required this.visible,
    required this.onPressed,
  });

  final bool visible;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedScale(
        scale: visible ? 1 : 0,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        child: StartWatchingHero(
          tag: kBackToTopHeroTag,
          child: FloatingActionButton.small(
            heroTag: null,
            tooltip: '回到顶部',
            onPressed: onPressed,
            child: const Icon(Icons.arrow_upward_rounded),
          ),
        ),
      ),
    );
  }
}
