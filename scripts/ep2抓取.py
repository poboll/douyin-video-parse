#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ep2 抓取一键处理（Mac 端）

作用：拉 iPad 上最新一轮的 dump（音频 + 视频会话）→ 合并成能听的音频
     → 判定这段音频在正片里的起点（重点：是不是从 00:00 开始的真片头）
     → 顺手检查新视频会话能不能独立解码

环境变量：
  WEBDAV   iPad WebDAV 根地址，默认 http://192.168.1.70:11111
  CONTAINER App 容器 UUID（抖音精选 Data 容器）

用法：
  python3 ep2抓取.py [分钟数]

  分钟数 = 只处理最近 N 分钟内修改过的文件，默认 45
"""
import os, sys, re, subprocess, urllib.request, email.utils, datetime
import numpy as np

WEBDAV = os.environ.get("WEBDAV", "http://192.168.1.70:11111")
CONTAINER = os.environ.get(
    "CONTAINER", "E694D148-F119-4239-A804-958C567C68FB")  # 抖音精选 Data 容器
BASE = f"{WEBDAV}/private/var/mobile/Containers/Data/Application/{CONTAINER}/Documents/ep2dump"
ROOT = WEBDAV
OUT = os.environ.get("OUT", "/tmp/ep2/cap")
REF = os.environ.get("REF", "/tmp/ep2")
DL = os.path.expanduser("~/Downloads")
SR, SRD = 44100, 11025
MIN = float(sys.argv[1]) if len(sys.argv) > 1 else 45.0
CUT = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=MIN)
os.makedirs(OUT, exist_ok=True)


def P(*a):
    print(*a, flush=True)


def http(url, method="GET", data=None, timeout=25):
    req = urllib.request.Request(url, data=data, method=method)
    if method == "PROPFIND":
        req.add_header("Depth", "1")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def ls(sub):
    body = (b'<?xml version="1.0"?><D:propfind xmlns:D="DAV:"><D:prop>'
            b'<D:getcontentlength/><D:getlastmodified/></D:prop></D:propfind>')
    xml = http(BASE + "/" + sub + "/", "PROPFIND", body).decode("utf-8", "replace")
    res = []
    for blk in re.findall(r"<D:response>(.*?)</D:response>", xml, re.S):
        h = re.search(r"<D:href>(.*?)</D:href>", blk)
        if not h or h.group(1).endswith("/"):
            continue
        sz = re.search(r"<D:getcontentlength>(\d+)", blk)
        mt = re.search(r"<D:getlastmodified>(.*?)<", blk)
        ts = None
        if mt:
            try:
                ts = email.utils.parsedate_to_datetime(mt.group(1))
            except Exception:
                ts = None
        res.append(dict(href=h.group(1), name=h.group(1).rsplit("/", 1)[-1],
                        size=int(sz.group(1)) if sz else 0, ts=ts))
    return res


def dl(it):
    dst = os.path.join(OUT, it["name"])
    with open(dst, "wb") as f:
        f.write(http(ROOT + it["href"], timeout=300))
    return dst


# ---------------- 音频 ----------------
def wav_off(path):
    with open(path, "rb") as f:
        h = f.read(4096)
    p = 12
    while p + 8 <= len(h):
        cid, sz = h[p:p + 4], int.from_bytes(h[p + 4:p + 8], "little")
        if cid == b"data":
            return p + 8, sz
        p += 8 + sz + (sz & 1)
    raise RuntimeError("no data chunk in " + path)


def write_wav_s16(path, x):
    y = np.clip(x, -1.0, 1.0) * 32767.0
    y = y.astype("<i2")
    with open(path, "wb") as f:
        f.write(b"RIFF"); f.write((36 + len(y) * 2).to_bytes(4, "little")); f.write(b"WAVE")
        f.write(b"fmt "); f.write((16).to_bytes(4, "little"))
        f.write((1).to_bytes(2, "little")); f.write((2).to_bytes(2, "little"))
        f.write(SR.to_bytes(4, "little")); f.write((SR * 4).to_bytes(4, "little"))
        f.write((4).to_bytes(2, "little")); f.write((16).to_bytes(2, "little"))
        f.write(b"data"); f.write((len(y) * 2).to_bytes(4, "little"))
        f.write(y.tobytes())


def ds(x):
    n = (len(x) // 4) * 4
    return x[:n].reshape(-1, 4).mean(axis=1)


def ncc(hay, needle):
    """在 hay 里找 needle，返回 (起点样本, ncc)。"""
    n, m = len(hay), len(needle)
    if m > n or m < 8:
        return -1, 0.0
    a = needle - needle.mean()
    b = hay - hay.mean()
    N = 1 << int(np.ceil(np.log2(n + m)))
    cc = np.fft.irfft(np.fft.rfft(b, N) * np.fft.rfft(a[::-1], N), N)[m - 1:n]
    e = np.sqrt(np.convolve(b * b, np.ones(m), "valid"))
    v = cc / (e * np.linalg.norm(a) + 1e-12)
    k = int(np.argmax(v))
    return k, float(v[k])


def est_start(audio, ref, ref_start, u0, w=2.0):
    """audio/ref 均为 11025Hz 单声道。返回 (start_content, ncc)"""
    i0, ww = int(u0 * SRD), int(w * SRD)
    if i0 + ww > len(audio):
        return None, 0.0
    k, v = ncc(ref, audio[i0:i0 + ww])
    if k < 0:
        return None, 0.0
    return ref_start + k / SRD - u0, v


# ---------------- 视频 NAL ----------------
def nal_info(path):
    data = open(path, "rb").read()
    if data[:4] == b"\x00\x00\x00\x01" or data[:3] == b"\x00\x00\x01":
        fmt, types = "AnnexB", []
        idx = 0
        while True:
            j = data.find(b"\x00\x00\x01", idx)
            if j < 0:
                break
            s = j + 3
            if s < len(data):
                types.append((data[s] >> 1) & 0x3F)
            idx = s
    else:
        fmt, types, p = "HVCC", [], 0
        while p + 4 <= len(data):
            ln = int.from_bytes(data[p:p + 4], "big")
            if ln <= 0 or p + 4 + ln > len(data):
                break
            types.append((data[p + 4] >> 1) & 0x3F)
            p += 4 + ln
    vcl = [t for t in types if t <= 21]
    ps = [t for t in types if t in (32, 33, 34)]
    first_vcl = vcl[0] if vcl else None
    return dict(fmt=fmt, nal=len(types), frames=len(vcl), ps=len(ps),
                first_vcl=first_vcl,
                starts_idr=(first_vcl in (19, 20)))


def decodable(path):
    try:
        r = subprocess.run(["ffmpeg", "-hide_banner", "-i", path, "-f", "null", "-"],
                           capture_output=True, text=True, timeout=300)
        m = re.findall(r"frame=\s*(\d+)", r.stderr)
        return int(m[-1]) if m else 0
    except Exception:
        return -1


# ---------------- main ----------------
def main():
    P("== 1. iPad 可达性 ==")
    try:
        http(BASE + "/", "PROPFIND",
             b'<?xml version="1.0"?><D:propfind xmlns:D="DAV:"><D:prop><D:resourcetype/></D:prop></D:propfind>',
             timeout=8)
        P("  ✓ 可达")
    except Exception as e:
        P("  ✗ iPad 不可达:", e)
        return 1

    P("\n== 2. dump 目录 ==")
    allitems = []
    for sub in ("audio", "frames"):
        try:
            items = ls(sub)
        except Exception as e:
            P(f"  {sub}: 读取失败 {e}")
            continue
        P(f"  [{sub}]")
        for it in items:
            ts = it["ts"].astimezone().strftime("%H:%M:%S") if it["ts"] else "?"
            fresh = bool(it["ts"] and it["ts"] >= CUT)
            P(f"    {'★' if fresh else ' '} {it['name']:<28} {it['size']:>10} B  {ts}")
            if fresh:
                it["sub"] = sub
                allitems.append(it)
    if not allitems:
        P(f"\n  ✗ 最近 {MIN:.0f} 分钟内没有新文件 —— 播放没产生 dump？")
        return 2

    P(f"\n== 3. 下载 {len(allitems)} 个新文件 ==")
    got = []
    for it in allitems:
        try:
            p = dl(it)
            P(f"  ✓ {it['name']}  {os.path.getsize(p)} B")
            got.append((it, p))
        except Exception as e:
            P(f"  ✗ {it['name']}: {e}")

    # ---- 音频 ----
    pcm = [(it, p) for it, p in got if it["sub"] == "audio" and p.endswith(".pcm")]
    P("\n== 4. 音频 ==")
    if not pcm:
        P("  ✗ 没有新的 .pcm")
        return 3
    pcm.sort(key=lambda x: x[0]["size"], reverse=True)
    it, apath = pcm[0]
    raw = np.fromfile(apath, dtype="<f4")
    if len(raw) % 2:
        raw = raw[:-1]
    x = raw.reshape(-1, 2)
    dur = len(x) / SR
    P(f"  文件 {it['name']}  {len(x)} 帧  {dur:.3f}s  ({SR}Hz f32 立体声)")

    wav = os.path.join(OUT, "audio.wav")
    write_wav_s16(wav, x)
    stamp = datetime.datetime.now().strftime("%H%M")
    prev = os.path.join(DL, f"新抓音频_试听_{stamp}.m4a")
    subprocess.run(["ffmpeg", "-y", "-v", "error", "-i", wav, "-t", "25",
                    "-c:a", "aac", "-b:a", "256k", prev], check=False)
    P(f"  → {wav}")
    if os.path.exists(prev):
        P(f"  → {prev}  ({os.path.getsize(prev)} B, 前 25 秒)")

    # ---- 起点判定 ----
    P("\n== 5. 起点判定（这段音频在正片第几秒）==")
    mono = ds(x.mean(axis=1))
    refs = []
    try:
        a = np.fromfile(os.path.join(REF, "old_aucb.pcm"), dtype="<f4")
        if len(a) % 2:
            a = a[:-1]
        refs.append(("aucb", ds(a.reshape(-1, 2).mean(axis=1)), 5.831))
    except Exception:
        pass
    try:
        n = np.fromfile(os.path.join(REF, "new_avdec.pcm"), dtype="<f4")
        if len(n) % 2:
            n = n[:-1]
        refs.append(("new_avdec", ds(n.reshape(-1, 2).mean(axis=1)), 6.667))
    except Exception:
        pass
    comp = os.path.join(REF, "comp_full.wav")
    if os.path.exists(comp):
        try:
            off, _sz = wav_off(comp)
            tail_s = 4100.0
            cnt = int((4180.94 - tail_s) * SR) * 2
            c = np.fromfile(comp, dtype="<f4", count=cnt, offset=off + int(tail_s * SR) * 8)
            refs.append(("comp_tail", ds(c.reshape(-1, 2).mean(axis=1)), 6.2954 + tail_s))
        except Exception as e:
            P("  (comp 读取失败:", e, ")")

    if not refs:
        P("  ✗ 参考文件缺失")
        return 4

    cands = []
    for u0 in (0.5, 2.0, 4.0, 6.0, 8.0, 10.0, 12.0):
        if u0 + 2.0 > dur:
            continue
        row = []
        for name, r, rs in refs:
            s, v = est_start(mono, r, rs, u0)
            row.append((v, name, s))
        row.sort(reverse=True)
        v, name, s = row[0]
        P(f"  @{u0:>4.1f}s → 最佳 {name:<9} ncc={v:.4f}  起点≈{('%.3f' % s) if s is not None else '?'}s")
        if v >= 0.80 and s is not None and -2.0 < s < 60.0:
            cands.append(s)

    P("\n== 6. 结论 ==")
    if cands:
        cands.sort()
        med = cands[len(cands) // 2]
        P(f"  起点 content ≈ {med:.3f}s   （可信窗口 {len(cands)} 个）")
        if med < 0.15:
            P("  ✅ 抓到真片头（从 0 秒起）！")
        elif med < 1.0:
            P("  ⚠ 接近片头，但还差一点")
        else:
            P(f"  ❌ 不是片头 —— 仍从 {med:.2f}s 起播（App 又续播了）")
    else:
        P("  ⚠ 无法判定（可能全是新内容 = 片头，或匹配失败）")

    # ---- 视频 ----
    P("\n== 7. 新视频会话 ==")
    vids = [(it, p) for it, p in got if it["sub"] == "frames" and p.endswith(".h265")]
    if not vids:
        P("  无")
    for it, p in vids:
        try:
            d = nal_info(p)
            dc = decodable(p)
            P(f"  {it['name']}: {d['fmt']}  VCL {d['frames']} 帧  参数集 {d['ps']} 个  "
              f"首帧类型 {d['first_vcl']}  可解码 {dc} 帧")
        except Exception as e:
            P(f"  {it['name']}: 解析失败 {e}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
