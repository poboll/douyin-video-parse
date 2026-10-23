#!/bin/zsh
# watch2.sh — 盯梢器 v2
#   A) BDXPrefetchStorageDomain/mmkv.default/loginData.dat 里的新鲜 douyinvod 直链(l=2026) → curl 下载
#   B) TTPlayerCache 根目录新出现的大文件(>30MB) 或 2160p/1440p 档位命名文件 → 下载到 ~/Downloads/offline_final/gears/
# 用法: ./watch2.sh [轮询间隔秒, 默认20]
set -u
WEBDAV=${WEBDAV:-http://192.168.1.70:11111}
CONTAINER=${CONTAINER:-E694D148-F119-4239-A804-958C567C68FB}
B=$WEBDAV/var/mobile/Containers/Data/Application/$CONTAINER
TP=$B/Library/Caches/TTPlayerCache
DEST=~/Downloads/offline_final
GEARS=$DEST/gears
mkdir -p "$DEST" "$GEARS"
INTERVAL=${1:-20}
PY=${PYTHON:-python3}
declare -A seen_file   # 文件名 -> 已见
declare -A seen_url

log() { print -r -- "[$(date '+%H:%M:%S')] $1"; }
log "盯梢器v2启动 (每 ${INTERVAL}s): 新鲜直链 + 播放缓存大文件/4K档"

scan_fresh_urls() {  # $1=本地文件
  [ -s "$1" ] || return 0
  $PY - "$1" <<'PYEOF'
import re, sys
text = open(sys.argv[1], "rb").read().decode("utf-8", "replace")
out = []
for m in re.finditer(r'https:[^"\s\x00,]+', text):
    u = m.group(0).replace("\\/", "/").replace("\\u0026", "&").rstrip('\\"')
    if "douyinvod.com" not in u:
        continue
    lm = re.search(r'l=(20\d{12,})', u)
    exp = re.search(r'x-expires=(\d+)', u)
    if (lm and lm.group(1).startswith("2026")) or (exp and int(exp.group(1)) > 1792000000):
        if u not in out:
            out.append(u)
print("\n".join(out))
PYEOF
}

while true; do
  # ---- A) 新鲜直链 ----
  for REL in Documents/mmkv/BDXPrefetchStorageDomain Documents/mmkv/mmkv.default Library/loginData.dat; do
    curl -s -m 30 -o /tmp/w2_now "$B/$REL" 2>/dev/null
    for u in $(scan_fresh_urls /tmp/w2_now); do
      [ -n "${seen_url[$u]:-}" ] && continue
      seen_url[$u]=1
      log "新直链($REL): ${u:0:100}..."
      fn="$DEST/url_$(echo -n "$u" | md5 | cut -c1-10).mp4"
      # api-play 跳转链接: 记录完整 URL(含 biz_sign) 并用 -L 跟随
      EXTRA=""
      case "$u" in
        *api-play.amemv.com*)
          echo "$u" >> "$DEST/apiplay_urls.txt"
          log "api-play 跳转链(含biz_sign), 已记录到 apiplay_urls.txt"
          EXTRA="-L"
          ;;
      esac
      code=$(curl -s $EXTRA -o /dev/null -w "%{http_code}" -m 25 -r 0-1023 -e "https://www.douyin.com/" -A "Mozilla/5.0" "$u")
      if [ "$code" = "206" ] || [ "$code" = "200" ]; then
        log "链接有效(HTTP $code), 下载 -> $fn"
        curl -s $EXTRA -m 7200 -e "https://www.douyin.com/" -A "Mozilla/5.0" -o "$fn" "$u" \
          && log "下载完成: $(du -h "$fn" | cut -f1)" \
          || log "下载失败 $fn"
        if [ -s "$fn" ]; then
          info=$(ffprobe -v error -show_entries stream=codec_type,codec_name,width,height -show_entries format=duration -of csv=p=0 "$fn" 2>/dev/null | tr '\n' ' ')
          log "文件信息: $info"
        fi
      else
        log "链接失效 (HTTP $code), 30秒后重试一次"
        sleep 30
        code=$(curl -s $EXTRA -o /dev/null -w "%{http_code}" -m 25 -r 0-1023 -e "https://www.douyin.com/" -A "Mozilla/5.0" "$u")
        if [ "$code" = "206" ] || [ "$code" = "200" ]; then
          log "重试有效(HTTP $code), 下载 -> $fn"
          curl -s $EXTRA -m 7200 -e "https://www.douyin.com/" -A "Mozilla/5.0" -o "$fn" "$u" \
            && log "下载完成: $(du -h "$fn" | cut -f1)"
          if [ -s "$fn" ]; then
            info=$(ffprobe -v error -show_entries stream=codec_type,codec_name,width,height -show_entries format=duration -of csv=p=0 "$fn" 2>/dev/null | tr '\n' ' ')
            log "文件信息: $info"
          fi
        else
          log "重试仍失效 (HTTP $code)"
        fi
      fi
    done
  done

  # ---- B) 播放缓存新大文件 / 高规格档位 ----
  listing=$(curl -s -m 15 -X PROPFIND -H "Depth: 1" "$TP/" \
            | grep -oE '<D:href>[^<]+\.mdl</D:href>' | sed 's/<D:href>//;s|</D:href>||')
  for h in $listing; do
    name=$(basename "$h")
    # 已知的不重复处理(除非是持续增长的: 见下方 size 比对)
    info=$(curl -s -m 10 -X PROPFIND -H "Depth: 0" "$TP/$name" 2>/dev/null)
    sz=$(echo "$info" | grep -oE '<D:getcontentlength>[0-9]+' | grep -oE '[0-9]+')
    [ -n "$sz" ] || continue
    local_path="$GEARS/$name"
    prev="${seen_file[$name]:-0}"
    big=0; gear=0
    [ "$sz" -gt 31457280 ] && big=1
    case "$name" in *2160p*|*1440p*|*bytevc1_2160p*) gear=1;; esac
    if { [ "$big" = "1" ] || [ "$gear" = "1" ]; } && \
       { [ ! -f "$local_path" ] || [ "$((sz - prev))" -gt 10485760 ]; }; then
      log "缓存文件 $name ($((sz/1048576))MB, 已见${prev}) -> 下载"
      curl -s -m 7200 -o "$local_path" "$TP/$name" \
        && log "下载完成 $name ($(du -h "$local_path" | cut -f1))" \
        || log "下载失败 $name"
      seen_file[$name]=$sz
    else
      seen_file[$name]=$sz
    fi
  done

  sleep "$INTERVAL"
done
