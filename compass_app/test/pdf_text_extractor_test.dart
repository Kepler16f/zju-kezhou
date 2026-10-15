// test/pdf_text_extractor_test.dart — 纯 Dart PDF 抽取器单测（真实 PDF + 合成数据）。
import 'dart:io';
import 'package:test/test.dart';
import 'package:compass_app/data/pdf_text_extractor.dart';

void main() {
  // 真实 PDF（沙箱缓存，存在时才跑——CI 无此文件自动跳过）
  final realPdf = File(
      'C:/Users/胡天泽/AppData/Roaming/edu.zju.compass/compass_app/compass/cache_planpdf_20261321.pdf');

  group('真实方案 PDF 抽取', skip: !realPdf.existsSync() ? '沙箱无缓存 PDF' : false, () {
    test('抽取并验证关键词', () {
      final bytes = realPdf.readAsBytesSync();
      final text = extractPdfText(bytes);
      print('抽取字符数: ${text.length}');
      print('前 300 字:\n${text.substring(0, text.length > 300 ? 300 : text.length)}');
      expect(text.length, greaterThan(1000), reason: '抽取文本过短');
      expect(RegExp(r'[\u4e00-\u9fff]').hasMatch(text), isTrue, reason: '无中文');
      // 用户核心诉求：通识课程修读要求
      expect(text.contains('通识'), isTrue, reason: '缺「通识」');
      expect(text.contains('学分'), isTrue, reason: '缺「学分」');
    });

    test('模块学分声明行可识别', () {
      final text = extractPdfText(realPdf.readAsBytesSync());
      // 与 plan_pdf_parse 同款正则（实测格式：`N)标题 X学分`）
      final mods = RegExp(
              r'(?:\d+[).]|\(\d+\))\s*([\u4e00-\u9fff][\u4e00-\u9fffA-Za-z（）()·]{1,20}?)\s*(\d{1,3}(?:\.\d+)?)\s*学分')
          .allMatches(text)
          .toList();
      print('模块声明行命中: ${mods.length}');
      for (final m in mods.take(8)) {
        print('  MODULE: ${m.group(1)} ${m.group(2)}学分');
      }
      expect(mods.length, greaterThan(3), reason: '模块声明行不足');
    });

    test('课程行可识别（课程号+名称+学分）', () {
      final text = extractPdfText(realPdf.readAsBytesSync());
      final courses = RegExp(
              r'([A-Z]{3,6}\d{4}[A-Z]?)\s*([^\s\d][^\n]{1,30}?)\s+(\d{1,2}(?:\.\d)?)\s')
          .allMatches(text)
          .toList();
      print('课程行命中: ${courses.length}');
      for (final c in courses.take(5)) {
        print('  COURSE: ${c.group(1)} ${c.group(2)} ${c.group(3)}');
      }
      expect(courses.length, greaterThan(10), reason: '课程行不足');
    });
  });

  group('合成数据', () {
    test('UTF-16BE 解码', () {
      // "浙江大学" = U+6D59 U+6C5F U+5927 U+5B66
      expect(utf16beDecode([0x6D, 0x59, 0x6C, 0x5F, 0x59, 0x27, 0x5B, 0x66]), '浙江大学');
    });

    test('空输入安全', () {
      expect(extractPdfText([]), '');
    });

    test('非 PDF 输入安全', () {
      expect(extractPdfText([0x48, 0x65, 0x6C, 0x6C, 0x6F]), '');
    });
  });
}
