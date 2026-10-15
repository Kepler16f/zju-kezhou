/// data/pdf_text_extractor.dart — 纯 Dart PDF 文本抽取（零依赖，鸿蒙完全兼容）。
///
/// 设计依据（广泛参考已有案例后的工程决策）：
///  - pypdf（Python 参考实现）：全对象图解析，对本 PDF 过重；
///  - pdf.js（Mozilla，zdbk Web 端所用）：完整渲染器，复杂度不可接受；
///  - syncfusion_flutter_pdf：实测在本 PDF 的 CJK 字体上挂起（>10 分钟无输出）；
///  - pdf 包（Dart）：仅生成，无抽取 API；
///  - 各 Flutter PDF 渲染库（pdfrx/flutter_pdfview 等）：原生插件/FFI，鸿蒙不可用。
///
/// 结论：针对 zdbk 培养方案 PDF 写定向解析器，是唯一同时满足"能解析"和
/// "鸿蒙兼容（flutter-ohos 3.27.5 / Dart 3.6，dart:io+dart:convert 内置）"的方案。
///
/// 本 PDF 混合两种 Type0 编码，必须字体感知才能全量还原：
///  - STSong(-Std)-Light / UniGB-UCS2-H：码字节即 Unicode（课程表、正文）；
///  - SimHei / Identity-H + ToUnicode CMap：字形 ID 需经 CMap 映射回 Unicode
///    （板块标题、修读要求说明——不经映射全是乱码）。
/// 实现：解析 N 0 R 间接对象 → 内容流的 Resources/Font 字典 → 字体编码与
/// ToUnicode CMap（FlateDecode 后 bfchar/bfrange）→ BT/Tf 状态机逐串解码。
/// 整条链路失败时回退到"全文 UTF-16BE 直读"（旧版行为）。
///
/// 非目标：不处理加密 PDF、不做布局还原（按流序拼接文本，由上层
/// plan_pdf_parse 做结构化）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 从 zdbk 生成的培养方案 PDF 字节中抽取全部文本。
/// 返回按内容流顺序拼接的文本（页间以 \n 分隔）。
/// 非法/非文本流自动跳过；无文本时返回空串。
String extractPdfText(List<int> bytes) {
  if (bytes.isEmpty) return '';
  final data = Uint8List.fromList(bytes);
  final fontAware = _extractFontAware(data);
  if (fontAware != null && fontAware.trim().length >= 100) {
    return fontAware;
  }
  return _extractLegacy(data);
}

// ── 间接对象 ───────────────────────────────────────────────────────────────

/// 一个已定位的 `N G obj ... endobj`：字典头部文本 + 流字节（若有）。
class _PdfObj {
  final String header; // obj 关键字与 stream/endobj 之间的字典文本
  final Uint8List? stream; // stream…endstream 的原始（可能压缩）字节
  const _PdfObj(this.header, this.stream);
}

/// 扫描全部间接对象（按对象号索引）。
Map<int, _PdfObj> _parseObjects(String latin) {
  final objs = <int, _PdfObj>{};
  final objRe = RegExp(r'(\d+)\s+\d+\s+obj');
  final bytes = _latinBytes(latin);
  for (final m in objRe.allMatches(latin)) {
    final num = int.tryParse(m.group(1)!);
    if (num == null || objs.containsKey(num)) continue;
    final endObj = latin.indexOf('endobj', m.end);
    final bodyEnd = endObj < 0 ? latin.length : endObj;
    // 字典头 = obj 之后到 stream（或 endobj）；流字节按 /Length 精确截取
    final si = latin.indexOf('stream', m.end);
    final hasStream = si >= 0 && si < bodyEnd;
    final header = latin.substring(m.end, hasStream ? si : bodyEnd);
    Uint8List? stream;
    if (hasStream) {
      var ds = si + 'stream'.length;
      if (ds < latin.length && latin.codeUnitAt(ds) == 0x0D) ds++;
      if (ds < latin.length && latin.codeUnitAt(ds) == 0x0A) ds++;
      final declared =
          RegExp(r'/Length\s+(\d+)').firstMatch(header)?.group(1);
      final len = declared == null ? null : int.tryParse(declared);
      int de;
      if (len != null && ds + len <= latin.length) {
        final cand = latin.indexOf('endstream', ds + len - 20);
        de = (cand >= 0 && cand <= ds + len + 20) ? ds + len : cand;
      } else {
        de = latin.indexOf('endstream', ds);
      }
      if (de > ds) stream = Uint8List.sublistView(bytes, ds, de);
    }
    objs[num] = _PdfObj(header, stream);
  }
  return objs;
}

