import 'dart:math';

bool needUpdate(String localVersion, String remoteVersion) {
  final localVersionList = localVersion.split('.');
  final remoteVersionList = remoteVersion.split('.');
  final maxLength = max(localVersionList.length, remoteVersionList.length);
  for (var i = 0; i < maxLength; i++) {
    final localSegment =
        i < localVersionList.length ? int.parse(localVersionList[i]) : 0;
    final remoteSegment =
        i < remoteVersionList.length ? int.parse(remoteVersionList[i]) : 0;
    if (remoteSegment > localSegment) {
      return true;
    } else if (remoteSegment < localSegment) {
      return false;
    }
  }
  return false;
}

/// 比较两个点分版本名（不含 build 号）：[a] 小返回 -1，相等 0，大返回 1。
/// 段内非数字按 0 计，缺段补 0。
int compareVersionNames(String a, String b) {
  final left = a.trim().split('.');
  final right = b.trim().split('.');
  final maxLength = max(left.length, right.length);
  for (var i = 0; i < maxLength; i++) {
    final leftSegment = i < left.length ? _versionSegment(left[i]) : 0;
    final rightSegment = i < right.length ? _versionSegment(right[i]) : 0;
    if (leftSegment != rightSegment) {
      return leftSegment.compareTo(rightSegment);
    }
  }
  return 0;
}

/// 本仓库 Release 的更新判定：先比版本名，版本名相同再比 build 号。
///
/// 版本名一直停在 `2.3.9`（对齐上游基座），真正的发布序号是 pubspec 里 `+` 后面的
/// build 号，所以只比版本名会永远判成“已是最新”。
bool needUpdateForRelease({
  required String localVersion,
  required int localBuild,
  required String remoteVersion,
  required int remoteBuild,
}) {
  final byName = compareVersionNames(remoteVersion, localVersion);
  if (byName != 0) {
    return byName > 0;
  }
  return remoteBuild > localBuild;
}

int _versionSegment(String value) => int.tryParse(value.trim()) ?? 0;
