import 'package:computer_manager/services/rust_api.dart';
import 'package:flutter_test/flutter_test.dart';

/// 深度清理的归类：规则里的 `LangSecRef` 一直被解析却没往外送，
/// 列表因此只能按规则名分组。这组测试钉住编号→归类名的映射。
void main() {
  test('四个既定编号各自落到参考实现自带的归类名', () {
    // 归类名逐字取参考实现文案表：:248/:562/:131/:180
    expect(deepCleanCategory('3021'), '垃圾清理');
    expect(deepCleanCategory('3401'), '系统无用文件');
    expect(deepCleanCategory('3402'), '应用缓存');
    expect(deepCleanCategory('3403'), '网络缓存');
  });

  test('不认识或缺失的编号给空串，不编一个归类名', () {
    // 宁可不给归类，也不要按名字猜一个出来
    expect(deepCleanCategory('9999'), '');
    expect(deepCleanCategory(''), '');
    expect(deepCleanCategory('   '), '');
  });

  test('规则里写的前后空格不影响归类（INI 手写常有空格）', () {
    expect(deepCleanCategory(' 3401 '), '系统无用文件');
  });

  test('非深度清理的条目不带归类，界面与改前一致', () {
    final item = CleanItem(path: r'C:\a.bin', size: 10);
    expect(item.category, '');
  });
}
