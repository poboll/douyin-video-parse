#!/usr/bin/env python3
"""sweep3.py — 递归爬 iPad 容器, 找 16:40 后修改且含 douyinvod/itemID/api-play 的文件"""
import urllib.request, re, sys, os, time

WEBDAV = os.environ.get("WEBDAV", "http://192.168.1.70:11111")
CONTAINER = os.environ.get("CONTAINER", "E694D148-F119-4239-A804-958C567C68FB")
BASE = f"{WEBDAV}/var/mobile/Containers/Data/Application/{CONTAINER}"
PREFIX = f"/var/mobile/Containers/Data/Application/{CONTAINER}"
OUT = "/tmp/sweep3_hits"
os.makedirs(OUT, exist_ok=True)
CUT = "Wed, 21 Oct 2026 08:40"  # GMT

def propfind(url, depth=1):
    req = urllib.request.Request(url, method="PROPFIND")
    req.add_header("Depth", str(depth))
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.read().decode("utf-8", "replace")
    except Exception as e:
        return ""

def parse_entries(xml):
    """-> list of (href, is_dir, size, lastmod)"""
    out = []
    for m in re.finditer(r"<D:response>(.*?)</D:response>", xml, re.S):
        blk = m.group(1)
        hm = re.search(r"<D:href>([^<]+)</D:href>", blk)
        if not hm:
            continue
        href = hm.group(1)
        is_dir = "<D:collection/>" in blk
        sm = re.search(r"<D:getcontentlength>(\d+)</D:getcontentlength>", blk)
        lm = re.search(r"<D:getlastmodified>([^<]+)</D:getlastmodified>", blk)
        out.append((href, is_dir, int(sm.group(1)) if sm else 0, lm.group(1) if lm else ""))
    return out

visited = set()
hits = []
scanned = [0]

def crawl(path, depth=0):
    """path 为相对容器根的路径, 如 /Documents"""
    if depth > 5 or path in visited:
        return
    visited.add(path)
    full = PREFIX + path
    xml = propfind(BASE + path + "/")
    for href, is_dir, size, lm in parse_entries(xml):
        href = href.split("?")[0].rstrip("/")
        if not href.startswith(PREFIX):
            continue
        rel = href[len(PREFIX):]          # 相对路径, 不以 / 结尾
        if not rel or rel == path.rstrip("/"):
            continue
        if is_dir:
            crawl(rel, depth + 1)
            continue
        if lm <= CUT:
            continue
        if size > 20_000_000:
            continue
        scanned[0] += 1
        try:
            with urllib.request.urlopen(BASE + rel, timeout=20) as r:
                data = r.read()
        except Exception:
            continue
        t = data.decode("utf-8", "replace")
        if "douyinvod" in t or "7642311481656184074" in t or "api-play" in t or "amemv" in t:
            hits.append((rel, size, lm))
            fn = os.path.join(OUT, re.sub(r"[^\w.]", "_", rel)[-80:])
            with open(fn, "wb") as f:
                f.write(data)
            print("命中:", rel, size, "B", lm, flush=True)

t0 = time.time()
for start in ["/Documents", "/Library/Caches", "/tmp", "/Library/Preferences"]:
    print("== 爬取", start, flush=True)
    crawl(start)
print(f"== 完成: 扫描 {scanned[0]} 个文件, 命中 {len(hits)} 个, 耗时 {time.time()-t0:.0f}s")
for rel, size, lm in hits:
    print("  ", rel, size, lm)
