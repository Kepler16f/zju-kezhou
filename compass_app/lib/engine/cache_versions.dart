/// 方案构建器版本门禁（用户反馈：装了新版但页面仍是旧解析结果）。
///
/// 会话缓存 `cache_last_session.json` 里的 `audit_plan` 是生成时的完整方案树，
/// 若不做版本校验，升级后仍会原样展示旧解析（板块重复、微辅修误计、总学分
/// 口径旧等），用户会以为修复没生效。凡是改变 PDF 解析、模块切分、课程/学分
/// 归属的改动，都必须 +1；启动恢复会话时会据此用本地缓存 PDF 重建方案并重算。
const int kPlanBuilderVersion = 2;

/// audit_plan 是否由旧版构建器生成。
///
/// 只对 PDF 解析构建的方案生效：`meta.builder_version` 缺失即为旧缓存。
/// 非 PDF 方案（教务接口课程表 / 摘要回落）没有可重建的本地 PDF，返回 false，
/// 避免无谓重算。
bool isPlanCacheStale(Map<String, dynamic>? plan) {
  final meta = plan?['meta'];
  if (meta is! Map) return false;
  final extractedBy = '${meta['extracted_by'] ?? ''}';
  if (!extractedBy.contains('planFileFromPdf')) return false;
  final v = (meta['builder_version'] as num?)?.toInt();
  return v == null || v < kPlanBuilderVersion;
}
