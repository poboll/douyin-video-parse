#!/bin/zsh
# probe_cache.sh — 抖音精选离线缓存批量检测工具
# 用法: ./probe_cache.sh <离线缓存目录>
#       (默认 ~/Downloads/offlineCaches，即从 iPad 的
#        Library/Caches/TTPlayerCache/offlineCaches 整个拷过来的文件夹)
# 做的事:
#   1) 递归遍历所有文件, 先按类型分流(与大小无关):
#      - SQLite 库 -> 自动导出全部表结构+样例数据(找文件名->视频URL映射)
#      - m3u8/文本 -> 预览内容
#      - >1MB 其它 -> ffprobe 识别, 能解出视频流的自动复制成 .mp4 到 <目录>/probed/
#   2) 解不出的标注魔术字节, 供人工判断(DASH分片/加密/非标准容器)
set -u
SRC="${1:-$HOME/Downloads/offlineCaches}"
[ -d "$SRC" ] || { echo "目录不存在: $SRC"; exit 1; }
OUT="$SRC/probed"
mkdir -p "$OUT"
LOG="$SRC/probe_report.txt"
: > "$LOG"
log() { print -r -- "$1" | tee -a "$LOG"; }

log "===== 缓存检测报告 $(date '+%F %T') ====="
log "目录: $SRC"
log ""

idx=0; ok=0; unknown=0; db=0; text=0
while IFS= read -r f; do
  case "$f" in */probed/*) continue;; esac
  base=$(basename "$f")
  sz=$(stat -f%z "$f")
  ftype=$(file -b "$f" | cut -c1-70)
  idx=$((idx+1))
  log "[$idx] $base  ($(( sz / 1024 ))KB)"
  log "     file: $ftype"
  if echo "$ftype" | grep -qi "sqlite"; then
    db=$((db+1))
    log "     SQLite 数据库, 导出结构+样例:"
    for t in $(sqlite3 "$f" ".tables" 2>/dev/null); do
      log "     [表] $t"
      sqlite3 "$f" ".schema $t" 2>/dev/null | head -30 | sed 's/^/       /' | tee -a "$LOG"
      sqlite3 -header "$f" "SELECT * FROM \"$t\" LIMIT 3;" 2>/dev/null | head -8 | sed 's/^/       /' | tee -a "$LOG"
    done
  elif echo "$ftype" | grep -qiE "ascii text|utf-8|json"; then
    text=$((text+1))
    if head -c 200 "$f" | grep -q "m3u8\|EXTINF"; then log "     HLS 播放列表 (m3u8):"
    else log "     文本内容(前 300 字符):"; fi
    head -c 300 "$f" | sed 's/^/       /' | tee -a "$LOG"
  elif [ "$sz" -gt 1048576 ]; then
    info=$(ffprobe -v error -show_entries format=format_name,duration:stream=codec_type,codec_name,width,height -of csv=p=0 "$f" 2>/dev/null | tr '\n' ' ')
    vid=$(echo "$info" | grep -o "video,[a-z0-9_]*" | head -1)
    if [ -n "$vid" ]; then
      ok=$((ok+1))
      log "     ffprobe: $info"
      dst="$OUT/${base%.*}.mp4"; [ -e "$dst" ] && dst="$OUT/${base%.*}_$idx.mp4"
      cp "$f" "$dst" 2>/dev/null && log "     => 已导出 $dst" || log "     => 拷贝失败!"
    else
      unknown=$((unknown+1))
      log "     ffprobe 解不出(可能是DASH分片/加密/非标准), 前 32 字节:"
      xxd -l 32 "$f" | sed 's/^/       /' | tee -a "$LOG"
    fi
  else
    log "     <1MB 非文本非库文件, 跳过深度探测"
  fi
  log ""
done < <(find "$SRC" -type f ! -path "*/probed/*" ! -name "probe_report.txt" | sort)

log "===== 汇总 ====="
log "文件总数: $idx | 可识别视频: $ok | SQLite库: $db | 文本: $text | 待深入: $unknown"
log "可播放副本在: $OUT"
log "完整报告: $LOG"