// latin 字符串 ↔ 字节一一对应：每字节映射为一个同值码位（0-255），
// 保证 substring 索引与字节偏移严格一致（latin1.decode(allowInvalid) 会把
// 非法字节替换成 U+FFFD，破坏这个对应关系，所以不用它）。
Uint8List _latinToBytes(String latin) {
  final b = Uint8List(latin.length);
  for (var i = 0; i < latin.length; i++) {
    final c = latin.codeUnitAt(i);
    b[i] = c <= 0xFF ? c : 0x20;
  }
  return b;
}

String _bytesToLatin(List<int> bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.writeCharCode(b & 0xFF);
  }
  return sb.toString();
}

Uint8List? _latinCacheSrc;
String? _latinCacheStr;
Uint8List _latinBytes(String latin) {
  if (identical(latin, _latinCacheStr)) return _latinCacheSrc!;
  final b = _latinToBytes(latin);
  _latinCacheStr = latin;
  _latinCacheSrc = b;
  return b;
}

/// 解析 `xref` 风格的值：可能是字典字面量，也可能是 `N 0 R` 引用。
/// 返回字典文本；引用解析最多递归 4 层。
String? _resolveDict(Map<int, _PdfObj> objs, String? raw, [int depth = 0]) {
  if (raw == null || depth > 4) return null;
  var cur = raw.trim();
  final refRe = RegExp(r'^(\d+)\s+\d+\s+R$');
  while (true) {
    final r = refRe.firstMatch(cur);
    if (r == null) return cur;
    final o = objs[int.tryParse(r.group(1)!)];
    if (o == null) return null;
    cur = o.header.trim();
    depth++;
    if (depth > 4) return null;
  }
}

// ── FlateDecode / CMap ─────────────────────────────────────────────────────

Uint8List? _tryInflate(Uint8List compressed) {
  try {
    return Uint8List.fromList(ZLibCodec().decoder.convert(compressed));
  } catch (_) {
    return null;
  }
}

String? _inflateToText(_PdfObj? obj) {
  if (obj?.stream == null) return null;
  final infl = _tryInflate(obj!.stream!);
  if (infl == null) return null;
  final s = _bytesToLatin(infl);
  return s.contains('begincmap') ? s : null;
}

