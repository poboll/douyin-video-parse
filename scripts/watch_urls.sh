#!/bin/zsh
# watch_urls.sh — 抖音精选新鲜播放直链盯梢器
# 原理: App 解析视频直链后会写进 mmkv.default / loginData.dat,
#       带 l=2026xxxx 新鲜时间戳 + x-expires 有效期。
#       本脚本轮询这两个文件, 一旦发现 douyinvod.com 的新鲜直链:
#       1) 打印完整 URL  2) 立即 curl 全速下载(带 Referer)到 ~/Downloads/offline_final/
# 用法: 先在 iPad 抖音精选里打开/播放目标视频(画质选最高), 再运行:
#       ./watch_urls.sh [轮询间隔秒, 默认15]
set -u
WEBDAV=${WEBDAV:-http://192.168.1.70:11111}
CONTAINER=${CONTAINER:-E694D148-F119-4239-A804-958C567C68FB}
B=$WEBDAV/var/mobile/Containers/Data/Application/$CONTAINER
DEST=~/Downloads/offline_final
mkdir -p "$DEST"
INTERVAL=${1:-15}
seen=""

log() { print -r -- "[$(date '+%H:%M:%S')] $1"; }
log "开始盯梢新鲜直链 (每 ${INTERVAL}s 拉取 mmkv), 目标目录: $DEST"
log ">>> 现在去 iPad 上打开/播放《女主》第二集, 画质选最高 <<<"

extract_fresh() {  # 文件路径 -> 输出新鲜 URL(每行一条)
  ${PYTHON:-python3} - "$1" <<'PYEOF'
import re, sys
text = open(sys.argv[1], "rb").read().decode("utf-8","replace")
out = []
# 注意: mmkv 里是 JSON 转义形式 https:\/\/..., 允许反斜杠进入再统一还原
for m in re.finditer(r'https:[^"\s\x00,]+', text):
    u = m.group(0).replace("\\/","/").rstrip('\\"')
    if "douyinvod.com" not in u: continue
    exp = re.search(r'x-expires=(\d+)', u)
    lm  = re.search(r'l=(20\d{12})', u)
    fresh = (lm and lm.group(1).startswith("2026")) or \
            (exp and int(exp.group(1)) > 1792000000)  # 2026-10 之后
    if fresh and u not in out: out.append(u)
print("\n".join(out))
PYEOF
}

while true; do
  for SRC in "Documents/mmkv/mmkv.default" "Library/loginData.dat"; do
    curl -s -m 20 -o /tmp/watch_now "$B/$SRC" 2>/dev/null
    for u in $(extract_fresh /tmp/watch_now); do
      case "$seen" in *"$u"*) continue;; esac
      seen="$seen$u\n"
      log "新鲜直链: ${u:0:120}..."
      fn="$DEST/$(echo "$u" | md5 -q | cut -c1-8).mp4"
      # 先用 Range 探活
      code=$(curl -s -o /dev/null -w "%{http_code}" -m 15 -r 0-1023 \
             -e "https://www.douyin.com/" -A "Mozilla/5.0" "$u")
      if [ "$code" = "206" ] || [ "$code" = "200" ]; then
        log "链接有效(HTTP $code), 全速下载 -> $fn"
        curl -s -m 7200 -e "https://www.douyin.com/" -A "Mozilla/5.0" \
             -o "$fn" "$u" && log "下载完成: $(du -h "$fn" | cut -f1)"
      else
        log "链接已失效/拒绝 (HTTP $code)"
      fi
    done
  done
  sleep "$INTERVAL"
done
