// test/ai_knowledge_test.dart — 内置知识库接口的零依赖回归：
// JSON 加载、关键词命中、空查询返回空、默认空知识库不产生任何片段。
import 'package:test/test.dart';

import 'package:compass_app/data/ai_knowledge.dart';

void main() {
  test('InMemoryAiKnowledgeBase：JSON 加载 + 关键词检索', () async {
    final kb = InMemoryAiKnowledgeBase.fromJson([
      {
        'id': 'rule-1',
        'title': '选课学分上限',
        'text': '每学期最多选 30 学分，超出需向教务申请。',
        'keywords': ['选课', '学分'],
        'source': '教务手册',
      },
      {
        'id': 'rule-2',
        'title': '体育课安排',
        'text': '体育课按学期安排，具体以选课系统为准。',
      },
    ]);
    expect(kb.length, 2);
    final hits = await kb.retrieve('选课学分上限是多少');
    expect(hits, isNotEmpty);
    expect(hits.first.title, '选课学分上限');
    expect(hits.first.source, '教务手册');
  });

  test('空查询与空知识库返回空列表，不抛异常', () async {
    final kb = InMemoryAiKnowledgeBase.fromJson({
      'documents': [
        {'title': 'A', 'text': 'B'}
      ]
    });
    expect(await kb.retrieve('   '), isEmpty);
    expect(await const EmptyAiKnowledgeBase().retrieve('选课'), isEmpty);
  });
}
