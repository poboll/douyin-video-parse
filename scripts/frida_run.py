#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
frida_run.py — Mac 端驱动: USB 连 iPad, 给抖音精选(AwemeJX) 注入 ep2dump.js
用法:
  python3 frida_run.py                  # USB 直连, recon 模式
  python3 frida_run.py dump             # USB 直连, dump 模式
  python3 frida_run.py remote 192.168.1.70        # WiFi 远程(巨魔注入 frida-gadget 后), recon
  python3 frida_run.py remote 192.168.1.70 dump   # WiFi 远程, dump
  python3 frida_run.py spawn            # 冷启动 App(USB)
"""
import os
import sys
import time

import frida

OUT_DIR = os.path.expanduser("~/Downloads/ep2dump_out")
AGENT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ep2dump.js")
APP = "AwemeJX"          # 进程名(抖音精选)

os.makedirs(OUT_DIR, exist_ok=True)

# ---------- 解析参数 ----------
remote_ip = None
spawn = False
mode = "recon"
args = sys.argv[1:]
if args and args[0] == "remote":
    remote_ip = args[1] if len(args) > 1 else os.environ.get("PAD_IP", "192.168.1.70")
    if len(args) > 2 and args[2] in ("recon", "dump"):
        mode = args[2]
elif args and args[0] == "spawn":
    spawn = True
    if len(args) > 1 and args[1] in ("recon", "dump"):
        mode = args[1]
elif args and args[0] in ("recon", "dump"):
    mode = args[0]

if remote_ip:
    dev = frida.get_device_manager().add_remote_device(f"{remote_ip}:27042")
    print(f"[*] remote device: {remote_ip}:27042")
else:
    dev = frida.get_usb_device(timeout=10)
    print(f"[*] device: {dev.name}")

if spawn and not remote_ip:
    pid = dev.spawn([APP])
    print(f"[*] spawned {APP} pid={pid}")
    session = dev.attach(pid)
else:
    procs = [p for p in dev.enumerate_processes() if p.name == APP]
    if not procs:
        print(f"[!] 没找到 {APP} 进程, 请先在 iPad 上打开抖音精选; 或加 spawn 参数冷启动")
        sys.exit(1)
    session = dev.attach(procs[0].pid)
    print(f"[*] attached pid={procs[0].pid}")

with open(AGENT, "r", encoding="utf-8") as f:
    src = f.read()
script = session.create_script(src)

counter = 0
last_summary = time.time()


def on_message(msg, data):
    global counter, last_summary
    if msg.get("type") == "error":
        print("[agent-error]", msg.get("stack", msg))
        return
    p = msg.get("payload", {})
    kind = p.get("kind")
    if kind == "meta":
        args = " ".join(f"a{a['i']}:{a['cls']}/{a['len']}B" for a in p.get("args", []))
        print(f"  #{p['n']:05d} {p['cls']} {p['sel']}  {args}")
        for a in p.get("args", []):
            if a.get("head"):
                print(f"        a{a['i']} head: {a['head'][:96]}")
    elif kind == "ret":
        print(f"  #{p['n']:05d} ret {p['cls_r']}/{p['len']}B  head: {p.get('head','')[:96]}")
    elif kind == "data":
        counter += 1
        fn = os.path.join(OUT_DIR, f"{counter:06d}_{p.get('tag','data')}.bin")
        with open(fn, "wb") as f:
            f.write(data)
        print(f"  [save] {fn} ({len(data)}B)")
    elif kind == "ready":
        print(f"[*] agent ready, hooks: {len(p.get('hooks', []))}")
        for h in p.get("hooks", []):
            print("    +", h)
        script.exports.setmode(mode)
        if spawn:
            dev.resume(session._impl.pid if hasattr(session, "_impl") else 0)
    elif kind == "send":
        print("[log]", p)


script.on("message", on_message)
script.load()
if mode == "dump":
    script.exports.setmode("dump")
print(f"[*] mode={mode}  现在去 iPad 上播放《女主》第二集(选4K), Ctrl-C 停止")
try:
    sys.stdin.read()
except KeyboardInterrupt:
    pass
finally:
    try:
        script.exports.flush()
    except Exception:
        pass
    session.detach()
    print("[*] detached")