/// ToUnicode CMap → 码到 Unicode 映射。宽松扫描，容忍 bfchar/bfrange 块头计数失真。
Map<int, List<int>> _parseCMap(String text) {
  final map = <int, List<int>>{};
  final hex = RegExp(r'<([0-9A-Fa-f]+)>');
  // beginbfchar: <src> <dst>  （dst 可为多码串，如连字）
  final bfCharBlock = RegExp(
      r'beginbfchar\s*([\s\S]*?)endbfchar');
  for (final blk in bfCharBlock.allMatches(text)) {
    final lines = RegExp(r'<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>')
        .allMatches(blk.group(1)!);
    for (final l in lines) {
      final src = _hexCode(l.group(1)!);
      if (src == null) continue;
      map[src] = _hexCodes(l.group(2)!);
    }
  }
  // beginbfrange: <lo> <hi> <dstStart>  或  <lo> <hi> [<d0> <d1> ...]
  final rangeBlock = RegExp(r'beginbfrange\s*([\s\S]*?)endbfrange');
  for (final blk in rangeBlock.allMatches(text)) {
    final body = blk.group(1)!;
    final m = RegExp(r'<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*(<([0-9A-Fa-f]+)>|\[([\s\S]*?)\])');
    var pos = 0;
    while (pos < body.length) {
      final r = m.firstMatch(body.substring(pos));
      if (r == null) break;
      final lo = _hexCode(r.group(1)!);
      final hi = _hexCode(r.group(2)!);
      if (lo != null && hi != null && hi >= lo && hi - lo < 65536) {
        if (r.group(4) != null) {
          final dst = _hexCode(r.group(4)!) ?? 0;
          for (var c = lo; c <= hi; c++) {
            map[c] = [dst + (c - lo)];
          }
        } else {
          final dsts = hex
              .allMatches(r.group(5) ?? '')
              .map((h) => _hexCode(h.group(1)!) ?? 0)
              .toList();
          for (var k = 0; k < dsts.length && lo + k <= hi; k++) {
            map[lo + k] = [dsts[k]];
          }
        }
      }
      pos += r.start + r.group(0)!.length;
    }
  }
  return map;
}

int? _hexCode(String h) => h.length <= 8 ? int.tryParse(h, radix: 16) : null;
List<int> _hexCodes(String h) {
  final out = <int>[];
  for (var i = 0; i + 4 <= h.length && i < 16; i += 4) {
    final c = int.tryParse(h.substring(i, i + 4), radix: 16);
    if (c != null && c != 0) out.add(c);
  }
  return out;
}

// ── 字体信息 ────────────────────────────────────────────────────────────────

/// 一张 Type0 字体的解码规则。
class _FontInfo {
  final bool identity; // Identity-H → 码是字形 ID，需 CMap
  final Map<int, List<int>>? cmap; // ToUnicode 映射（identity 字体有效）
  const _FontInfo({required this.identity, this.cmap});
}

/// 从对象集合构建 字体对象号 → 解码规则。
Map<int, _FontInfo> _buildFontInfos(Map<int, _PdfObj> objs) {
  final infos = <int, _FontInfo>{};
  for (final e in objs.entries) {
    final h = e.value.header;
    if (!h.contains('/Type0')) continue;
    final encM = RegExp(r'/Encoding\s*/(\w[\w-]*)').firstMatch(h);
    final identity = encM?.group(1) == 'Identity-H';
    if (!identity) {
      // UniGB-UCS2-H 等外部 CMap：对 GB 系码字节即 Unicode，直读即可
      infos[e.key] = const _FontInfo(identity: false);
      continue;
    }
    Map<int, List<int>>? cmap;
    final tuM = RegExp(r'/ToUnicode\s+(\d+)\s+\d+\s+R').firstMatch(h);
    if (tuM != null) {
      final cmText = _inflateToText(objs[int.tryParse(tuM.group(1)!)]);
      if (cmText != null) cmap = _parseCMap(cmText);
    }
    infos[e.key] = _FontInfo(identity: true, cmap: cmap);
  }
  return infos;
}

/// 内容流对象头里的 Resources/Font：字体名(如 /F1) → 字体对象号。
/// 兼容 `/Font <</Xi1 2 0 R>>` 与 `/Font 91 0 R`（后者需再解析）。
Map<String, int> _fontResources(Map<int, _PdfObj> objs, String header) {
  final out = <String, int>{};
  final fi = header.indexOf('/Font');
  if (fi < 0) return out;
  final seg = header.substring(fi);
  // 内联字典形式
  final open = seg.indexOf('<<');
  final ref = RegExp(r'^/?\s*(\d+)\s+\d+\s+R').firstMatch(
      seg.substring('/Font'.length).trim());
  String? dict;
  if (open >= 0) {
    // 找到配对 >>
    var depth = 0;
    var end = -1;
    for (var i = open; i + 1 < seg.length; i++) {
      if (seg[i] == '<' && seg[i + 1] == '<') {
        depth++;
        i++;
      } else if (seg[i] == '>' && seg[i + 1] == '>') {
        depth--;
        i++;
        if (depth == 0) {
          end = i + 1;
          break;
        }
      }
    }
    dict = end > 0 ? seg.substring(open, end) : seg.substring(open);
  } else if (ref != null) {
    dict = _resolveDict(objs, seg.substring('/Font'.length).trim(), 0);
  }
  if (dict == null) return out;
  for (final m in RegExp(r'/(\w+)\s+(\d+)\s+\d+\s+R').allMatches(dict)) {
    out[m.group(1)!] = int.parse(m.group(2)!);
  }
  return out;
}

