#!/usr/bin/env python3
# 离线抽样（R8 + 相邻语义）：两部分
#   A) 用真实 menu.d 样本，按**第 6b 步修复后**的语义核对一致性面，并列出剩余已知偏差
#   B) 合成探针菜单，起 molly-host 实测每条差异的 HTTP 结果，与上游语义逐条对照
# 验收：B 段必须输出 `不一致条目: 0 / 11`（A 段只作核对与残留清单，不是断言）
# 用法：python3 .ai-memory/r8_probe.py
import json, os, re, subprocess, sys, time, urllib.request, shutil, collections
import importlib.util

REPO = "/opt/repos/molly"
SAMPLE = "/tmp/r8/menu.d"
PROBE = "/tmp/r8/probe.d"
PORT = 18098

# ---- 复用 r8_sample.py 的 schema/segments ----
spec = importlib.util.spec_from_file_location("r8", os.path.join(REPO, ".ai-memory/r8_sample.py"))
r8 = importlib.util.module_from_spec(spec); spec.loader.exec_module(r8)

def part_a():
    """A) 真实样本核对。

    第 6b 步之后 molly 的键处理与上游一致（逐键忽略），所以「schema 不符」不再是偏差，
    只作为覆盖面信息列出；真正的剩余偏差只剩解析层：molly 用 core:encoding/json 严格解析，
    `luci-app-sms-tool-js.json` 的对象尾逗号让它整文件丢（上游 ucode 是否容忍待第 7 步实测）。
    """
    files = sorted(f for f in os.listdir(SAMPLE) if f.endswith(".json"))
    typed_keys = set()            # 类型不符的键（上游只忽略该键 → molly 同）
    parse_fail_paths = set()      # molly 解析不了、上游可能解析得了的路径
    fs_specs, fs_object, fs_absent = [], [], []
    uci_specs, uci_true, uci_object, uci_array = [], [], [], []

    for fn in files:
        raw = open(os.path.join(SAMPLE, fn)).read()
        try:
            data = json.loads(raw)
        except Exception:
            # 非严格 JSON：按「宽松解析后能拿到哪些路径」估算影响面
            try:
                parse_fail_paths |= set(json.loads(re.sub(r",(\s*[}\]])", r"\1", raw)))
            except Exception:
                pass
            continue
        if not isinstance(data, dict):
            continue
        for path, s in data.items():
            if not isinstance(s, dict):
                continue
            for k, v in s.items():
                # css 是 molly 自己的扩展键，两边都不影响结果，跳过
                if k in r8.SCHEMA and k != "css" and r8.jtype(v) != r8.SCHEMA[k]:
                    typed_keys.add(path)
            dep = s.get("depends")
            if not isinstance(dep, dict):
                continue
            v = dep.get("fs")
            if isinstance(v, (dict, list)):
                fs_specs.append(path)
                if isinstance(v, dict):
                    fs_object.append(path)
                    if "absent" in v.values():
                        fs_absent.append(path)
                else:
                    for a in v:
                        if isinstance(a, dict) and "absent" in a.values():
                            fs_absent.append(path)
            v = dep.get("uci")
            if isinstance(v, (dict, list)):
                uci_specs.append(path)
                if isinstance(v, list):
                    uci_array.append(path)
                else:
                    for vals in v.values():
                        if vals is True:
                            uci_true.append(path)
                        elif isinstance(vals, dict):
                            uci_object.append(path)

    print("A) 真实样本 %d 文件 / 413 路径（按第 6b 步修复后的语义核对）：" % len(files))
    print("   类型不符的键（上游只忽略该键，molly 同）：%d 条路径 %s"
          % (len(typed_keys), sorted(typed_keys)[:6]))
    print("   depends.fs 用例：%d（object 形式 %d、含 absent %d）" % (len(fs_specs), len(fs_object), len(fs_absent)))
    print("   depends.uci 用例：%d（true %d、object %d、array %d）"
          % (len(uci_specs), len(uci_true), len(uci_object), len(uci_array)))
    print("   非严格 JSON 整文件丢（待第 7 步用设备 ucode 验）：%d 条路径 %s"
          % (len(parse_fail_paths), sorted(parse_fail_paths)))
    print("   剩余已知偏差：%d / 413" % len(parse_fail_paths))
    return parse_fail_paths

