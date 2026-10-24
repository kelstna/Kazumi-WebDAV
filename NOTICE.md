# NOTICE — Kazumi-WebDAV（非官方修改版）

本仓库是 [Predidit/Kazumi](https://github.com/Predidit/Kazumi) 的**非官方修改版（fork）**，
由 **kelstna** 维护，修改过程有 **AI 参与**。本项目与原项目作者无关，也未获得其背书。

- 上游仓库：https://github.com/Predidit/Kazumi
- 基线版本：2.3.9（上游 `main` commit `184f8db5`，2026-10-20）
- 修改日期：2026-10-23
- 修改者：kelstna
- 许可证：GNU General Public License v3.0（`GPL-3.0-only`，见 `LICENSE`）

## 修改内容

相对基线 commit，本仓库主要增加/调整了以下功能：

1. **本地 / WebDAV 片库来源**：内置一个通用 WebDAV 来源（PROPFIND + Basic Auth +
   HTTP Range），可直接播放 WebDAV 上的原始文件，不依赖 anime-server；
   搜索、集数、外挂字幕都走同一套 WebDAV 目录。
2. **字幕选择**：内封字幕轨、同目录外挂字幕（ass/srt/vtt 等）统一进字幕菜单，
   自动优先简体、次选繁体、再次中文；外挂字幕下载到缓存后交给 libass。
3. **多音轨选择**：内封音轨列表与切换，默认音轨自动选中。
4. **ASS 字体适配**：扫描 ASS 的 `Style` 字体名，A（本地导入）/ B（服务器字体库）两条路线，
   通过 `sub-fonts-dir` / `sub-ass` 交给 libass。
5. **追番 / 时间表界面**：标题栏随滚动收起、分类栏吸顶、回到顶部按钮、
   NestedScrollView + TabBarView 的滑动切换。
6. **选集命名**：从文件名解析集数，支持「集数 / 完整文件名」一键切换。
7. **播放链路**：识别直链媒体地址（mkv/mp4 等）时跳过 WebView，直接交给 mpv。
8. **WebDAV 字体库**：由客户端扫描 WebDAV 字体文件头建立索引，按需下载缺失字体，
   缓存上限 200MB；WebDAV 侧不需要索引文件，也不需要修改服务端。

## AI 参与说明

本修改版的代码、文档与发布物在 AI 辅助下完成（AI-assisted modification）。
AI 参与的部分包括但不限于：WebDAV 服务、字幕/音轨控制器、字体服务、界面调整与文档整理。
所有改动均由维护者审阅后提交；上游版权归原作者及贡献者所有。

## 已知限制：弹幕搜索

上游的弹幕搜索使用弹弹play 开放接口，需要在**构建时**通过
`--dart-define=DANDANAPI_APPID=... --dart-define=DANDANAPI_KEY=...` 注入应用密钥
（官方 Release 由 CI secrets 提供）。

本仓库源码与 Release 中的 APK **不包含**这些密钥，因此：

- 弹幕搜索会失败（服务端返回 `403 Invalid AppId`，界面显示「搜索失败」）；
- 这不是网络问题，也不是本修改引入的缺陷，而是自编译包的固有限制；
- 自行构建时可提供自己的弹弹play 密钥，或改用其它弹幕来源方案。

## 许可证与署名

本项目整体仍以 **GNU General Public License v3.0（GPL-3.0-only）** 授权给任何获得副本的人。
上游版权归 Predidit 及 Kazumi 贡献者所有；修改部分的版权归 kelstna（AI 辅助修改）。
上游 `LICENSE` 全文原样保留，未删除或修改任何版权声明。

## 商标

“Kazumi” 名称、图标及相关标识归上游作者所有。本仓库仅用于说明修改版的来源，
不主张任何商标权利，也不代表上游官方发布。

## 无担保

本程序按“现状”提供，不附带任何明示或暗示的担保。使用本修改版产生的任何后果由使用者自行承担。
