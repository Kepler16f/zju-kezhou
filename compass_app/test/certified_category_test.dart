// 任务 #5 回归：认定类课程关键词"特异性计分"区分开易混类。
// 用户原话：心理健康类和军体类不是一回事，美育类和劳育类不是一回事。
// 锁定：真实课程名归类 + 跨类干扰词并列时的兜底优先级 + 同类子串词不重复计分。
import 'package:compass_app/engine/plan_audit_adapter.dart';
import 'package:test/test.dart';

void main() {
  group('certifiedCategoryOf 真实课程名（#5）', () {
    test('军体类：军事/体育/体质独立成类，不再被心理/思政吃掉', () {
      expect(certifiedCategoryOf('军事理论'), '军体类');
      expect(certifiedCategoryOf('军训'), '军体类');
      expect(certifiedCategoryOf('体育Ⅶ'), '军体类');
      expect(certifiedCategoryOf('体质测试'), '军体类');
    });

    test('心理健康类独立：心理词只归心理，与军体分家', () {
      expect(certifiedCategoryOf('心理健康教育'), '心理健康类');
      expect(certifiedCategoryOf('大学生心理适应与发展'), '心理健康类');
    });

    test('美育类：此前漏归的「民乐演奏」现在命中；与劳育分家', () {
      expect(certifiedCategoryOf('民乐演奏'), '美育类');
      expect(certifiedCategoryOf('书法'), '美育类');
      expect(certifiedCategoryOf('影视鉴赏'), '美育类');
    });

    test('劳育类：劳动/农事/志愿服务；裸「实践」不再越界吸入', () {
      expect(certifiedCategoryOf('劳动教育'), '劳育类');
      expect(certifiedCategoryOf('农事体验'), '劳育类');
      expect(certifiedCategoryOf('志愿服务'), '劳育类');
      // 泛词不收：生产实习/社会实践不是劳育认定课（旧实现会被「实践」误吸）
      expect(certifiedCategoryOf('生产实习'), isNull);
      expect(certifiedCategoryOf('社会实践'), isNull);
    });

    test('创新创业类与思政类', () {
      expect(certifiedCategoryOf('创新创业实践'), '创新创业类');
      expect(certifiedCategoryOf('大学生创业基础'), '创新创业类');
      expect(certifiedCategoryOf('思想道德与法治'), '思政类');
      expect(certifiedCategoryOf('形势与政策'), '思政类');
    });

    test('无命中返回 null（宁缺勿猜）', () {
      expect(certifiedCategoryOf('数据结构'), isNull);
      expect(certifiedCategoryOf('概率论与数理统计'), isNull);
      expect(certifiedCategoryOf(''), isNull);
    });
  });

  group('跨类干扰词：并列走兜底优先级，子串词不抬高分数', () {
    test('心理+艺术 → 心理健康（兜底优先级第一位）', () {
      expect(certifiedCategoryOf('心理健康与艺术鉴赏'), '心理健康类');
    });

    test('艺术+创新创业 → 美育（创新创业是复合词，不再靠子串叠加反超）', () {
      // 回归：「创新创业」(3)+「创业」(3) 曾被叠加成 6 分压过「艺术」(3)
      expect(certifiedCategoryOf('艺术与创新创业'), '美育类');
    });

    test('创新创业+志愿服务 → 创新创业（并列时兜底序）', () {
      expect(certifiedCategoryOf('创新创业与志愿服务'), '创新创业类');
    });

    test('军事+心理 并列 → 心理（兜底优先级心理最前）；分家不吃掉', () {
      // 计分均为 3 分并列；心理排兜底序第一位——证明两类是独立判定而非互相吞并
      expect(certifiedCategoryOf('军事心理学'), '心理健康类');
      // 真军体课不受影响
      expect(certifiedCategoryOf('军事理论'), '军体类');
    });

    test('劳动+艺术 → 美育（劳育词面最宽排最后）', () {
      expect(certifiedCategoryOf('劳动艺术工作坊'), '美育类');
    });
  });
}