// ── 字体感知抽取主流程 ──────────────────────────────────────────────────────

/// 按内容流（≈页/表单）切分的文本列表：上层据此把课程表绑定到所属板块。
/// 与 [extractPdfText] 用同一套解码，顺序即对象序（zdbk 中等于阅读序）。
List<String> extractPdfPages(List<int> bytes) {
  if (bytes.isEmpty) return const [];
  final data = Uint8List.fromList(bytes);
  final latin = _bytesToLatin(data);
  final objs = _parseObjects(latin);
  final fontInfos = _buildFontInfos(objs);
  final pages = <String>[];
  for (final e in objs.entries) {
    final stream = e.value.stream;
    if (stream == null) continue;
    final content = _tryInflate(stream);
    if (content == null) continue;
    final text = _bytesToLatin(content);
    if (!text.contains('BT') || !text.contains('Tj')) continue;
    final fonts = _fontResources(objs, e.value.header);
    final pageText = _decodeContentStream(text, fonts, fontInfos);
    if (pageText.trim().isNotEmpty) pages.add(pageText);
  }
  return pages;
}

String? _extractFontAware(Uint8List data) {
  final latin = _bytesToLatin(data);
  final objs = _parseObjects(latin);
  if (objs.isEmpty) return null;
  final fontInfos = _buildFontInfos(objs);
  if (fontInfos.isEmpty) return null;

  final out = StringBuffer();
  var anyStream = false;
  // 内容流 = 解压后含 BT 且以 /Font 资源引用字体的流
  for (final e in objs.entries) {
    final stream = e.value.stream;
    if (stream == null) continue;
    final content = _tryInflate(stream);
    if (content == null) continue;
    final text = _bytesToLatin(content);
    if (!text.contains('BT') || !text.contains('Tj')) continue;
    anyStream = true;
    final fonts = _fontResources(objs, e.value.header);
    final pageText = _decodeContentStream(text, fonts, fontInfos);
    if (pageText.trim().isNotEmpty) {
      if (out.isNotEmpty) out.write('\n');
      out.write(pageText);
    }
  }
  if (!anyStream) return null;
  return out.toString();
}

