#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""mini-jq —— 项目实际用到的 jq 过滤语法的最小实现（**测试桩**，不是 jq）。

为什么需要：本机没有 jq，而仓库里有 119 处 jq 调用（lib/core.sh、lib/rules.sh、
lib/update.sh、notifications/*.sh、port-traffic-dog.sh）。不装 jq 就等于
「整段依赖 jq 的配置生成路径」完全没被测过。

桩的纪律（重要）：
  1. **只实现仓库里真实出现过的过滤器**；
  2. 遇到不支持的语法 → stderr 打印 `jq-stub: 桩能力不足：<表达式>` 并以**退出码 3** 结束
     —— 让调用方的兜底分支真的走到，而不是悄悄返回空值「假装成功」；
  3. **能力检测与数据无关**：先做一遍语法校验，再求值。
     （否则「数据刚好没走到那个分支」时就会静默返回空值 → 看起来测过了，其实没测。）
  4. 不做通用 jq。宁可显式说「我不会」，也不要假装会。

支持（来自仓库实际用法）：
  .tag_name // empty
  .assets[]? | select(.name==$n) | .digest // empty
  .network.send_proxy // false
  .network | {send_proxy, send_proxy_version, accept_proxy, accept_proxy_timeout}
             | to_entries | map(select(.value != null)) | from_entries
  del(.network.send_proxy) | del(.network.send_proxy_version) | ...
  .network.send_proxy = true | .network.send_proxy_version = 2 | ...
  . + {"send_proxy": true}          ← lib/core.sh 是把变量插进过滤器文本用的
  .notifications.telegram.enabled // false
  .notifications.telegram.bot_token // ""
  .notifications.telegram.status_notifications.interval
  .nftables.table_name / .ports."8080".billing_mode // "double"
  keys | length | keys[]
  .endpoints[0]                  ← 第 7 轮：段后面的数组下标
  -e                             ← 第 7 轮：退出码语义（null/false → 1，无输出 → 4）

输出格式说明：桩固定输出**紧凑 JSON**（jq -c 的形态）。
真 jq 默认是缩进输出，差别只在空白，不影响 JSON 语义；
用例断言一律按**语义**（解析后的键值）判，不按字节。
"""

import copy
import json
import re
import sys

UNSUPPORTED = "jq-stub: 桩能力不足"


class Unsupported(Exception):
    def __init__(self, expr):
        super().__init__(expr)
        self.expr = expr


def die(expr):
    print("%s：%s" % (UNSUPPORTED, expr), file=sys.stderr)
    sys.exit(3)


# ---------------------------------------------------------------- 词法工具

def split_top(s, sep):
    """按 sep 切分，跳过引号内 / 括号内的分隔符。"""
    out, depth, buf, i = [], 0, [], 0
    in_q = None
    while i < len(s):
        c = s[i]
        if in_q:
            buf.append(c)
            if c == "\\" and i + 1 < len(s):
                buf.append(s[i + 1])
                i += 2
                continue
            if c == in_q:
                in_q = None
            i += 1
            continue
        if c in "\"'":
            in_q = c
            buf.append(c)
            i += 1
            continue
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        if depth == 0 and s.startswith(sep, i):
            out.append("".join(buf))
            buf = []
            i += len(sep)
            continue
        buf.append(c)
        i += 1
    out.append("".join(buf))
    return out


def path_segments(path):
    """把 .a.b."c"[d] 拆成 ['a','b','c','d']；'.' 本身 → []（整个对象）。

    ★ 第 7 轮扩展：支持**段后面的数组下标** `.endpoints[0]`。
      原来只认「. 后面紧跟 [」，所以 `.endpoints[0]` 只被解析成 ['endpoints']
      —— 取出来是整个数组，OCR 脚本读单个 endpoint 就全空了（静默失败，还看不出来）。
      现在下标作为独立的一段：数字 → 数组下标；带引号 → 对象键。
    """
    segs, i = [], 0
    while i < len(path):
        c = path[i]
        if c == "[":
            j = path.find("]", i)
            if j < 0:
                raise Unsupported(path)
            inner = path[i + 1:j].strip()
            if len(inner) >= 2 and inner[0] == '"' and inner[-1] == '"':
                inner = inner[1:-1]
            segs.append(inner)
            i = j + 1
            continue
        if c != ".":
            i += 1
            continue
        i += 1
        if i < len(path) and path[i] == '"':
            j = path.find('"', i + 1)
            if j < 0:
                raise Unsupported(path)
            segs.append(path[i + 1:j])
            i = j + 1
        else:
            j = i
            while j < len(path) and (path[j].isalnum() or path[j] == "_"):
                j += 1
            if j > i:
                segs.append(path[i:j])
                i = j
    return segs


def _as_index(seg):
    try:
        return int(seg)
    except (TypeError, ValueError):
        return None


def get_path(obj, path):
    cur = obj
    for s in path_segments(path):
        if isinstance(cur, dict) and s in cur:
            cur = cur[s]
        elif isinstance(cur, list):
            idx = _as_index(s)
            if idx is None or idx < 0 or idx >= len(cur):
                return None
            cur = cur[idx]
        else:
            return None
    return cur


def set_path(obj, path, value):
    segs = path_segments(path)
    if not segs:
        return
    cur = obj
    for s in segs[:-1]:
        if isinstance(cur, dict):
            if s not in cur or not isinstance(cur[s], (dict, list)):
                cur[s] = {}
            cur = cur[s]
        elif isinstance(cur, list):
            idx = _as_index(s)
            if idx is None or idx < 0 or idx >= len(cur):
                return
            cur = cur[idx]
        else:
            return
    last = segs[-1]
    if isinstance(cur, dict):
        cur[last] = value
    elif isinstance(cur, list):
        idx = _as_index(last)
        if idx is not None and 0 <= idx < len(cur):
            cur[idx] = value


def delete_path(obj, path):
    segs = path_segments(path)
    if not segs:
        return
    cur = obj
    for s in segs[:-1]:
        if isinstance(cur, dict) and s in cur:
            cur = cur[s]
        elif isinstance(cur, list):
            idx = _as_index(s)
            if idx is None or idx < 0 or idx >= len(cur):
                return
            cur = cur[idx]
        else:
            return
    last = segs[-1]
    if isinstance(cur, dict):
        cur.pop(last, None)
    elif isinstance(cur, list):
        idx = _as_index(last)
        if idx is not None and 0 <= idx < len(cur):
            del cur[idx]


def parse_value(tok, args):
    tok = tok.strip()
    if tok == "true":
        return True
    if tok == "false":
        return False
    if tok == "null":
        return None
    if tok.startswith("$"):
        name = tok[1:]
        if name not in args:
            raise Unsupported(tok)
        return args[name]
    if len(tok) >= 2 and tok[0] == '"' and tok[-1] == '"':
        return tok[1:-1]
    # ★ 第 7 轮扩展：JSON 对象/数组字面量
    #   仓库里 port-traffic-dog.sh 用 `jq ".\"$port\" = {\"input\": $v, ...}"`，
    #   bash 会先把 $v 插值进过滤器文本 → 传进 jq 的是一段合法 JSON。
    if tok[:1] in ("{", "["):
        try:
            return json.loads(tok)
        except ValueError:
            raise Unsupported(tok)
    if re.match(r"^-?\d+$", tok):
        return int(tok)
    if re.match(r"^-?\d+\.\d+$", tok):
        return float(tok)
    raise Unsupported(tok)


def parse_operand(tok, args):
    """`. + X` 的右操作数：$变量 或 JSON 字面量。

    注意：仓库里 lib/core.sh 是把变量**插进过滤器文本**里用的
    （`jq ". + $existing_proxy"`）—— 实际传进 jq 的是 `. + {"send_proxy": true}`，
    所以这里必须支持 JSON 对象字面量，不能只认 $var。
    """
    tok = tok.strip()
    if tok.startswith("$"):
        name = tok[1:]
        if name not in args:
            raise Unsupported(tok)
        return args[name]
    try:
        return json.loads(tok)
    except ValueError:
        raise Unsupported(tok)


COND_RE = re.compile(
    r"^\.([A-Za-z_][A-Za-z0-9_]*)\s*(!=|==)\s*(null|true|false|\"[^\"]*\"|\$[A-Za-z_][A-Za-z0-9_]*)$"
)

STAGE_SET = ("to_entries", "from_entries", "keys", "keys[]", "length")


def validate_stage(st, args):
    """**先验语法检查**（与数据无关）。

    为什么必须有这一层：如果只在求值时才发现不支持，
    那么「数据刚好没走到那个分支」时就会静默返回空值 → 看起来测过了，其实没测。
    桩必须**无条件**说清楚「这一条我不会」。
    """
    st = st.strip()
    if not st:
        return

    parts = split_top(st, "//")
    if len(parts) == 2:
        validate_stage(parts[0], args)
        default = parts[1].strip()
        if default == "empty":
            return
        # 备选值可能是字面量（// false / // "" / // 0），也可能是路径
        try:
            parse_value(default, args)
            return
        except Unsupported:
            validate_stage(default, args)
            return

    m = re.match(r"^del\((.*)\)$", st, re.S)
    if m:
        for p in split_top(m.group(1), ","):
            p = p.strip()
            if not p.startswith("."):
                raise Unsupported(st)
        return

    m = re.match(r"^(\.[^=|]*?)\s*=\s*(.+)$", st, re.S)
    if m:
        parse_value(m.group(2), args)
        return

    if re.match(r"^\{(.*)\}$", st, re.S):
        return

    if st in STAGE_SET:
        return

    m = re.match(r"^map\((.*)\)$", st, re.S)
    if m:
        validate_stage(m.group(1).strip(), args)
        return

    m = re.match(r"^select\((.*)\)$", st, re.S)
    if m:
        cond = m.group(1).strip()
        if not COND_RE.match(cond):
            raise Unsupported(cond)
        return

    m = re.match(r"^\.\s*\+\s*(.+)$", st, re.S)
    if m:
        parse_operand(m.group(1), args)
        return

    if re.match(r"^(\.[^\[\]]*)\[\]\??$", st):
        return

    # ★ 第 7 轮：显式拒绝「会被静默误解」的危险语法
    #   `..`（递归下降）：原来会被解析成「整个对象」→ 结果有输出但语义全错
    #   `?` 单独出现：可选操作符，桩没实现
    #   这类语法必须报「桩能力不足」，不能给一个看着对的错答案。
    if st == ".." or st == "..." or st == "?":
        raise Unsupported(st)

    if st.startswith("."):
        return

    raise Unsupported(st)


def eval_cond(cond, v, args):
    """只支持 select() 里用到的几种比较。"""
    cond = cond.strip()
    m = COND_RE.match(cond)
    if not m:
        raise Unsupported(cond)
    key, op, rhs = m.group(1), m.group(2), m.group(3)
    left = v.get(key) if isinstance(v, dict) else None
    if rhs == "null":
        right = None
    elif rhs == "true":
        right = True
    elif rhs == "false":
        right = False
    elif rhs.startswith("$"):
        right = args.get(rhs[1:])
    else:
        right = rhs[1:-1]
    return (left != right) if op == "!=" else (left == right)


def eval_stage(st, v, args):
    st = st.strip()
    if not st:
        return [v]

    # 备选运算符 A // B
    parts = split_top(st, "//")
    if len(parts) == 2:
        left = eval_stage(parts[0].strip(), v, args)
        if left and left[0] is not None and left[0] is not False:
            return left
        default = parts[1].strip()
        if default == "empty":
            return []
        try:
            return [parse_value(default, args)]
        except Unsupported:
            return eval_stage(default, v, args)

    # del(.a.b)
    m = re.match(r"^del\((.*)\)$", st, re.S)
    if m:
        obj = copy.deepcopy(v)
        for p in split_top(m.group(1), ","):
            p = p.strip()
            if p:
                delete_path(obj, p)
        return [obj]

    # 赋值 .a.b = value
    m = re.match(r"^(\.[^=|]*?)\s*=\s*(.+)$", st, re.S)
    if m:
        obj = copy.deepcopy(v)
        set_path(obj, m.group(1).strip(), parse_value(m.group(2), args))
        return [obj]

    # 对象构造 {a, b, c}：jq 语义是取**当前对象的字段**
    m = re.match(r"^\{(.*)\}$", st, re.S)
    if m:
        out = {}
        for k in split_top(m.group(1), ","):
            k = k.strip()
            if not k:
                continue
            if isinstance(v, dict) and k in v:
                out[k] = v[k]
            else:
                out[k] = None
        return [out]

    if st == "to_entries":
        if not isinstance(v, dict):
            return []
        return [[{"key": k, "value": v[k]} for k in v]]
    if st == "from_entries":
        if not isinstance(v, list):
            return []
        return [{e["key"]: e["value"] for e in v}]
    if st == "keys":
        return [list(v.keys())] if isinstance(v, dict) else []
    if st == "keys[]":
        return list(v.keys()) if isinstance(v, dict) else []
    if st == "length":
        if isinstance(v, (dict, list, str)):
            return [len(v)]
        return [0]

    # map(...)
    m = re.match(r"^map\((.*)\)$", st, re.S)
    if m:
        inner = m.group(1).strip()
        out = []
        if isinstance(v, list):
            for item in v:
                out.extend(eval_stage(inner, item, args))
        return [out]

    # select(...)
    m = re.match(r"^select\((.*)\)$", st, re.S)
    if m:
        return [v] if eval_cond(m.group(1), v, args) else []

    # . + X（$变量 或 JSON 字面量）
    m = re.match(r"^\.\s*\+\s*(.+)$", st, re.S)
    if m:
        other = parse_operand(m.group(1), args)
        if not isinstance(other, dict) or not isinstance(v, dict):
            raise Unsupported(st)
        merged = copy.deepcopy(v)
        merged.update(other)
        return [merged]

    # 数组迭代 .foo[] / .foo[]?
    m = re.match(r"^(\.[^\[\]]*)\[\]\??$", st)
    if m:
        arr = get_path(v, m.group(1).strip())
        return list(arr) if isinstance(arr, list) else []

    # 普通路径访问
    if st.startswith("."):
        return [get_path(v, st)]

    raise Unsupported(st)


def eval_filter(expr, data, args):
    stages = split_top(expr, "|")
    # 先验校验（与数据无关）：不支持的语法必须无条件报出来
    for st in stages:
        validate_stage(st, args)
    values = [data]
    for st in stages:
        st = st.strip()
        if not st:
            continue
        nxt = []
        for v in values:
            nxt.extend(eval_stage(st, v, args))
        values = nxt
    return values


def format_value(v, raw):
    """输出格式：紧凑 JSON（= jq -c 的形态）。

    真 jq 默认是缩进输出，桩固定紧凑 —— 差别只在空白，不影响 JSON 语义。
    用例断言一律按语义判，不按字节。
    """
    if raw and isinstance(v, str):
        return v
    return json.dumps(v, ensure_ascii=False, separators=(",", ":"))


def main(argv):
    raw = False
    exit_on_error = False
    args = {}
    expr = None
    files = []
    i = 0
    # 输出统一 UTF-8：Windows 控制台默认编码会把中文标记弄成乱码，
    # 而「桩能力不足」这个标记必须能被用例稳定地 grep 到。
    try:
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    except Exception:  # noqa: BLE001
        pass
    try:
        while i < len(argv):
            a = argv[i]
            if a == "-r":
                raw = True
            elif a == "--arg":
                args[argv[i + 1]] = argv[i + 2]
                i += 2
            elif a.startswith("--arg"):
                args[a[len("--arg"):]] = argv[i + 1]
                i += 1
            elif a == "-e":
                exit_on_error = True
            elif a in ("-n", "-c", "--compact-output", "--raw-output"):
                pass
            elif a.startswith("-") and len(a) > 1:
                raise Unsupported(a)
            elif expr is None:
                expr = a
            else:
                files.append(a)
            i += 1
        if expr is None:
            raise Unsupported("<空过滤器>")

        if files:
            try:
                with open(files[0], "r", encoding="utf-8") as f:
                    data = json.load(f)
            except OSError as e:
                print("jq-stub: 读不到输入：%s" % e, file=sys.stderr)
                return 3
            except ValueError as e:
                print("jq-stub: 输入不是合法 JSON：%s" % e, file=sys.stderr)
                return 3
        else:
            text = sys.stdin.read()
            try:
                data = json.loads(text) if text.strip() else None
            except ValueError as e:
                print("jq-stub: 输入不是合法 JSON：%s" % e, file=sys.stderr)
                return 3

        results = eval_filter(expr, data, args)
        for v in results:
            print(format_value(v, raw))
        # ★ 第 7 轮扩展：jq -e 的退出码语义
        #   真 jq：-e 时，若最后��个输出是 false/null → 退出码 1；一个输出都没有 → 4。
        #   不实现的话，`.endpoints` 这类「不存在就是 null」的判空会永远成功。
        if exit_on_error:
            if not results:
                return 4
            last = results[-1]
            if last is None or last is False:
                return 1
        return 0
    except Unsupported as u:
        die(u.expr)
    except Exception as e:  # noqa: BLE001 —— 桩的行为要可预期
        print("%s：%s" % (UNSUPPORTED, e), file=sys.stderr)
        return 3


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
