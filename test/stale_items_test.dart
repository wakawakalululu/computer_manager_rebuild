import 'package:computer_manager/pages/disk_clean_page.dart';
import 'package:computer_manager/services/rust_api.dart';
import 'package:flutter_test/flutter_test.dart';

/// 删除前先探一遍文件还在不在：扫描结果会过期，按扫描时的条数说
/// 「将删除 N 个」是拿旧账说新话。参照实现也留了「文件不存在」(:58)。
void main() {
  CleanItem one(String p) => CleanItem(path: p, size: 1);
  CleanItem group(String label, List<String> ps) =>
      CleanItem(path: label, size: ps.length, paths: ps);

  test('单文件行：还在的留、没了的剔', () {
    final items = [one(r'C:\a.bin'), one(r'C:\b.bin')];
    final (kept, stale) = dropStaleItems(items, [true, false]);
    expect(kept.length, 1);
    expect(kept.single.path, r'C:\a.bin');
    expect(stale, 1);
  });

  test('一组重复文件：只算实际存活的份数', () {
    // 一行代表 3 份，其中 1 份没了 → 这一行还留（还有活的），失效计 1
    final items = [
      group('3 份重复', [r'C:\b1', r'C:\b2', r'C:\b3'])
    ];
    final (kept, stale) = dropStaleItems(items, [true, false, true]);
    expect(kept.length, 1);
    expect(stale, 1);
  });

  test('一组全没了：整行剔掉，失效按份数算', () {
    final items = [
      group('2 份重复', [r'C:\b1', r'C:\b2'])
    ];
    final (kept, stale) = dropStaleItems(items, [false, false]);
    expect(kept, isEmpty);
    expect(stale, 2);
  });

  test('探不到（null）或长度对不上：整批原样返回，不臆断', () {
    final items = [one(r'C:\a.bin'), one(r'C:\b.bin')];
    final (k1, s1) = dropStaleItems(items, null);
    expect(k1.length, 2);
    expect(s1, 0);
    // frb 回的向量长度对不上 = 数据不可信，按"都在"处理
    final (k2, s2) = dropStaleItems(items, [true]);
    expect(k2.length, 2);
    expect(s2, 0);
  });

  test('pathsOf 与 fileCountOf 对同一行给同一个数', () {
    final items = [
      one(r'C:\a.bin'),
      group('2 份', [r'C:\b1', r'C:\b2'])
    ];
    expect(pathsOf(items[0]).length, 1);
    expect(pathsOf(items[1]).length, 2);
    expect(fileCountOf(items), 3);
  });
}