/// 内容流状态机：跟踪当前字体（Tf）与文本位置（Td/TD/Tm），
/// 解码 Tj / TJ 操作符，并据位置还原行结构。
String _decodeContentStream(
    String text, Map<String, int> fontByName, Map<int, _FontInfo> fontInfos) {
  final spans = <_Span>[];
  _FontInfo? current;
  var size = 12.0;
  double x = 0, y = 0;
  final opRe = RegExp(
      r'/(\w+)\s+([\d.]+)\s+Tf' // 1 字体名 2 字号
      r'|(-?[\d.]+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s+Tm' // 3-8 a b c d e f
      r'|(-?[\d.]+)\s+(-?[\d.]+)\s+T[dD]' // 9 10 tx ty
      r'|(\((?:[^()\\]|\\[\s\S]|\((?:[^()\\]|\\[\s\S])*\))*\))\s*Tj' // 11
      r'|\[((?:[^\[\]\\]|\\[\s\S])*)\]\s*TJ'); // 12
  for (final m in opRe.allMatches(text)) {
    if (m.group(1) != null) {
      final objNum = fontByName[m.group(1)!];
      current = objNum == null ? null : fontInfos[objNum];
      size = double.tryParse(m.group(2)!) ?? size;
    } else if (m.group(3) != null) {
      final b = double.tryParse(m.group(4)!) ?? 0;
      final c = double.tryParse(m.group(5)!) ?? 0;
      final e = double.tryParse(m.group(7)!) ?? 0;
      final f = double.tryParse(m.group(8)!) ?? 0;
      if (b == 0 && c == 0) {
        // 非旋转矩阵：绝对定位（旋转 = 页眉水印，跳过）
        x = e;
        y = f;
      } else if (e == 0 && f == 0) {
        x = 0;
        y = 0;
      }
    } else if (m.group(9) != null) {
      x += double.tryParse(m.group(9)!) ?? 0;
      y += double.tryParse(m.group(10)!) ?? 0;
    } else if (m.group(11) != null) {
      final t = _decodedString(_unescapePdfString(m.group(11)!), current);
      if (t.isNotEmpty) {
        spans.add(_Span(x, y, size, t));
        x += _estWidth(t, size);
      }
    } else if (m.group(12) != null) {
      final arr = m.group(12)!;
      final strRe =
          RegExp(r'\((?:[^()\\]|\\[\s\S]|\((?:[^()\\]|\\[\s\S])*\))*\)|<[0-9A-Fa-f\s]*>');
      for (final s in strRe.allMatches(arr)) {
        final raw = s.group(0)!.startsWith('(')
            ? _unescapePdfString(s.group(0)!)
            : _hexToBytes(s.group(0)!);
        final t = _decodedString(raw, current);
        if (t.isNotEmpty) {
          spans.add(_Span(x, y, size, t));
          x += _estWidth(t, size);
        }
      }
    }
  }
  return _spansToText(spans);
}

class _Span {
  final double x;
  final double y;
  final double size;
  final String text;
  const _Span(this.x, this.y, this.size, this.text);
}

/// 估算渲染宽度（CJK 全宽、ASCII 半宽），用于同行拼接时的空格判定。
double _estWidth(String s, double size) {
  var w = 0.0;
  for (final r in s.runes) {
    w += (r >= 0x2E80 || (r >= 0xFF00 && r <= 0xFFEF)) ? size : size * 0.5;
  }
  return w;
}

/// 位置 → 文本：按 y 分行（自上而下），行内按 x 排序，
/// 间隔超过半个字号时补空格（列与列之间），恢复可解析的行结构。
String _spansToText(List<_Span> spans) {
  if (spans.isEmpty) return '';
  final sorted = List<_Span>.of(spans)
    ..sort((a, b) {
      final dy = b.y.compareTo(a.y);
      return dy != 0 ? dy : a.x.compareTo(b.x);
    });
  final sb = StringBuffer();
  var lineY = double.nan;
  var lineEnd = 0.0;
  var lineSize = 12.0;
  for (final sp in sorted) {
    if (lineY.isNaN || (lineY - sp.y).abs() > sp.size * 0.5) {
      // 新行
      if (sb.isNotEmpty) sb.write('\n');
      lineY = sp.y;
      lineEnd = sp.x + _estWidth(sp.text, sp.size);
      lineSize = sp.size;
      sb.write(sp.text);
      continue;
    }
    final gap = sp.x - lineEnd;
    if (gap > lineSize * 0.35) sb.write(' ');
    sb.write(sp.text);
    lineEnd = sp.x + _estWidth(sp.text, sp.size);
  }
  return sb.toString();
}

/// 解码一个 PDF 字符串（按当前字体规则）。
String _decodedString(Uint8List raw, _FontInfo? font) {
  final sb = StringBuffer();
  _appendDecoded(sb, raw, font);
  return sb.toString();
}

