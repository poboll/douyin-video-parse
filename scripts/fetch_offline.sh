#!/bin/zsh
# fetch_offline.sh — 抖音精选离线缓存盯梢抓取器
# 原理: 轮询 iPad WebDAV(默认 192.168.1.70:11111) 上抖音精选容器的
#       TTPlayerCache/ 与 TTPlayerCache/offlineCaches/ 两个目录,
#       自动下载所有 >30MB 的 .mdl 文件(视频轨/音轨分开存),
#       下全后 ffmpeg -c copy 无损合成一个 .mp4。
# 用法: ./fetch_offline.sh [轮询间隔秒, 默认60]
set -u
WEBDAV=${WEBDAV:-http://192.168.1.70:11111}
CONTAINER=${CONTAINER:-E694D148-F119-4239-A804-958C567C68FB}
B=$WEBDAV/var/mobile/Containers/Data/Application/$CONTAINER
DEST=~/Downloads/offline_final
INTERVAL=${1:-60}
MIN_SIZE=31457280   # 30MB
mkdir -p "$DEST"

log() { print -r -- "[$(date '+%H:%M:%S')] $1"; }

log "开始盯梢 TTPlayerCache (目标: 视频/音轨 .mdl, >30MB 或 v0200* 清晰度命名文件), 结果目录: $DEST"

while true; do
  for DIR in "Library/Caches/TTPlayerCache" \
             "Library/Caches/TTPlayerCache/JingXuanFeedCache" \
             "Library/Caches/TTPlayerCache/feedPrecacheV2" \
             "Library/Caches/TTPlayerCache/offlineCaches"; do
    files=$(curl -s -m 15 -X PROPFIND -H "Depth: 1" "$B/$DIR/" \
            | grep -oE '<D:href>[^<]+\.mdl</D:href>' | sed 's/<D:href>//;s|</D:href>||')
    for u in $files; do
      name=$(basename "$u")
      [ -f "$DEST/$name" ] && continue
      rsz=$(curl -s -m 10 -X PROPFIND -H "Depth: 0" "$B/$DIR/$name" \
            | grep -oE '<D:getcontentlength>[0-9]+' | grep -oE '[0-9]+')
      [ -n "$rsz" ] || continue
      # 大文件 或 清晰度命名文件(v0200fg1..._bytevc1_2160p_XXXX) 才抓
      if [ "$rsz" -gt "$MIN_SIZE" ] || [[ "$name" == v0200* ]]; then
        log "发现 $name ($((rsz/1048576))MB) -> 下载中"
        curl -s -m 7200 -o "$DEST/$name" "$B/$DIR/$name" \
          && log "$name 下载完成 ($(du -h "$DEST/$name" | cut -f1))" \
          || log "$name 下载失败, 下轮重试"
      fi
    done
  done
  # 尝试无损合成: 找视频流(有宽度)+音轨(aac)各一个
  V=""; A=""
  for f in "$DEST"/*.mdl; do
    [ -f "$f" ] || continue
    info=$(ffprobe -v error -show_entries stream=codec_type,codec_name,width -of csv=p=0 "$f" 2>/dev/null)
    echo "$info" | grep -q "^video" && [ -z "$V" ] && V="$f"
    echo "$info" | grep -q "audio" && [ -z "$A" ] && A="$f"
  done
  if [ -n "$V" ] && [ -n "$A" ]; then
    OUT="$DEST/final_$(date '+%H%M%S').mp4"
    if ffmpeg -y -v error -i "$V" -i "$A" -c copy -movflags +faststart "$OUT" 2>/dev/null; then
      log "合成完成: $OUT ($(du -h "$OUT" | cut -f1))"
      log "视频轨: $(basename $V) | 音轨: $(basename $A)"
      log "全部完成, 退出。人工核对时长后可再次运行本脚本抓下一部。"
      exit 0
    else
      log "合成失败(可能音视频未下全), 继续等待"
    fi
  else
    log "等齐: 视频轨=${V:+有} 音轨=${A:+有}"
  fi
  sleep "$INTERVAL"
done
