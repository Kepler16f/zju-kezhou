/// engine/jxb_status.dart — 教学班状态判定（对齐浙大 zdbk 自主选课页图例）。
///
/// LIVE 实证（2026-10-20，zzxkghb.js / 页面内联 CSS）：
///  * `.body_tr.tr-enable` 绿 = 可选（余量 > 0 且无冲突）；
///  * `.body_tr.tr-conflit` 红 = 冲突（与已选教学班时间冲突）；
///  * `.body_tr.tr-disable` 灰绿 = 余量不足（rs 首数 = 0，即无剩余名额）；
///  * 已选 = 行 sfxz=1 / 该 xkkh 出现在已选清单；
///  * 未选 = 课程级默认（本页用于「无时间信息、无法判断可选性」的教学班）。
///
/// `rs` 是「余量/容量」（如 41/43 = 余 41 席、容量 43），解析层已换算成
/// cap/selected；本文件只做纯判定，不碰网络。
library;

import '../data/xk_models.dart';
import 'timeline.dart';

/// 教学班状态（展示顺序即优先级）。
enum JxbStatus { selected, insufficient, conflict, unselected, available }

/// 判定一位教学班的状态。纯函数、不抛异常。
/// [chosenXkkh] 为教务已选清单里的 xkkh 集合；
/// [busySlots] 为「已选 + 模拟选课 + 当前课表」占用的时隙（含 day/start/end/周次）。
JxbStatus classifyJxb(
  XkCourse j, {
  required Set<String> chosenXkkh,
  required List<Map<String, dynamic>> busySlots,
}) {
  final xkkh = '${j.raw['xkkh'] ?? ''}'.trim();
  if ('${j.raw['sfxz'] ?? ''}'.trim() == '1' ||
      (xkkh.isNotEmpty && chosenXkkh.contains(xkkh))) {
    return JxbStatus.selected;
  }
  if (j.cap != null && j.selected != null && j.selected! >= j.cap!) {
    return JxbStatus.insufficient;
  }
  if (j.slots.isNotEmpty &&
      busySlots.isNotEmpty &&
      Timeline.slotsConflict(j.slots, busySlots) != null) {
    return JxbStatus.conflict;
  }
  // 无时间信息：无法判断是否冲突/可选，按 zdbk 默认口径显示「未选」。
  if (j.slots.isEmpty) return JxbStatus.unselected;
  return JxbStatus.available;
}

String jxbStatusLabel(JxbStatus s) => switch (s) {
      JxbStatus.selected => '已选',
      JxbStatus.insufficient => '余量不足',
      JxbStatus.conflict => '冲突',
      JxbStatus.unselected => '未选',
      JxbStatus.available => '可选',
    };

/// 教学班是否允许「模拟选课」：已选/余量不足/冲突一律拦住。
bool canSimulateJxb(JxbStatus s) =>
    s == JxbStatus.available || s == JxbStatus.unselected;