void _appendDecoded(StringBuffer sb, Uint8List raw, _FontInfo? font) {
  if (raw.isEmpty || font == null) {
    // 未知字体：按 UTF-16BE 直读兜底
    if (raw.isNotEmpty && raw.length.isEven && _looksUtf16Be(raw)) {
      sb.write(utf16beDecode(raw));
    }
    return;
  }
  if (!font.identity) {
    // UniGB-UCS2-H：码字节即 Unicode
    sb.write(utf16beDecode(raw));
    return;
  }
  // Identity-H + ToUnicode
  final cmap = font.cmap;
  for (var i = 0; i + 1 < raw.length; i += 2) {
    final code = (raw[i] << 8) | raw[i + 1];
    if (cmap != null && cmap.containsKey(code)) {
      for (final u in cmap[code]!) {
        if (u != 0) sb.writeCharCode(u);
      }
    } else if (code != 0) {
      // CMap 缺失该码（如 2 字节 Unicode 直写的少数串）：UTF-16BE 兜底
      if (code < 0xD800 || code > 0xDFFF) sb.writeCharCode(code);
    }
  }
}

Uint8List _hexToBytes(String hexLit) {
  final digits = RegExp(r'[0-9A-Fa-f]+').allMatches(hexLit).map((m) => m.group(0)!).join();
  final bytes = <int>[];
  for (var i = 0; i + 1 < digits.length; i += 2) {
    bytes.add(int.parse(digits.substring(i, i + 2), radix: 16));
  }
  return Uint8List.fromList(bytes);
}

// ── PDF 字符串 ──────────────────────────────────────────────────────────────

/// `( ... )` → 原始字节（处理转义与嵌套括号）。
Uint8List _unescapePdfString(String lit) {
  final bytes = <int>[];
  var i = 1; // 跳过首个 (
  final end = lit.length - 1;
  while (i < end) {
    final c = lit[i];
    if (c == r'\') {
      i++;
      if (i >= end) break;
      final n = lit[i];
      switch (n) {
        case 'n':
          bytes.add(0x0A);
          i++;
        case 'r':
          bytes.add(0x0D);
          i++;
        case 't':
          bytes.add(0x09);
          i++;
        case 'b':
          bytes.add(0x08);
          i++;
        case 'f':
          bytes.add(0x0C);
          i++;
        case r'\':
          bytes.add(0x5C);
          i++;
        case '(':
          bytes.add(0x28);
          i++;
        case ')':
          bytes.add(0x29);
          i++;
        default:
          if (n.codeUnitAt(0) >= 0x30 && n.codeUnitAt(0) <= 0x37) {
            var oct = '';
            while (oct.length < 3 && i < end && lit[i].codeUnitAt(0) >= 0x30 && lit[i].codeUnitAt(0) <= 0x37) {
              oct += lit[i];
              i++;
            }
            bytes.add(int.parse(oct, radix: 8));
          } else {
            bytes.add(n.codeUnitAt(0));
            i++;
          }
      }
    } else {
      final b = c == '\n' ? 0x0A : c.codeUnitAt(0);
      if (b != 0x0D) bytes.add(b); // PDF 规定 \r 与 \r\n 折行不产生字节
      i++;
    }
  }
  return Uint8List.fromList(bytes);
}

// ── 旧版兜底路径（全文 UTF-16BE 直读） ──────────────────────────────────────

String _extractLegacy(Uint8List data) {
  final out = StringBuffer();
  for (final stream in _findStreams(data)) {
    final decompressed = _tryInflate(stream);
    if (decompressed == null) continue;
    final text = _extractTjTextLegacy(decompressed);
    if (text.isNotEmpty) {
      if (out.isNotEmpty) out.write('\n');
      out.write(text);
    }
  }
  return out.toString();
}

