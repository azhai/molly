#!/usr/bin/env python3
# 离线抽样：用 ImmortalWrt 25.12.2 钉住的 luci 提交（d6167ea）里全部 menu.d JSON，
# 按 dispatcher.uc（同一提交）的语义统计，回答 R8 并顺带核对 schema / depends 形状。
# 用法：python3 .ai-memory/r8_sample.py [menu.d 目录]
import json, os, sys, collections

MENU_DIR = sys.argv[1] if len(sys.argv) > 1 else "/tmp/r8/menu.d"

# dispatcher.uc:349-360（注意：**没有 css**）
SCHEMA = {
    "action": "object", "auth": "object", "cors": "bool", "depends": "object",
    "order": "int", "setgroup": "string", "setuser": "string", "title": "string",
    "wildcard": "bool", "firstchild_ineligible": "bool",
}

def jtype(v):
    if v is True or v is False: return "bool"
    if isinstance(v, int): return "int"
    if isinstance(v, float): return "num"
    if isinstance(v, str): return "string"
    if isinstance(v, list): return "array"
    if isinstance(v, dict): return "object"
    if v is None: return "null"
    return "?"

def segments(path):
    """dispatcher.uc:393 match(path, /[^\/]+/g)"""
    return [s for s in path.split("/") if s != ""]

def main():
    files = sorted(f for f in os.listdir(MENU_DIR) if f.endswith(".json"))
    specs, spec_files = {}, collections.defaultdict(list)
    violations, extra_keys = [], collections.Counter()
    dep_fs, dep_uci, dep_other = [], [], collections.Counter()
    bad_json, wildcard_paths, all_paths = [], [], set()

    for fn in files:
        try:
            with open(os.path.join(MENU_DIR, fn)) as fh:
                data = json.load(fh)
        except Exception as e:
            bad_json.append((fn, str(e))); continue
        if not isinstance(data, dict):
            bad_json.append((fn, "顶层不是 object")); continue
        for path, spec in data.items():
            if not isinstance(spec, dict):
                continue
            all_paths.add(path)
            spec_files[path].append(fn)
            specs[path] = spec
            segs = segments(path)
            if any(s.startswith("*") for s in segs):
                wildcard_paths.append(path)
            for k, v in spec.items():
                if k not in SCHEMA:
                    extra_keys[k] += 1
                    violations.append((fn, path, k, jtype(v), "<不在 schema>"))
                elif jtype(v) != SCHEMA[k]:
                    violations.append((fn, path, k, jtype(v), SCHEMA[k]))
            dep = spec.get("depends")
            if isinstance(dep, dict):
                for k, v in dep.items():
                    if k == "fs": dep_fs.append((path, v))
                    elif k == "uci": dep_uci.append((path, v))
                    else: dep_other[k] += 1

    # ---- 隐式中间层（R8 的核心）----
    by_segs = {tuple(segments(p)): p for p in all_paths}
    implicit_missing = []
    for p in all_paths:
        segs = segments(p)
        for i in range(1, len(segs)):
            if segs[i-1].startswith("*") or segs[i].startswith("*"):
                break
            prefix = tuple(segs[:i])
            if prefix not in by_segs:
                implicit_missing.append(("/".join(prefix), p))

    def shape(v):
        return "array[%d]" % len(v) if isinstance(v, list) else "object"

    fs_shapes = collections.Counter(shape(v) for _, v in dep_fs)
    uci_shapes = collections.Counter(shape(v) for _, v in dep_uci)
    fs_kinds = collections.Counter()
    for _, v in dep_fs:
        for a in (v if isinstance(v, list) else [v]):
            if isinstance(a, dict):
                for k2 in a.values():
                    fs_kinds[k2 if isinstance(k2, str) else jtype(k2)] += 1
            else:
                fs_kinds["<非 object 备选:%s>" % jtype(a)] += 1
    uci_val_kinds = collections.Counter()
    for _, v in dep_uci:
        for a in (v if isinstance(v, list) else [v]):
            if isinstance(a, dict):
                for v2 in a.values():
                    uci_val_kinds["config->true" if v2 is True else "config->object"] += 1
            else:
                uci_val_kinds["<非 object 备选:%s>" % jtype(a)] += 1

    depths = collections.Counter(len(segments(p)) for p in all_paths)
    firstchild = sum(1 for s in specs.values()
                     if isinstance(s.get("action"), dict) and s["action"].get("type") == "firstchild")
    view = sum(1 for s in specs.values()
               if isinstance(s.get("action"), dict) and s["action"].get("type") == "view")

    print("文件数            : %d" % len(files))
    print("JSON 解析失败     : %s" % (bad_json or "无"))
    print("path 条目数       : %d，唯一 path: %d" % (sum(len(v) for v in spec_files.values()), len(all_paths)))
    print("action=firstchild : %d    action=view: %d" % (firstchild, view))
    print("路径深度分布      : %s" % dict(sorted(depths.items())))
    print("通配(*)路径       : %d  %s" % (len(wildcard_paths), wildcard_paths[:6]))
    print("同 path 多文件    : %d" % sum(1 for v in spec_files.values() if len(v) > 1))
    print()
    print("== R8：中间层缺显式 spec（上游 satisfied 默认 true，故不影响可解析性）==")
    print("条数: %d" % len(implicit_missing))
    for a, b in implicit_missing[:20]:
        print("   %-28s  <-- %s" % (a, b))
    print()
    print("== schema 偏差（上游：只忽略该键，不丢弃整条）==")
    print("不在 schema 的键  : %s" % (dict(extra_keys) or "无"))
    print("类型不匹配条数    : %d" % sum(1 for v in violations if v[4] != "<不在 schema>"))
    for v in [x for x in violations if x[4] == "<不在 schema>"][:15]:
        print("   %-38s %-46s 键=%s(%s)" % v[:4])
    for v in [x for x in violations if x[4] != "<不在 schema>"][:15]:
        print("   %-38s %-46s %s=%s 期望 %s" % v)
    print()
    print("== depends 形状 ==")
    print("fs  出现: %d   值形状: %s   要求类型计数: %s" % (len(dep_fs), dict(fs_shapes), dict(fs_kinds)))
    print("uci 出现: %d   值形状: %s   取值形状: %s" % (len(dep_uci), dict(uci_shapes), dict(uci_val_kinds)))
    print("其它 depends 键   : %s" % (dict(dep_other) or "无"))
    print()
    print("fs 备选示例（前 6）:")
    for p, v in dep_fs[:6]:
        print("   %-46s %s" % (p, json.dumps(v, ensure_ascii=False)))
    print("uci 备选示例（前 6）:")
    for p, v in dep_uci[:6]:
        print("   %-46s %s" % (p, json.dumps(v, ensure_ascii=False)[:150]))

if __name__ == "__main__":
    main()