PROBE_FILES = {
    "10-schema.json": {
        "ordstr": {"title": "OrdStr", "order": "10", "action": {"type": "view", "path": "ordstr"}},
        "extrak": {"title": "ExtraKey", "action": {"type": "view", "path": "extrak"}, "title_hide": "x"},
    },
    "20-fs.json": {
        "fsabsent": {"title": "FsAbsent", "action": {"type": "view", "path": "fsabsent"},
                     "depends": {"fs": {"/etc/molly-r8-nonexistent": "absent"}}},
        "fsand": {"title": "FsAnd", "action": {"type": "view", "path": "fsand"},
                  "depends": {"fs": {"/etc/hosts": "file", "/etc/molly-r8-nonexistent": "file"}}},
        "fsarray": {"title": "FsArray", "action": {"type": "view", "path": "fsarray"},
                    "depends": {"fs": [{"/etc/molly-r8-nonexistent": "absent"}, {"/etc/hosts": "file"}]}},
        "fskind": {"title": "FsKind", "action": {"type": "view", "path": "fskind"},
                   "depends": {"fs": {"/etc/hosts": "directory"}}},
    },
    "30-uci.json": {
        "uciand": {"title": "UciAnd", "action": {"type": "view", "path": "uciand"},
                   "depends": {"uci": {"network": True, "molly-r8-nope": True}}},
        "ucihit": {"title": "UciHit", "action": {"type": "view", "path": "ucihit"},
                   "depends": {"uci": {"network": True}}},
    },
    "40-wild-base.json": {
        "wv": {"title": "Wbase", "action": {"type": "view", "path": "wild-base"}},
    },
    "50-wild-card.json": {
        "wv/*": {"title": "Wcard", "action": {"type": "view", "path": "wild-card"}},
    },
    "60-implicit.json": {
        "imp/a/b": {"title": "ImplicitMid", "action": {"type": "view", "path": "imp/a/b"}},
    },
}

# url -> (上游语义下的期望状态, 期望 view, 说明)；view 为 None 表示不比对
EXPECT = {
    "/cgi-bin/luci/ordstr": (200, "ordstr", "order 为 string：上游只忽略该键"),
    "/cgi-bin/luci/extrak": (200, "extrak", "title_hide 不在 schema：上游只忽略该键"),
    "/cgi-bin/luci/fsabsent": (200, "fsabsent", "absent 且确实不存在 → 满足"),
    "/cgi-bin/luci/fsand": (404, None, "两个 fs 要求须同时成立，第二个不存在"),
    "/cgi-bin/luci/fsarray": (200, "fsarray", "array = 任一备选成立"),
    "/cgi-bin/luci/fskind": (404, None, "/etc/hosts 是 file，不是 directory"),
    "/cgi-bin/luci/uciand": (404, None, "多 config 须同时成立"),
    "/cgi-bin/luci/ucihit": (200, "ucihit", "network 有 section"),
    "/cgi-bin/luci/wv": (200, "wild-base", "无剩余段 → 用 node.action"),
    "/cgi-bin/luci/wv/extra": (200, "wild-card", "有剩余段 → 用 wildcardaction"),
    "/cgi-bin/luci/imp/a/b": (200, "imp/a/b", "隐式中间层 satisfied=true（与上游一致）"),
}

def http_get(url):
    try:
        with urllib.request.urlopen(url, timeout=5) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")

def view_of(body):
    for line in body.splitlines():
        line = line.strip()
        if line.startswith("<dt>view</dt>"):
            i = line.find("<dd>")
            return line[i+4:line.find("</dd>")] if i >= 0 else "?"
    return "?"

def part_b():
    shutil.rmtree(PROBE, ignore_errors=True); os.makedirs(PROBE)
    for fn, data in PROBE_FILES.items():
        json.dump(data, open(os.path.join(PROBE, fn), "w"), ensure_ascii=False, indent=1)
    srv = subprocess.Popen([os.path.join(REPO, "build/molly-host"),
                            "--listen", "127.0.0.1:%d" % PORT,
                            "--docroot", os.path.join(REPO, "tests/fixtures/www"),
                            "--menu-dir", PROBE],
                           stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
    try:
        for _ in range(50):
            try:
                urllib.request.urlopen("http://127.0.0.1:%d/" % PORT, timeout=1); break
            except Exception:
                time.sleep(0.1)
        else:
            print("B) molly-host 未能启动"); return
        print()
        print("B) 合成探针实测（molly 实测 vs 上游 dispatcher.uc 语义）：")
        diff = 0
        for url, (exp, expv, why) in EXPECT.items():
            code, body = http_get("http://127.0.0.1:%d%s" % (PORT, url))
            vw = view_of(body) if code == 200 else "-"
            why2 = why if (expv is None or code != 200 or vw == expv) else "%s；view 应为 %s" % (why, expv)
            ok = "一致" if (code == exp and (expv is None or vw == expv)) else "**不一致**"
            if ok != "一致": diff += 1
            print("   %-28s 上游=%d  molly=%d (view=%-10s) %s  %s" % (url, exp, code, vw, ok, why2))
        print("   不一致条目: %d / %d" % (diff, len(EXPECT)))
    finally:
        srv.terminate(); srv.wait(timeout=5)

if __name__ == "__main__":
    part_a()
    part_b()