List<Uint8List> _findStreams(Uint8List data) {
  final streams = <Uint8List>[];
  var pos = 0;
  while (true) {
    final s = _findSequence(data, _streamKeyword, pos);
    if (s < 0) break;
    var dataStart = s + _streamKeyword.length;
    if (dataStart < data.length && data[dataStart] == 0x0D) dataStart++;
    if (dataStart < data.length && data[dataStart] == 0x0A) dataStart++;
    final length = _readDeclaredLength(data, s);
    int end;
    if (length != null && dataStart + length <= data.length) {
      final declared = dataStart + length;
      final verify = _findSequence(data, _endstreamKeyword, declared - 20);
      end = (verify >= 0 && verify <= declared + 20)
          ? declared
          : _findSequence(data, _endstreamKeyword, dataStart);
    } else {
      end = _findSequence(data, _endstreamKeyword, dataStart);
    }
    if (end < 0) break;
    if (end > dataStart) {
      streams.add(Uint8List.sublistView(data, dataStart, end));
    }
    pos = end + _endstreamKeyword.length;
  }
  return streams;
}

const _streamKeyword = [0x73, 0x74, 0x72, 0x65, 0x61, 0x6D]; // "stream"
const _endstreamKeyword = [
  0x65, 0x6E, 0x64, 0x73, 0x74, 0x72, 0x65, 0x61, 0x6D
]; // "endstream"

int _findSequence(Uint8List data, List<int> seq, int from) {
  if (seq.isEmpty || data.length < seq.length) return -1;
  outer:
  for (var i = from; i <= data.length - seq.length; i++) {
    for (var j = 0; j < seq.length; j++) {
      if (data[i + j] != seq[j]) continue outer;
    }
    return i;
  }
  return -1;
}

int? _readDeclaredLength(Uint8List data, int streamPos) {
  final headStart = streamPos > 200 ? streamPos - 200 : 0;
  final head = latin1.decode(
      Uint8List.sublistView(data, headStart, streamPos), allowInvalid: true);
  final m = RegExp(r'/Length\s+(\d+)').firstMatch(head);
  return m == null ? null : int.tryParse(m.group(1)!);
}

String _extractTjTextLegacy(Uint8List content) {
  final sb = StringBuffer();
  for (final m in RegExp(r'\(((?:\\.|\\[\s\S]|\((?:[^()\\]|\\.)*\)|[^()\\])*)\)')
      .allMatches(latin1.decode(content, allowInvalid: true))) {
    final s = '(${m.group(1)})';
    final raw = _unescapePdfString(s);
    if (raw.length.isEven && _looksUtf16Be(raw)) {
      try {
        sb.write(utf16beDecode(raw));
        continue;
      } catch (_) {}
    }
    for (final b in raw) {
      if (b == 0) continue;
      if (b < 0x20 && b != 0x0A && b != 0x0D && b != 0x09) continue;
      sb.writeCharCode(b);
    }
  }
  return sb.toString();
}

bool _looksUtf16Be(Uint8List raw) {
  var zeroHigh = 0;
  var cjkHigh = 0;
  final pairs = raw.length ~/ 2;
  for (var i = 0; i < pairs && i < 20; i++) {
    final hi = raw[i * 2];
    if (hi == 0x00) zeroHigh++;
    if (hi >= 0x4E && hi <= 0x9F) cjkHigh++;
  }
  return zeroHigh + cjkHigh > pairs ~/ 2;
}

/// UTF-16BE 解码（dart:convert 无 utf16be，手动实现；跳 NUL）。
String utf16beDecode(List<int> bytes) {
  final sb = StringBuffer();
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    final code = bytes[i] * 256 + bytes[i + 1];
    if (code >= 0xD800 && code <= 0xDBFF && i + 3 < bytes.length) {
      final low = bytes[i + 2] * 256 + bytes[i + 3];
      if (low >= 0xDC00 && low <= 0xDFFF) {
        sb.writeCharCode(0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00));
        i += 2;
        continue;
      }
    }
    if (code != 0) sb.writeCharCode(code);
  }
  return sb.toString();
}
