// test/cache_versions_test.dart — 会话缓存版本门禁（用户反馈：装新版仍显示旧解析）。
//
// 只有 PDF 解析构建的方案（meta.extracted_by 命中 planFileFromPdf）参与
// builder_version 校验；旧缓存缺版本号 → 需要重建；非 PDF 方案无本地 PDF
// 可重建，必须返回 false 避免无谓重算。
import 'package:test/test.dart';

import 'package:compass_app/engine/cache_versions.dart';

void main() {
  group('isPlanCacheStale', () {
    test('最新 builder_version → 不重建', () {
      expect(
          isPlanCacheStale({
            'meta': {
              'extracted_by': 'engine/plan_audit_adapter.planFileFromPdf',
              'builder_version': kPlanBuilderVersion,
            }
          }),
          isFalse);
    });

    test('旧缓存缺 builder_version / 版本落后 → 重建', () {
      expect(
          isPlanCacheStale({
            'meta': {
              'extracted_by': 'engine/plan_audit_adapter.planFileFromPdf',
            }
          }),
          isTrue);
      expect(
          isPlanCacheStale({
            'meta': {
              'extracted_by': 'engine/plan_audit_adapter.planFileFromPdf',
              'builder_version': kPlanBuilderVersion - 1,
            }
          }),
          isTrue);
    });

    test('非 PDF 方案 / 空值 → 不重建（没有本地 PDF 可用）', () {
      expect(isPlanCacheStale(null), isFalse);
      expect(isPlanCacheStale({}), isFalse);
      expect(
          isPlanCacheStale({
            'meta': {'extracted_by': 'engine/plan_audit_adapter.planFileFromCourseRows'}
          }),
          isFalse);
    });
  });
}
