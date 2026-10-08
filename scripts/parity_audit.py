#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""对齐体检：把「我们和参考实现差在哪」从猜变成量。

六项独立检查（下面编号 [1]–[6]），全部只读，输出都是「数字 + 清单」，
便于逐条判断：

1. API 面：`frb_calls.txt` 里参考实现真正调用过的 codec 符号，我们这边有没有实现
   （Rust 源码里能找到同名函数，或 codec 名登记在注释里）。
2. 接线面：`lib/services/rust_api.dart` 适配层里，哪些方法在 UI/宿主侧没有任何调用点
   ——实现了但从界面上够不着，等于没有这个能力。
3. 文案面：`zh_strings.txt` 里的界面文案，哪些我们整个 lib/ 从来没出现过
   ——参考实现有这句话，说明它有这么个控件或状态。

用法：python scripts/parity_audit.py            （全部六面）
     python scripts/parity_audit.py strings    （只做文案那项，输出更长）
     python scripts/parity_audit.py selftest   （可达面结论判据的自检，退出码非 0 即红）

判据（重要）：只有名字没有第二处证据（类名/路由/相邻文案）的条目一律不动手，
宁可不做什么也别照着名字编一个页面出来。
"""
import io
import os
import re
import shutil
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXTRACTED = os.path.join(ROOT, 'docs', 'extracted')


def read(path):
    return io.open(path, encoding='utf-8', errors='replace').read()


def dart_sources(only_ui=True):
    """lib/ 下的 Dart 源码；only_ui 时排除生成代码与服务层。"""
    out = []
    for root, _dirs, files in os.walk(os.path.join(ROOT, 'lib')):
        n = root.replace('\\', '/')
        if n.endswith('/src') or '/src/' in n or n == 'lib/src':
            continue
        if only_ui and (n.endswith('services') or n == 'lib'):
            continue
        for f in files:
            if f.endswith('.dart'):
                out.append(read(os.path.join(root, f)))
    return ''.join(out)


def rust_sources():
    out = []
    for root, _dirs, files in os.walk(os.path.join(ROOT, 'rust', 'src')):
        for f in files:
            if f.endswith('.rs'):
                out.append(read(os.path.join(root, f)))
    return ''.join(out)


def _rust_files():
    out = []
    for root, _dirs, files in os.walk(os.path.join(ROOT, 'rust', 'src')):
        for f in sorted(files):
            if f.endswith('.rs'):
                out.append(os.path.join(root, f))
    return out


RUST_FILES = _rust_files()

# 「故意不接」的判据只认这几个说法，且必须写在函数自己的紧邻注释块或函数体里。
# 不收「建议」「注意」「暂时」——那些是随笔，不是结论。
VERDICT_MARK = re.compile(
    u'故意不给|负向结论|接了反而|不该接|不该透出')


def _clean_reason(line):
    s = line.strip()
    s = re.sub(r'^/+ *', '', s).strip()       # 去掉 /// 前缀
    s = s.replace(u'⚠', '').replace('**', '').strip()
    return s[:78]


def _verdict_at(lines, fn_line):
    """给定 `fn` 所在行号，看它的紧邻注释块或函数体里有没有结论。"""
    block, j = [], fn_line - 1
    while j >= 0:
        s = lines[j].strip()
        if s.startswith('///') or s.startswith('//') or s.startswith('#'):
            block.insert(0, s)
            j -= 1
        else:
            break
    # 函数体收到第一个独占一行的 `}` 为止：不把下一个函数的注释算进来
    body, k = [], fn_line + 1
    while k < len(lines) and not re.match(r'^\s*\}\s*$', lines[k]):
        body.append(lines[k])
        k += 1
    for cand in block + body:
        if VERDICT_MARK.search(cand):
            return _clean_reason(cand)
    return None


def _body_end(lines, fn_line):
    k = fn_line + 1
    while k < len(lines) and not re.match(r'^\s*\}\s*$', lines[k]):
        k += 1
    return k


def verdict_for(codec, fn_name):
    """这个 Rust 函数有没有「故意不给出口」的结论？返回理由原文，没有则 None。

    为什么要这一层：可达面过去只是一个平铺的「够不着 N 个」清单，
    里面好几条早已逐条判完并写明了不接的理由，可它跟真缺口长得一模一样，
    于是每一轮都得有人把这 N 条重查一遍。判据取自源码注释而不是脚本里的
    白名单——想关掉一条就得在函数上写下理由，脚本不替谁记着结论。

    定位用 codec 字面量而不是函数名：每个实现里都有一行 `// frb codec: <codec>`，
    而 codec 名反推出来的函数名并不可靠（`...ProcessProcessInfoGetProcessIco`
    实际叫 `get_process_ico`），按名字找会把已有结论的条目错当成没结论。
    """
    hit = None
    for path in RUST_FILES:
        text = read(path)
        lines = text.splitlines()
        anchors = []
        if codec in text:
            for i, ln in enumerate(lines):
                if codec not in ln:
                    continue
                for j in range(i, -1, -1):
                    m = re.search(r'\bfn\s+(\w+)\s*[(<]', lines[j])
                    if m:
                        # 锚点必须真落在这个函数体内：写在文档注释里的 codec
                        # 属于**上一个**函数，不能替它背结论。
                        if i < _body_end(lines, j):
                            anchors.append(j)
                        break
        if not anchors:
            for i, ln in enumerate(lines):
                if re.search(r'\bfn\s+' + re.escape(fn_name) + r'\s*[(<]', ln):
                    anchors.append(i)
        for fl in anchors:
            r = _verdict_at(lines, fl)
            if r and (hit is None or len(r) > len(hit)):
                hit = r
    return hit


def codec_to_snake(codec):
    body = re.sub(r'^crateApi\w+?R', '', codec)
    return re.sub(r'(?<!^)(?=[A-Z])', '_', body).lower()


def audit_api():
    codecs = sorted(set(l.strip() for l in read(
        os.path.join(EXTRACTED, 'frb_calls.txt')).splitlines()
        if l.strip().startswith('crateApi')))
    rust, dart = rust_sources(), dart_sources(only_ui=False)
    dart += read(os.path.join(ROOT, 'lib', 'services', 'rust_api.dart'))
    missing = [c for c in codecs
               if c not in rust and c not in dart
               and codec_to_snake(c) not in rust]
    print('[1] API 面：参考实现调用 %d 个 codec，我们缺 %d 个' % (len(codecs), len(missing)))
    for c in missing:
        print('    缺 %s  (期望 Rust fn %s)' % (c, codec_to_snake(c)))
    return missing


def camel(name):
    parts = name.split('_')
    return parts[0] + ''.join(p[:1].upper() + p[1:] for p in parts[1:])


def audit_reachable():
    """参考实现调用过的 codec，我们既在 Rust 侧实现了、又在适配层有出口吗？

    为什么单列一项：`audit_wiring` 只查"适配层方法有没有被引用"，看不见
    "适配层压根没有这个方法"。PCAS 就是这么掉出视野的——Rust 实现了、codec 名
    也对得上，api 面因此报"缺 0"，但界面上永远够不着。
    """
    codecs = sorted(set(l.strip() for l in read(
        os.path.join(EXTRACTED, 'frb_calls.txt')).splitlines()
        if l.strip().startswith('crateApi')))
    rust = rust_sources()
    api = read(os.path.join(ROOT, 'lib', 'services', 'rust_api.dart'))
    # 适配层里所有公开方法名：`  Future<X> name(` / `  Stream<X> name(` /
    # `  X name(`。类型部分可能含嵌套 <> 与空格，所以按"最后一个标识符
    # 紧跟 ( 或 = 为准"来切，不用会被最小匹配坑到的懒惰量词。
    # 也认 `ds.name(` 这种"适配层内部直调桥"——它对外由包着它的公开方法承担。
    api_methods = set()
    for line in api.splitlines():
        m = re.match(r'\s{2}[A-Za-z][\w<>,\s?]*?([A-Za-z]\w*)\s*[(=]', line)
        if m:
            api_methods.add(m.group(1))
        m2 = re.search(r'\b(?:ds|si|ru|gl|pc)\.(\w+)\s*\(', line)
        if m2:
            api_methods.add(m2.group(1))
    missing = []
    for c in codecs:
        snake = codec_to_snake(c)
        if snake not in rust and c not in rust:
            continue  # Rust 侧都没实现，交给 audit_api 报
        name = snake.split('::')[-1]
        # 适配层方法多用 camelCase；Rust 的 snake 名也接受
        if name in api_methods or camel(name) in api_methods:
            continue
        # 方法名可能另有其名（如 get_monitor_size → primaryScreenSize），
        # 这时靠我们在方法上写的 codec 注释作为证据链——注释里写了 codec 名，
        # 就说明这一条是真接上的，而不是碰巧同名。
        if c in api or name in api:
            continue
        missing.append((c, name))
    decided, undecided = [], []
    for c, name in missing:
        r = verdict_for(c, name)
        (decided if r else undecided).append((c, name, r))
    print(u'[3] 可达面：Rust 已实现但适配层没有出口的 %d 个，其中**还没有结论的 %d 个**'
          u'（另有 %d 个已判定不接，理由就地写在函数上）'
          % (len(missing), len(undecided), len(decided)))
    for c, name, r in undecided:
        print(u'    待判定 %s  (期望适配层有 %s)' % (c, name))
    for c, name, r in decided:
        print(u'    已判定不接 %s —— %s' % (name, r))
    return undecided


BRIDGE_RECEIVERS = {'ds', 'si', 'ru', 'gl', 'pc', 'di'}


def receivers_of(name, text):
    return set(re.findall(r'\b(\w+)\.' + re.escape(name) + r'\b', text))


def is_declaration(line, name):
    # 类型部分必须**看起来像类型**：大写开头或 Future<>/Stream<>（点号允许，
    # `Future<pc.X>` 是本项目里真实存在的写法）。
    # 旧写法用 `[A-Za-z<>, ?]+`（含空格）会把 `    await foo();` 这类**调用行**
    # 也认成声明并剔除掉——于是唯一的使用点被自己吃掉，方法被误报成「没接线」。
    # （真就这么发生过：snapshotPortUsage 的同文件直调就是这么丢的。）
    return re.match(
        r'  (?:(?:Future|Stream)<[\w<>, ?.]*>|[A-Z][\w<>, ?. ]*) '
        + re.escape(name) + r'\(', line) is not None


def wiring_split(api, callers):
    """把适配层公开方法分成「真没人调」与「适配层内部自用」。

    ⚠ 使用点必须**排除桥别名**（ds/si/ru/gl/pc/di）：一行式转发
        Future<PcasLaunchOutcome> openPcasClient() => pc.openPcasClient();
    的 `.openPcasClient` 就写在声明行自己身上。按"带个点就算接"判，这类 1:1 包装
    **永远**已接线，而界面上压根没有入口——PCAS 正是这样掉出视野的（可达面当初
    就是为它加的）。这条判据由 `selftest_wiring` 用 fixture 钉着。

    反过来，只匹配 `.name` 又会漏两类**确实存在**的用法（本项目长期挂着的那几条
    全这么来的）：① 同文件内直调 `await hostsConfigured();` 前面没有点；
    ② tear-off `ips.any(isUsableIp)` 只给名字不给括号。所以裸调用与 tear-off 算
    内部自用，且判"内部有没有用"时先剔掉注释行（文档里写 `[processPublisher]` 不是调用）。
    """
    methods = set(re.findall(
        '\n  (?:Future<[^>]*>|Stream<[^>]*>|[A-Za-z<>, ?]+) (\\w+)\\(', api))
    methods = {m for m in methods if m[0].islower() and not m.startswith('_')}
    code_lines = [ln for ln in api.splitlines()
                  if not ln.strip().startswith(('//', '///'))]
    unwired, internal = [], []
    for m in sorted(methods):
        if receivers_of(m, callers) - BRIDGE_RECEIVERS:
            continue
        pat = re.compile(r'(?<![\w.])' + re.escape(m) + r'\s*(?:\(|[,)])')
        if any(pat.search(ln) for ln in code_lines
               if not is_declaration(ln, m)):
            internal.append(m)
        else:
            unwired.append(m)
    return methods, unwired, internal


FIXTURE_API = u'''
class RustApi {
  RustApi._();
  static final instance = RustApi._();

  // 只有一行式转发、界面没人调：这一条**必须**报未接线（洞 ①）
  Future<String> pcasOnlyDelegated() => pc.pcasOnlyDelegated();
  // 返回类型带点号的声明行不能被当成使用点（洞 ②），但它确实被 instance 调了
  Future<pc.PcasLaunchOutcome> usedByInstance() => pc.usedByInstance();
  Future<String> calledBare() async => 'x';
  Future<bool> isUsableIp(String ip) async => true;
  Future<void> host() async {
    await calledBare();
    final ok = ips.any(isUsableIp);
    await RustApi.instance.usedByInstance();
  }
  /// 文档里提到 notMentioned 不算调用点
  Future<void> unusedOne() async {}
}
'''


def selftest_wiring():
    """接线判据的自检：每个洞都得有一条用例能因为它坏掉而变红。"""
    _m, unwired, internal = wiring_split(FIXTURE_API, FIXTURE_API)
    want = [('pcasOnlyDelegated', 'unwired'),
            ('usedByInstance', 'wired'),
            ('calledBare', 'internal'),
            ('isUsableIp', 'internal'),
            ('unusedOne', 'unwired')]
    bad = []
    for name, expect in want:
        got = ('unwired' if name in unwired
               else 'internal' if name in internal else 'wired')
        print('    [%s] %s -> %s' % ('OK' if got == expect else 'FAIL',
                                     name, got))
        if got != expect:
            bad.append(name)
    print('[自检] 接线面判据 %s' % ('通过' if not bad else '失败: %s' % bad))
    return 0 if not bad else 1


def audit_wiring():
    api = read(os.path.join(ROOT, 'lib', 'services', 'rust_api.dart'))
    callers = dart_sources(only_ui=False) + read(
        os.path.join(ROOT, 'lib', 'app.dart'))
    # 使用点算全 lib（服务层之间也会互相调，比如 ExamineSource.fromBridge 取
    # serviceStatus、FeedbackSubmitter 用方法引用 api.collectLogPack）；只看 UI
    # 会把这类正常接线误报成「没接」。判据本体在 wiring_split（带 fixture 自检）。
    methods, unwired, internal = wiring_split(api, callers)
    # 与可达面同一套口径：未接线里**已经查明不接**的那些，理由在 Rust 函数上，
    # 判据现取——不然这一面就长着一串"看着像缺口"的条目，谁来都得重查一遍。
    # 出口上方的 codec 注释（本项目每个出口都标）用来把适配层方法映射回 Rust 函数。
    lines = api.splitlines()
    gaps, decided = [], []
    for m in unwired:
        codec = None
        for i, ln in enumerate(lines):
            if is_declaration(ln, m):
                head = '\n'.join(lines[max(0, i - 12):i])
                mm = re.search(r'(crateApi\w+)', head)
                if mm:
                    codec = mm.group(1)
                break
        r = verdict_for(codec, m) if codec else None
        (decided if r else gaps).append((m, codec, r))
    print('[2] 接线面：适配层公开方法 %d 个，其中**真缺口 %d 个**、'
          '已判定不接 %d 个（理由就地写在 Rust 函数上；另有 %d 个是**适配层内部自用**'
          '——同文件直调或 tear-off，按 `.name` 匹配认不出，不算缺口）'
          % (len(methods), len(gaps), len(decided), len(internal)))
    for m, _c, _r in gaps:
        print('    未接线 %s' % m)
    for m, c, r in decided:
        print('    已判定不接 %s（%s）—— %s' % (m, c, r))
    for m in internal:
        print('    内部自用 %s' % m)
    return gaps


# 文案面的结论表：某条自带文案我们**判过不照搬**，理由写在这儿。
#
# 为什么必须有这一层：这一面原先是一串平铺的「未见 N 条」，里面既有真缺口，也有
# 「名字与数据对不上，照抄就会说谎」和「缺能力（没有更新源）」那两类不该动手的条目，
# 三者长得一模一样——于是每一条都得有人重查一遍。
#
# 但**这张表自己也会过期**：一条结论说的是"我们没有这个"，而我们后来把它做出来了，
# 这条就成了谎。所以每个键都做了自动失效——串一旦出现在我们的代码里就报
# 「结论表失效」，要求删掉它，而不是留着让下面这个很危险的"修复"看起来仍成立：
# 看到表里有「开机启动耗时」就把我们那行「已开机 X」改回去，可那时我们手上只有
# LastBootUpTime 差值（运行时长），改完标签就开始承诺它给不出的数。
# 键**不许长期挂着一条已经过时的判断**：两个已经这样收掉的例子（不是漏删，是机制自己把它们退出来的）：
#  * 「开机启动耗时」——当初不能写，是因为手上只有 LastBootUpTime 差值=运行时长；
#    后来接了启动诊断事件的 BootTime（#100），标签就名副其实了。
#    ⚠ 这条判据现在由 `test/boot_duration_format_test.dart` 钉着（读不到就不显示该项），
#    不再靠这张表——删它之前先确认那个用例还在。
#  * 「应用中心」——当初被占位 URL 卡住不敢做成入口；#98 改成"先探客户端在不在、
#    没有假链接这条路"之后就不欠一个结论了。
STRING_VERDICTS = {
    # ---- 2026-10-08 第十八轮：短标签里"看着像槽位名"的三条，逐条给可反驳的理由 ----
    # 共同背景：文案表只给"串 + 次数"，不给它出现在哪个控件的哪个槽位，
    # 所以"表里有这个短词"≠"这一页/这一列就该叫这个"。三条都不据此改界面。
    u'开机管理':
        '我们这一页的标题是「开机启动项管理」(app_manage_page.dart:125/:480)，'
        '它的每个成分都能在表里找到(:6/:61/:300 一带的『开机启动项』)，是原话拼的；'
        ':488 是表里唯一相关的短标签，但没有第二证据说明它就是这一页的标题'
        '（也可能是导航/抽屉名）。要改得有实机版式证据，不凭孤词改',
    u'实用工具':
        '工具箱页(:15-65)只摆四张卡、没有分区标题，导航那一格叫「工具」；'
        ':524 这个短词归属哪个槽位没有第二证据（classes.txt 里没有可对照的对应类名），'
        '凭空加一行标题＝造一个表里没说过的版式动作。要动得有版式证据',
    u'文件大小':
        '大文件/重复文件页是"一行一条 + 体积作副标题"的形态，不是表格式列头；'
        ':561 到底是列头还是别处的标签没有位置证据。这一条留给实机版式比对，'
        '不在只有孤词的时候造列头',
    # ---- 2026-10-08 第二十六轮：提取残码与本地化模板，逐条登记 ----
    # 先统一说清这批的**性质**：它们不是"参考实现说过、我们没抄"的界面文案，
    # 而是 `zh_strings.txt` 自己的提取产物问题（编码错配）或 Flutter 的本地化数据。
    # ⚠ **不许把它做成规则**：第十八轮试过按"字在任何长句里都没出现过"筛残码，
    # 同一规则当场误杀了 `返回`/`智慧盘`/`详情`/`总容量`/`版本号`/`应用中心` 六个真词
    # （已全部撤回）。所以这里**一条一条**登记，每条理由只说"这一串自己读不成话"，
    # 任何人可以据此反驳单条。正解是**重新正确提取这张表**（修源头编码，不在下游过滤）；
    # 真重提取之后这些键会从表里消失，`string_verdict_check` 会自己报"结论该删"——正是期望。
    u'下膌下膋下': '残码：生僻字（膌/膋）堆成的三个字，读不成词',
    u'而HEH': '残码：单个汉字 + 孤立拉丁字母（与 `:600-:635` 那段连续错配同族）',
    u'而HHEHMHA': '残码：单字 + 一串大小写混排的孤立字母',
    u'脑HEHMHA': '残码：同上',
    u'表HHEHMHA': '残码：同上',
    u'解IFpH': '残码：同上（`解` + `IFpH`）',
    u'议HHEHA': '残码：同上',
    u'设HEH': '残码：同上',
    u'识HEI': '残码：同上',
    u'败HMHuH': '残码：同上',
    u'软HMHA': '残码：同上',
    u'还HEHH': '残码：同上',
    u'醓下蒹上能': '残码：生僻字（醓/蒹）拼出来的五个字，读不成话',
    u'年M月d日': '本地化模板：串里带 `M`/`d` 格式占位符，是 `intl` 的日期格式（非界面文案）',
    u'年第Q季度': '本地化模板：同上（`Q` 是季度占位符）',
    # ⚠ `日曜日` 也属于这一类（`intl` 的 ja 星期名），但**没有登记**：
    #   它只有 3 个汉字，落在文案面的 `min_len=4` 之外 → 登了也是**死键**
    #   （第十八轮已吃过这个亏：29 条残码 verdict 里只有 7 条真落在候选集内）。
    #   登记表里只放"这一面真会报出来的串"，否则失效检查替一个永远不出现的键背书。
}


def string_verdict_check(verdicts, table_text, corpus):
    """结论表的两条失效条件：表里已经没这条了；或者我们已经用上了它。

    返回问题列表（空=表还活着）。这两条都是**对着当前文本现查**的，不是靠人记得删——
    结论表最大的坏法是条目腐烂成"替一条早就不存在的串背书"。
    """
    problems = []
    for key in sorted(verdicts):
        if key not in table_text:
            problems.append(u'%s：提取表里已经没有这条了，结论该删而不是继续豁免' % key)
        if key in corpus:
            problems.append(u'%s：我们已经把它用上了，这条不再属于"未见"，结论该撤' % key)
    return problems


def selftest_string_verdicts():
    # 三种情形各一条：键还在表里也没被我们用上（健康）、键不在表里（表换了，结论失效）、
    # 键已经在我们的代码里出现（那它根本不该再挂"未见"的结论）。
    # ⚠ 三个键要**互相独立**：上一版我把"已被用上"那条写成了同时不在表里，于是它一次
    # 撞上两条规则，期望值算错——自检当场把我抓红了，说明这个判据确实在咬。
    table = u'开机启动耗时\n已被用上的串\n别的串\n'
    corpus = u'lib 里已经写了 已被用上的串 一次'
    verdicts = {u'开机启动耗时': u'ok', u'查无此串的键': u'bad1',
                u'已被用上的串': u'bad2'}
    got = string_verdict_check(verdicts, table, corpus)
    want = 2
    print('    [%s] 失效检出 %d 条（应为 %d）：%s'
          % ('OK' if len(got) == want else 'FAIL', len(got), want,
             u'；'.join(got) or u'（无）'))
    print('[自检] 文案面结论表判据 %s' % ('通过' if len(got) == want else '失败'))
    return 0 if len(got) == want else 1


def audit_strings(min_len=4, short_only=True):
    rows = read(os.path.join(EXTRACTED, 'zh_strings.txt')).splitlines()
    strs = []
    for l in rows:
        if not l.strip():
            continue
        parts = l.rsplit('\t', 1)
        strs.append(parts[0].strip() if (len(parts) == 2 and parts[1].isdigit())
                    else l.strip())
    blob = dart_sources(only_ui=False) + read(
        os.path.join(ROOT, 'lib', 'services', 'rust_api.dart'))

    def norm(t):
        return re.sub(r'[，。：、「」（）%…\s]', '', t)

    nb = norm(blob)
    missing = []
    for s in sorted(set(strs)):
        if len(s) < min_len or 'http' in s or '@' in s:
            continue
        if short_only and len(s) > 12:
            continue
        if s in blob or (len(norm(s)) >= 5 and norm(s) in nb):
            continue
        missing.append(s)
    scope = '界面短标签(≤12字)' if short_only else '全部文案(不按长度过滤)'
    decided = [s for s in missing if s in STRING_VERDICTS]
    undecided = [s for s in missing if s not in STRING_VERDICTS]
    print('[3] 文案面：%s 里我们没出现过的 %d 条（共 %d 条去重文案），'
          u'其中**还没有结论的 %d 条**（另有 %d 条已判定，理由就地列出）'
          % (scope, len(missing), len(set(strs)), len(undecided), len(decided)))
    probs = string_verdict_check(
        STRING_VERDICTS, read(os.path.join(EXTRACTED, 'zh_strings.txt')), blob)
    for p in probs:
        print(u'    ⚠ 结论表失效：%s' % p)
    upd = [s for s in undecided
           if re.search(u'升级|更新|下载|安装包|版本|补丁', s)]
    if upd:
        print(u'    其中 %d 条属于**客户端更新/补丁流程**：对面的 classes 里有 '
              u'`_ClientUpdateDialogContentState`，而我们没有更新源与安装器'
              u'（同一件事也挂在 5 个安装 codec 与 `restart_application2` 的负向结论上）——'
              u'这批不是措辞没抄，是一整条缺失的功能，别逐条去"补文案"' % len(upd))
    for s in undecided:
        print('    未见 %s' % s)
    for s in decided:
        print(u'    已判定 %s —— %s' % (s, STRING_VERDICTS[s]))
    return undecided


def has_cjk(s):
    """串里有没有中日韩汉字。界面文案判据只看含中文的那批。"""
    return any(0x4E00 <= ord(c) <= 0x9FFF for c in s)


# 逐条**核过**的"这是我们自己的说法"，附核过的理由。
#
# 为什么集中放这里而不是在 17 个调用点各写一句注释：一条注释会替它附近好几条串
# 背书（本项目真的发生过——给标题写的"搜不到"注释顺手豁免了旁边没核过的副标题）。
# 放在一张表里 = 每句一次判断、一个出处，谁都能单独反驳。
#
# ⚠ 加进来之前要**先去文案表里搜过**，理由里写清搜了什么。
# 只凭"看起来像我们编的"就登记，等于把检查关掉。
KNOWN_OURS = {
    # ---- 2026-10-08 第四批：#98「应用中心」那张卡拉起来的四种回话 ----
    # 共同背景：参考实现的机器上客户端**总是在**，所以它从不需要说"未安装/起不来"。
    # 这四句是净室分支多出来的状态话，与 #20 那条「未配置」是同一层诚实——
    # 每条都附"搜过哪个词、零命中"，可反驳。
    '未安装认证客户端':
        '表内搜「未安装」零命中（grep -c 未安装 = 0）；工具箱「应用中心」点下去、'
        '探测到客户端不在默认安装位置时的那句话',
    '已启动认证客户端':
        '表内搜「已启动」零命中；只有桥层真的 spawn 成功（client_started=true）才说这句',
    '认证客户端未能启动':
        '表内搜「未能」零命中；客户端在、但没起来（返回 false）时说，**不冒充上一句的成功**',
    '无法确认认证客户端是否安装':
        '表内搜「无法确认」零命中；探测本身失败（null）时说——不并进"未安装"，'
        '那是把未知报成结论',
    # ---- 2026-10-08 第三批：最后 29 条逐条判完（三条值得单独说明）----
    # 发现①：我们的串是**两句原话拼起来的**，所以永远匹配不上任何一条表项
    '更新托盘菜单位置失败，重建托盘':
        '由原话「更新托盘菜单位置失败」(:159) + 「重建托盘」(:211) 拼成；'
        '两句各自都在表里，拼接是我们做的（失败→自愈的因果要说清）',
    '重建托盘图标后仍无槽位，放弃菜单窗口':
        ':211「重建托盘」与 :267「创建托盘菜单窗口失败」是两条；这句是"重试之后仍失败"的终态',
    # 发现②：表里那条是**被截断的残句**，照抄会得到没头没尾的一句话
    '未检测到在用网卡，若无法上网请检查网络连接':
        '表内 :119 只有残句「若无法上网，请检查」（宾语被截掉），补语「网络连接」是我们的；'
        '行标签「未检测到在用网卡」表内零命中',
    '所选文件已不存在，没有可删除的内容':
        '表内的「不存在」类(:58/:73/:162/:163/:166)说的都是别的东西不存在；这句是删除前复探全失效',
    '组件】云电脑类型未取到（机型厂商与型号均为空）':
        '「组件】」那族(:530/:537/:202)本来就是日志句不是界面行；按 :549 的格式补的失败态',
    # 发现③：表里只有**泛指**，我们的标签要点名是哪一项失败
    '补丁列表读取失败': '表内只有泛指的「读取失败」(:583)；一屏几十项时分不出是什么读不到',
    '未取到机器标识，无法提交反馈': '表内只有「提交反馈」(:521)；这句说明拒因',
    '未配置不兼容应用清单，未做判定':
        ':192 是弹窗说明（「当安装不兼容应用时…」），不是"清单没配"这一态',
    '暂无可管理的开机启动项':
        ':107「暂无可清理项」是清理页空态；启动项页没有原话，**不拿别页的句子硬套**',
    '回收站已清空': '表内只有清空前确认语(:424)与后果说明(:490)，没有完成态那句',
    '当前网络环境测速': ':208「当前网速」已用在结果区抬头（另一槽位）；这行是副标题',
    '取消全选': '表内有「全选」(:209)、「重新加载」(:225)，但没有任何反选标签',
    '打开所在位置': '表内搜「所在位置」零命中；动作是 `open_file_dir` 开资源管理器',
    '查看进程': '同族于已登记的「看进程」；加速卡入口名，表内无',
    '查看已安装的补丁': ':151/:260 是长句陈述，不是卡片副标题',
    '列出系统已安装的补丁，可逐个卸载': '同上；这页实测动作就是逐个卸载，副标题按实写',
    '未发现带故障码的设备': ':142「未发现更新」是别的东西；WMI `ConfigManagerErrorCode` 全 0 的说法',
    '未检测到打印机': '表内只有分区名「打印机配置」(:310)，没有"没有打印机"这一态',
    '没有开机自启项': ':277 是失败日志句，不是空态；这行读到的是"确实没有"',
    '未检测到磁盘': '表内搜「未检测到磁盘」零命中；`getDiskInfoList` 返回空的读数',
    '未取得数据：': '表内搜「未取得数据」零命中；探针失败时的前缀（不写"正常"也不写"没有"）',
    '组件探针没有返回': '同上；WMI 无应答这一路',
    '系统未返回固件类型': '表内搜「固件」零命中；BIOS/UEFI 读数缺失的说法',
    '点击上报接口返回错误状态': '表内无；`/report/click/count` 返回非 2xx 时的日志',
    'tasklist 判定不可用，跳过本轮拉起': '表内搜「tasklist」零命中；命令名不是界面词',
    'Windows 详细版本': '表内只有「当前版本」这类；关于页这行点名是 Windows 那份',
    '镜像版本': '表内搜「镜像版本」零命中；读 `%ProgramData%` 下那份版本文件的一行',
    '请描述你遇到的问题…': ':584 是采集范围声明（长句），没有输入框 hint',
    '首次体检，检查过程不改动任何文件': '表内只有「上次体检时间」(:282)；"首次"与"不改文件"都是我们的说明',
    '正在读取常驻进程状态…': '与已登记的进行态说法同族（:57 那句是别页的「正在检测」）',
    # ---- 2026-10-08 第二批（逐条搜过表；理由写"搜什么零命中 + 这句在界面上是什么"）----
    # 设置页：三态读数与"每步单独回报"的说法，表内没有对应标签
    'hosts 被改写，将一并恢复默认内容': '表内搜「hosts」「改写」零命中；网络修复行的实测读数',
    '未能确认 hosts 与手动代理状态': '同上；探针读不到时的第三态说法（不能拿未知当正常）',
    '手动代理已开启，将一并关闭': '表内搜「手动代理」零命中（只有 :167 的 VPN 建议长句）',
    '手动代理已关闭': '同上；逐步回报里"这步做了"的说法',
    '当前 DNS 无有效配置': '表内搜「DNS」零命中；来自实测网卡 DNS 列表',
    'DHCP 未确认': '表内搜「DHCP」零命中；读不到状态时的第三态说法',
    'DNS 缓存已清理': '表内搜「缓存已清理」零命中；`ipconfig /flushdns` 这步的结果',
    'hosts 已恢复': '表内搜「hosts」零命中；`fix_host_configed` 成功那支的说法',
    '安装并启动守护服务': '表内相近的两条（「安装服务并启动」:132、「杀掉进程并启动服务」:311）'
                          '是日志/建议语，没有这条按钮标签；:311 那句已用在确认框正文里',
    '重启守护服务': '同上；"装了却停着"那一支的按钮标签',
    '开机自动启动': '表内搜「开机自动启动」零命中；开关标题（做不到什么已写在副标题）',
    '阻止云电脑息屏': '表内搜「息屏」「阻止」零命中；wakelock 开关标题',
    '打开系统存储感知设置': '表内只有「存储感知」:590 这个系统设置名，动宾短语是我们的',
    '打开系统代理设置': '表内只有「网络代理」:70 名词；跳转动作说法是我们的',
    '修改存储感知': '同上；确认框标题',
    '当前用户': '表内搜「当前用户」零命中；确认框里说明改的是 HKCU',
    '用记事本打开 hosts': '表内搜「记事本」零命中；hosts 被改写时才出现的动作行',
    '查看 Windows 自带的那份说明与清理计划': '表内搜「说明与清理」零命中；跳转 ms-settings 的说明行',
    '刷新状态': '表内搜「刷新状态」零命中（只有「暂无内容，请刷新试试」:181 是空态句）',
    '正在读取常驻进程状态…': '表内搜「常驻」零命中；进行态说法，与「正在检测」:57 不同槽位',
    '远程更新源尚未接入，暂时无法检测是否有新版本。': '坦白话：表内所有升级串都属于我们没有的那条更新流程',
    '缺少 netsh 接口名（不能用网卡描述代替）': '表内搜「netsh」零命中；这条是本轮修 netsh 接口名后加的守卫说明',
    '未知 CPU': '表内搜「未知」零命中；WMI 读不到 CPU 名时留空不如说明读不到',
    # 智慧盘页：材料只给了标题 :140 与说明 :456，过程态与磁盘选择都没有原话
    '未找到可用磁盘': '表内搜「可用磁盘」零命中；一张都挑不出来时的说法（不写"未生成"）',
    '目标磁盘：无': '表内搜「目标磁盘」零命中',
    '状态：未生成': '表内搜「未生成」零命中；`is_path_exits` 读到"不在"的说法',
    '正在生成…': '表内有「正在检测」:57，但没有生成态',
    '正在清理…': '同上；清理态（完成态用的是自带的「已清理」:457）',
    # 子窗口/原生通道的诊断行与球面标签
    '加速工具卡已定位': '表内搜「已定位」零命中；子窗口回实际矩形后的诊断',
    '加速工具卡 channel 已就绪': '表内搜「channel」零命中（原生通道名，不是界面词）',
    '托盘菜单已定位': '同上族；托盘菜单子窗定位诊断',
    '托盘菜单 channel 已就绪': '同上',
    '悬浮窗 channel 已就绪': '同上',
    '处理主窗口命令 send_data': '同上；`send_data` 是 Flutter 通道方法名',
    '应用兼容性': '表内只有事件名 `AppCompatibility_window` 与两句描述；体检行名是我们的概括',
    # ---- 2026-10-08 批量核过（每条都是"搜过哪个词、零命中"，可反驳）----
    # 状态读数类：表里只有**长句建议**或**日志句**，没有对应的行标签/状态词
    'CPU 占用过高': '表内搜「占用过高」零命中，只有长句「建议您关闭CPU占用率较高的应用」'
                    '(:215)——那是建议语，不是行标签',
    '未连接': '表内搜「未连接」零命中；首页网络行的两种实测读数之一',
    '连接正常': '表内搜「连接正常」零命中（「正常」只出现在协议长句里）',
    '往返时延': '表内搜「时延」「延迟」零命中；网速页量的是实测 RTT，这个名词是我们的',
    '外网探测可达': '表内搜「外网」「探测」零命中；`net_available` 单次探测的读数说法',
    '外网探测无响应': '同上；失败那一支的说法（不写成"断网"，因为只测了一个 IP:端口）',
    '原生侧无应答': '表内搜「应答」零命中；native channel 超时才有这句',
    '无人守护': '表内搜「守护」零命中；ResidentStatus 三态里"没在守"的那种说法',
    'GUI 会话内守护': '同上；服务没装时 GUI 自己顶上的那条状态',
    'hosts 本就干净，未改动': '表内搜「hosts」零命中；部分失败回报里必须把"没动"与"失败"分开',
    '机器标识': '表内搜「机器标识」零命中，只有日志句「从本地获取机器信息」(:54)；关于页一行',
    '网络修复（DNS/DHCP）': '表内搜「网络修复」零命中（只有日志「修复结果为」:66）；设置页行标题',
    '正在采样…': '表内有「正在检测」(:57) 与「正在更新」，但没有"采样"态；网速页测的是收发速率',
    # 跳转标签：表里**没有任何以「去」开头的条目**，也搜不到「看实测」「看进程」。
    # 它怎么给指路没有第二处证据，所以这类词只能是我们自己的（动作本身是真的）。
    '去处理': '表内无以「去」开头的标签；跳转目标本身有依据',
    '去清理': '同上',
    '去管理': '同上',
    '看实测': '表内搜「看实测」零命中；网速页确实做实测',
    '看进程': '表内搜「看进程」零命中；进程页是真的',
    # 分区/动作名：对应能力有 codec 或实机可读，但界面上叫什么没有证据
    '通用': '表内零命中；同类分区名它只有「其他」:253，已被另一区使用',
    '启用网卡': '表内搜「启用」零命中；能力是 netsh set admin=up',
    '常驻采集与守护': '表内搜「守护」零命中；能力有 agent/keep_alive 两个产物',
    '先看清被改了什么，再决定要不要恢复默认': '表内零命中；描述的是恢复默认前的确认步骤',
    '自动打包日志上传': '表内零命中；:584 是完整长句，装不进这行副标题',
    '网速测试': '表内只有「网络测速」:538（且夹在日志句里，单处证据不足）；'
                '路由名 net_speed_test 是自带的',
    # 智慧盘（本轮新页）的过程态：它的材料只给了标题:140 与说明:456
    '正在读取磁盘信息…': '表内零命中；本页是我们按 :140/:456/codec:86 复刻的',
    '未取得磁盘信息': '同上；这句说的是"没读到"那一路',
    '下载 / 上传 / 延迟 / 抖动': '表内搜「延迟」「抖动」零命中；测速页确实出这几项',
    '实测链路往返时延与采样窗口内的网卡收发速率': '表内零命中；描述真实测量口径',
    '开始测速': '表内只有「重新测速」:135（重测态用过了）；首次触发的词没有',
    '查看有没有带故障码的设备': '表内零命中；描述 WMI ConfigManagerErrorCode 那条真检查',
    # 两句"这开关现在做不到什么"的坦白话。表里没有对应原话——因为参考实现的
    # 升级服务与安装器都在我们这边**不存在**，它没有理由说这句话。
    '仅记住偏好；开机自启由安装器写入注册表，本程序不代其改动':
        '表内零命中；本项目无安装器，此开关只存 prefs（全仓无人据其写 Run 项）',
    '仅记住偏好；升级服务尚未接入，当前不会自动下载或安装任何更新':
        '表内零命中；本项目没有更新源与升级通道，必须说明做不到',
    # 法律条款：按仓库边界**刻意不抄**参考实现的协议原文（详见 project-public-repo-boundary）
    '用户协议 · 隐私政策（尚未提供）': '合规边界：不复制厂商协议原文，且如实标"尚未提供"',
    # 概览指标：概念与权重都是我们的（详见 dashboard_page 的 healthScore 上方）
    '设备健康评分': '表内搜「评分」零命中、classes/click/frb 搜 score 全空——概念是我们加的',
    '立即体检': '表内零命中；只沿用它的「立即X」构词(:189/:489)，动作是真接通的',
    '立即加速': '表内零命中；「一键加速」:439 与「完成加速」:60 已用在各自该处',
    # ---- 2026-10-08 第二十六轮：判据收紧/扩面之后才浮出来的三条 ----
    # 共同背景：这三条此前**不是"判过所以不报"，是判据看不见**——
    # ① 豁免窗口把当前代码行也算进去，于是"注释里出现这个串"恒真（收紧后可见 1 条）；
    # ② 赋给变量的整行被 skip 掉（扩面后可见 2 条）。
    # 登记标准与上面各条一致：每条都要能被单独反驳。
    '全面体检 · 启动检查 · 垃圾清理一键直达':
        '拼接句：表内自带「全面体检」（9 次）与「启动检查」（9 次）两段原话、'
        '「垃圾清理」:248 也在表里，只有「一键直达」零命中——拼接是界面做的，'
        '双向子串判据看不见拼接（与已登记的『更新托盘菜单位置失败，重建托盘』同族）；'
        '该串是首页头卡副标题（dashboard_page.dart:291）',
    '守护服务已重启':
        '表内搜「守护」「已重启」都零命中（表里带"重启"的只有「存在需要重启云电脑才生效的补丁」:260，'
        '那是补丁页挂起提示，不是这回事）；设置页重启常驻服务成功后的回执，'
        '只说我们真做成了的那一步（失败那支另有一句点名原因）',
    '暂无可执行的加速项':
        '表内搜「加速项」零命中，只有别页的空态「暂无可清理项」:107；'
        '加速卡的空态——源码注释写明参考实现只留了 `_AppAccelerationBallBlankEnteryState` 这个类名、'
        '没留下对应那句话，所以这里只陈述事实、不替它编',
}


REF_PATTERNS = [re.compile(r"(?:title|subtitle|actionLabel|label|emptyText|heading"
                           r"|titleText|buttonText)\s*:\s*'([^']+)'"),
                re.compile(r"Text\(\s*'([^']+)'"),
                # 引号紧跟在 `:` `(` `,` `?` 之后的串（三元式取真/取假的标签）。
                # ⚠ `?` 必须有：`Text(cond` 折行后是 `? '取消全选'`，
                #    只认 `:`/`(` 时这种行一条都匹配不上（实测被自检用例抓到）。
                re.compile(r"[:?,(]\s*'([^']*[一-鿿][^']*)'"),
                # ---- 第四种写法：**赋给变量的整行**（`final/var/const x = '…';`）----
                # 这种行此前被整行 skip，于是"先赋给变量、再画上去"的界面串
                # 这一面**永远看不见**。实测扩面后新看见 2 条
                # （`守护服务已重启`、`暂无可执行的加速项`），两条此前只能靠人想起来。
                re.compile(r"^\s*(?:final|var|const|late)\s+(?:String\s+)?\w+"
                           r"\s*=\s*'([^']+)'\s*;")]
# 这些调用画的不是界面，是日志/调试输出
NOT_UI = re.compile(r"^(logInfo|logWarn|logError|debugPrint|print)")

# 注释里出现过这些字样就算"已注明是我们的说法"
INVENTION_MARKERS = ('自造', '我们的说法', '自己的说法', '自己造', '不是它的说法',
                     '零命中', '搜不到', '参考实现没有', '没有这句')


def _attested_by_table(s, ref):
    """这句是不是"照着表里的说法说的"。

    先剥掉句尾的省略号/句号/叹号：我们自己给状态词加的 `…`（`正在检测…`）
    不该让一句**表里原话**（`正在检测`）变成"自造"——那是把标点差异
    误报成措辞差异，读数是虚高。
    """
    s = s.rstrip(u'…。.！!，,、 ')
    for t in ref:
        if len(t) < 2:
            continue
        if s in t:
            return True
        # 反方向必须**几乎 cover 住我们这句**才算自带。
        # 旧写法是 `t in s`（只要求表里那条 ≥2 字），于是长自造串只要含
        # 「全选」「占用」「应用」这种两字表格词就被判成"照抄"——
        # 这一面只会因此**偏乐观**（长期报 0）。收紧后实测有 20 条改判。
        tt = t.rstrip(u'…。.！!，,、 ')
        if len(tt) >= 6 and len(tt) >= len(s) - 2 and tt in s:
            return True
    return False


def collect_invented(root_dir, ref):
    """扫 `root_dir/lib` 下画到界面上的中文串，返回**没注明**的自造串。

    提取要覆盖四种写法（前两种是最初就有的，后两种都是**实测到的盲区**——
    每多认一种，"0 条"才更接近"都查过了"）：
      ① `title: '…'` / `emptyText: '…'` 这类字段；
      ② `Text('…')` 同行紧跟；
      ③ **跨行的三元标签**——`dart format` 会把
         `Text(cond ? '取消全选' : '全选')` 折成 `? '取消全选'` 单独一行，
         那种行既没有字段名也没有 `Text(`，旧提取一条都不匹配 ⇒
         「取消全选」这类标签整面检查都看不见；
      ④ **赋给变量的整行**（`final x = '…';`）——此前整行被 skip，
         "先赋给变量、再画上去"的串这一面永远看不见。
    """
    out = []
    for base, _dirs, files in os.walk(root_dir):
        n = base.replace('\\', '/')
        if '/src/' in n or n.endswith('/src'):
            continue
        if not (n.endswith('pages') or n.endswith('widgets')
                or n.endswith('services') or n.endswith('windows')):
            continue
        for f in files:
            if not f.endswith('.dart'):
                continue
            lines = read(os.path.join(base, f)).splitlines()
            for i, ln in enumerate(lines):
                if ln.strip().startswith(('//', '///')):
                    continue
                # 只取第一个 `//` 之前的代码部分；引号字符串里的 `//`（URL）不管
                code = ln.split('//')[0]
                stmt = code.lstrip()
                if NOT_UI.match(stmt):
                    continue      # 日志串不是界面文案，不归这一面管
                seen = set()
                for p in REF_PATTERNS:
                    for m in p.finditer(code):
                        s = m.group(1).strip()
                        if not has_cjk(s) or len(s) > 24 or '$' in s:
                            continue
                        if s in seen:
                            continue
                        seen.add(s)
                        if _attested_by_table(s, ref):
                            continue
                        # 豁免必须**点名这句**：本行**上方**的注释里出现这个串本身。
                        # 两处都是实测出来的，不是照着原意写的：
                        #  * 只认"附近有没有 自造/搜不到 之类字样"太宽——一次注释会替旁边
                        #    好几条串背书（本项目真发生过）。收紧到"上方注释点名该串"后
                        #    实测新看见 1 条（`全面体检 · 启动检查 · 垃圾清理一键直达`）。
                        #  * 窗口**不能含本行**：串就写在当前行，含了 `s in window` 恒真，
                        #    这条判据等于没写——第一版探针就是这么得出"零变化"的假象，
                        #    重量后才发现真放行了 3 条。
                        above = '\n'.join(lines[max(0, i - 10):i])
                        if s in above and any(k in above for k in INVENTION_MARKERS):
                            continue
                        out.append((s, '%s:%d' % (n + '/' + f, i + 1)))
    return out


def audit_invented_text():
    """反向查：我们画到界面上的中文，参考实现的文案表里**有没有说过**。

    这是 `strings` 那一面的**反向**，两者抓的是不同的东西：
      * `strings`：参考实现说过、我们没说 —— 找"漏对齐的措辞"；
      * 这一面：我们说了、参考实现**没说** —— 找"**我们自己编的措辞**"。
    只做前者会留一个盲区：自造的句子永远不被报（本项目工具箱四张卡的副标题
    全都是零命中，靠人想起来逐条搜才发现）。

    判据不是"必须照抄参考实现"——法律条款、我们自己的产品说法都合理。
    要求是**要么用自带的词，要么在注释里点名写清这是我们自己的说法**：
    沉默的自造最坏，因为它看起来像照抄来的。
    """
    blob = read(os.path.join(EXTRACTED, 'zh_strings.txt'))
    ref = [ln.split('\t')[0].strip()
           for ln in blob.splitlines() if ln.strip()]
    raw = collect_invented(ROOT, ref)
    # 登记过的（`KNOWN_OURS`，附核过的理由）不算"未注明的自造"；其余才是真问题
    offenders = [x for x in raw if x[0] not in KNOWN_OURS]

    # 同一句在多处出现只算一条（报第一处的位置，方便定位）
    seen, uniq = set(), []
    for s, loc in offenders:
        if s in seen:
            continue
        seen.add(s)
        uniq.append((s, loc))
    print('[5] 自造面：我们画上界面、参考实现文案表里**没有**的说法 %d 条'
          % len(uniq))
    for s, loc in uniq:
        print('    自造 %s  (%s)' % (s, loc))

    # 登记表也会腐烂：串已经改了/删了，条目还留着，就等于长期替一句**不再存在**的话背书。
    # ⚠ 判"还在不在"要直接看源码文本，**不能用上面那条 `used`**：走到"表里已有"就
    # `continue` 的串根本到不了 `used`，那样会把一堆**仍然在用**的条目误报成僵尸（实测过）。
    all_src = []
    for root, _dirs, files in os.walk(os.path.join(ROOT, 'lib')):
        n = root.replace('\\', '/')
        if '/src/' in n or n.endswith('/src'):
            continue
        for f in files:
            if f.endswith('.dart'):
                all_src.append(read(os.path.join(root, f)))
    src_blob = '\n'.join(all_src)
    stale = [s for s in KNOWN_OURS if s not in src_blob]
    if stale:
        print('    ⚠ 登记表里有 %d 条本轮没在代码中遇到（措辞已改或已删，条目该撤）：'
              % len(stale))
        for s in stale:
            print('       僵尸 %s' % s)
    return uniq


# 页面清单里"缺"的三个名字，逐个**核过之后性质不同**——不把结论写下来，
# 下一轮就会有人为了把这条数字清零而把已对齐的东西重做一遍。
PAGE_VERDICTS = {
    # 内容已逐字对齐（「反馈提交成功」:518 / 「感谢您的反馈，我们会尽快处理」:144 /
    # 「再次提交」:551），只是我们做成反馈页里的一个阶段而非独立路由。
    'FeedbackSuccess': '已覆盖，形态不同（页内阶段）——别为凑数拆成路由',
    # 协议正文是厂商法律文本，按仓库边界刻意不复制；设置那行如实写「尚未提供」。
    'UserAgreement': '按合规边界不做（法律文本不入库），入口已存在且标注未提供',
    # 页面确实存在，但**内容零证据**：文案表里没有该页的标题/布局串。
    'Error': '内容无第二证据，不做（照类名编就是造功能）',
}


def audit_page_routes():
    """页面清单对照：`page_route_extensions.txt` 里每个页面名都得有我们的路由。

    这份材料此前**从没被用过**（一直只看 classes / zh_strings / routes_ui / frb_calls /
    click_events 五份），是个实打实的证据盲区。它是"页面名"清单，比 `routes_ui.txt`
    的完整路径更抗重构：路由怎么嵌套、路径写成相对还是绝对都不影响比对。

    比对方式：参考实现给的是 PascalCase 后缀（`SecurityDisk`、`DeepCleanScan`），
    我们路由表里是 snake_case（`security_disk`），所以按"驼峰转下划线"归一后再比。
    """
    path = os.path.join(EXTRACTED, 'page_route_extensions.txt')
    if not os.path.isfile(path):
        print('[6] 页面面：没有 page_route_extensions.txt，跳过')
        return []
    names = [ln.strip() for ln in read(path).splitlines() if ln.strip()]
    routes = read(os.path.join(ROOT, 'lib', 'core', 'routes.dart'))

    def snake(name):
        out = re.sub(r'(?<!^)(?=[A-Z])', '_', name).lower()
        # 连续大写与数字边界（SyStemDiskFiles → sy_stem... 这类怪拼写）：
        # 一并把下划线折叠，两种写法都算命中
        return re.sub(r'_+', '_', out)

    missing = []
    for n in names:
        s = snake(n)
        if s in routes or n.lower().replace('_', '') in routes.replace('_', ''):
            continue
        missing.append((n, s))
    undecided = [(n, s) for n, s in missing if n not in PAGE_VERDICTS]
    print('[6] 页面面：参考实现 %d 个页面，路由表里找不到的 %d 个'
          '（其中 **%d 个还没有结论**）'
          % (len(names), len(missing), len(undecided)))
    for n, s in missing:
        verdict = PAGE_VERDICTS.get(n)
        if verdict:
            print('    已定论 %s —— %s' % (n, verdict))
        else:
            print('    缺页面 %s（期望路由含 %s）' % (n, s))
    return [m[0] for m in undecided]


FIXTURE_RS = u'''
pub fn a_clean() -> Result<()> {
    // frb codec: crateApiAA
    Ok(())
}

/// ⚠ **故意不给出口**：b 的理由
pub fn b_marked() -> Result<()> {
    // frb codec: crateApiBB
    Ok(())
}

pub fn c_body_marker() -> Result<()> {
    // frb codec: crateApiCC
    // ⚠ 故意不给出口：理由写在函数体里
    let x = 1;
    Ok(())
}

/// ⚠ **故意不给出口**：d 是上一个函数
pub fn d_marked() -> Result<()> {
    Ok(())
}

/// 说明里提到 codec 字面量 crateApiEE，但它属于 e
pub fn e_clean() -> Result<()> {
    Ok(())
}
'''


def selftest_verdicts():
    """判据自己得能被证伪：造一份假源码，看结论认得对不对。

    四条各挡一种真实的翻车方式：
      ①② 有标记/没标记要分得开（否则「待判定」永远是 0，白体检）；
      ③ 标记写在函数体里也要认（真项目里 start_exe 就是这么写的）；
      ④ codec 字面量出现在**别人的**文档注释里时，不能把别人的结论背过来
         ——这是最容易出假阴性的地方：一旦串味，待判定条数会莫名变少。
    """
    global RUST_FILES
    d = tempfile.mkdtemp(prefix='cm_verdict_selftest_')
    path = os.path.join(d, 'fixture.rs')
    with io.open(path, 'w', encoding='utf-8') as f:
        f.write(FIXTURE_RS)
    saved, RUST_FILES = RUST_FILES, [path]
    cases = [
        ('crateApiAA', 'a_clean', None),
        ('crateApiBB', 'b_marked', 'found'),
        ('crateApiCC', 'c_body_marker', 'found'),
        ('crateApiEE', 'e_clean', None),
    ]
    bad = []
    for codec, name, want in cases:
        got = verdict_for(codec, name)
        ok = (got is None) if want is None else (got is not None)
        print('    [%s] %s -> %s' % ('OK' if ok else 'FAIL', name,
                                     (got or '（无结论）')))
        if not ok:
            bad.append(name)
    # d_marked 的结论必须归它自己，且 e_clean 不能被它污染
    if verdict_for('crateApiDD', 'd_marked') is None:
        bad.append('d_marked')
    RUST_FILES = saved
    shutil.rmtree(d, ignore_errors=True)
    print('[自检] 可达面结论判据 %s' % ('通过' if not bad else '失败: %s' % bad))
    return 0 if not bad else 1


def audit_clicks():
    """第七面：点击埋点的事件名集合是否与参考实现一致。

    为什么单列：文案面看的是"说了什么话"，看不见"用户能点什么"。事件名是
    **控件存在的直接证据**（`click_RAM_window_expedite` 就指着加速卡上那个按钮），
    而且这份材料是现成的对照表——少一个名字就等于我们少一个可点的控件，或者
    多一个凭空造的控件。本项目此前只对着它接过埋点（#19/#20），没有把这层
    对照**钉成判据**。
    """
    ref = {l.split('\t')[0].strip()
           for l in read(os.path.join(EXTRACTED, 'click_events.txt')).splitlines()
           if l.strip().startswith('click')}
    dart = read(os.path.join(ROOT, 'lib', 'services', 'click_report.dart'))
    # 白名单里只有**字面量**条目算事件名；拼名字用的模板串（`'click_${k}_$a'`）
    # 不是控件，按 `'click_...'` 抓会把它当成多出来的一个。
    ours = {x for x in re.findall(r"'(click_[^']+)'", dart) if '${' not in x}
    missing, extra = sorted(ref - ours), sorted(ours - ref)
    print(u'[7] 埋点面：参考实现 %d 个点击事件名，我们白名单缺 %d 个、多 %d 个'
          % (len(ref), len(missing), len(extra)))
    for x in missing:
        print(u'    缺事件名 %s（对应一个我们没做的控件）' % x)
    for x in extra:
        print(u'    多出 %s（材料里没有这个名字）' % x)
    return missing, extra


FIXTURE_DART = u'''class Probe {
  Widget build() => Column(children: [
    Text(cond
        ? '编的一个说法甲乙丙丁'
        : '全选'),
    const Text('存储空间管理'),
    final assign = '赋给变量的标签甲乙';
    // 这句「有注释点名的标签」是我们的说法，表里零命中——点名式豁免
    subtitle: '有注释点名的标签',
    // 上面只说了"这里是自造的说法"，并没有点名下面那句
    subtitle: '周边有自造字样但没被点名的标签',
    logError('日志里的串不该算界面文案');
    subtitle: '另一句随机中文标签',
    emptyText: '正在检测…',
  ]);
}
'''


def selftest_invented():
    """自造面的提取必须看得见四种写法，且**不放行**没被点名的串。

    两条返工换来的判据，各由用例钉住，不靠我下次想起来：
      * `dart format` 把 `Text(cond ? A : B)` 折成三行，旧提取一条都不匹配
        ⇒ 界面上一句自造标签可以永远不被看见，而这一面一直报"0 条"；
      * 赋给变量的整行被 skip（第四种写法）；
      * 豁免原来只看"上方有没有 自造/搜不到 之类字样"，一次注释会替邻串背书
        ⇒ 现在必须**点名该串**，`周边有自造字样但没被点名的标签` 就是这条的阴性对照。
    """
    d = tempfile.mkdtemp(prefix='cm_invented_selftest_')
    pages = os.path.join(d, 'lib', 'pages')
    os.makedirs(pages)
    with io.open(os.path.join(pages, 'probe.dart'), 'w', encoding='utf-8') as f:
        f.write(FIXTURE_DART)
    ref = [ln.split('\t')[0].strip()
           for ln in read(os.path.join(EXTRACTED, 'zh_strings.txt')).splitlines()
           if ln.strip()]
    found = {s for s, _ in collect_invented(d, ref)}
    want_in = [u'编的一个说法甲乙丙丁', u'另一句随机中文标签',
               u'赋给变量的标签甲乙',             # 第四种写法：赋给变量
               u'周边有自造字样但没被点名的标签']  # 有 marker 但没点名 ⇒ 不许豁免
    want_out = [u'全选', u'存储空间管理', u'日志里的串不该算界面文案',
                u'正在检测…',                    # 表里有「正在检测」，只是加了省略号
                u'有注释点名的标签']              # 上方注释点名了它 ⇒ 豁免成立
    problems = [u'%s 没被抓到' % s for s in want_in if s not in found]
    problems += [u'%s 被误报' % s for s in want_out if s in found]
    for s in sorted(found):
        print('    抓到 %s' % s)
    for p in problems:
        print('    [FAIL] %s' % p)
    shutil.rmtree(d, ignore_errors=True)
    print(u'[自检] 自造面提取判据 %s' % ('通过' if not problems else u'失败'))
    return 0 if not problems else 1


def main():
    which = sys.argv[1] if len(sys.argv) > 1 else 'all'
    if which == 'selftest':
        return (selftest_verdicts() + selftest_wiring()
                + selftest_string_verdicts() + selftest_invented())
    os.chdir(ROOT)
    if not os.path.isdir(EXTRACTED):
        print('没有 docs/extracted/（提取产物不入库），无法体检')
        return
    if which in ('all', 'api'):
        audit_api()
    if which in ('all', 'reachable'):
        audit_reachable()
    if which in ('all', 'wiring'):
        audit_wiring()
    if which in ('all', 'strings', 'strings-all'):
        audit_strings(short_only=(which != 'strings-all'))
    if which in ('all', 'invented'):
        audit_invented_text()
    if which in ('all', 'pages'):
        audit_page_routes()
    if which in ('all', 'clicks'):
        audit_clicks()


if __name__ == '__main__':
    sys.exit(main() or 0)
