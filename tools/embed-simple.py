#!/usr/bin/env python3
# 从 webassets/simple/{index.html,mithril.js} 生成 src/assets/embedded.odin。
# Odin dev-2026-10 无 #embed 指令，故用字节数组字面量内嵌（保持「只丢一个二进制也能跑」）。
# 生成物确定性、随源一起提交；源变了重跑本脚本即可。
import os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "webassets", "simple")
OUT = os.path.join(ROOT, "src", "assets", "embedded.odin")

def emit_array(name, data):
    n = len(data)
    lines = []
    lines.append("%s : [%d]u8 = {" % (name, n))
    for i in range(0, n, 24):
        chunk = data[i:i+24]
        lines.append("    " + ", ".join("0x%02x" % b for b in chunk) + ",")
    lines.append("}")
    return "\n".join(lines)

def main():
    with open(os.path.join(SRC, "index.html"), "rb") as f:
        html = f.read()
    with open(os.path.join(SRC, "mithril.js"), "rb") as f:
        mith = f.read()

    header = (
        "// 自动生成，请勿手改 —— 由 tools/embed-simple.py 从 webassets/simple/{index.html,mithril.js} 生成。\n"
        "// 内嵌简洁版单文件页与 vendored Mithril（Odin 无 #embed，用字节数组承载；页面里用 __CFG__ / __MITHRIL__ 占位符注入）。\n"
    )
    body = []
    body.append("package assets\n\n")
    body.append(header + "\n")
    body.append(emit_array("_html_data", html) + "\n\n")
    body.append(emit_array("_mithril_data", mith) + "\n\n")
    body.append("// HTML —— 内嵌的简洁版页面原文（含 __CFG__ / __MITHRIL__ 占位符）；[]u8 到 string 是零拷贝重解释。\n")
    body.append("HTML :: proc() -> string { return string(_html_data[:]) }\n\n")
    body.append("// MITHRIL —— 内嵌的 mithril.js 正文。\n")
    body.append("MITHRIL :: proc() -> string { return string(_mithril_data[:]) }\n")

    with open(OUT, "w") as f:
        f.write("\n".join(body))
    sys.stderr.write("生成 %s：html=%d B, mithril=%d B\n" % (OUT, len(html), len(mith)))

if __name__ == "__main__":
    main()
