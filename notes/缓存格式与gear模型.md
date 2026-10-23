# 缓存格式与 gear 模型

抖音精选（AwemeJX）磁盘侧的技术档案。所有结论来自实际抓取的文件分析。

---

## 1. `.mdl` 与 `.mdlnodeconf`

成对存在，一一对应：

| 文件 | 内容 |
|---|---|
| `<fkey>.mdl` | **数据**，裸 MP4（`ftyp` 开头），`ffprobe` 可直接读 |
| `<fkey>.mdlnodeconf` | **索引**，`ttmd` 魔数二进制，仅区间表 + `fkey` |

关键点：

- `.mdlnodeconf` 里**没有 URL**，只有区间表和 fkey
- `fkey` 是 **md5 命名**，仅作缓存 key，**不是密钥**（早期误解）
- `group_id`（itemID）和 `raw_key`（video_id）在事件日志中与 fkey 关联
- 文件是**预分配稀疏**的：未下载区间为零填充

> ⚠️ **别把文件大小当已下载量。** 实测一个 790MB 的 `.mdl`，覆盖率只有 2.9%（约 23MB 有数据），中间 760MB 全是零。

---

## 2. 两套缓存路径

### 2.1 AWEOfflineCenter（离线下载）

```
Library/AWEStorage/FilePermanent/AWEOfflineVideoCenter/<uid>/<n>/kAWEOfflineCenterModelKey
```

NSKeyedArchiver bplist，含 `downloadedModels`：

```
title / itemID / fileSize / isFileExist
```

**特点：只给低档。** 实测《女主》第二集 359.1MB ÷ 4181s = **684kbps = 576p**。

### 2.2 TTPlayerCache / AVMDL（播放缓存）

```
Library/Caches/TTPlayerCache/
Library/Caches/TTPlayerCache/offlineCaches/
Library/Caches/TTPlayerCache/JingXianFeedCache/
Library/Caches/TTPlayerCache/feedPrecacheV2/
Library/Caches/TTPlayerCache/mdlManual/
```

文件名直接带 gear 名，一眼看出档位：

```
v0200fg1..._bytevc1_1440p_2040416.mdl
       ↑           ↑      ↑
   video_id    HEVC   1440p + 码率
```

**特点：上得去高档**（实测摸到 1440p、设备上躺过 3840×2160 残片），但**稀疏**，只下播过的部分。

### 2.3 对比

| | AWEOfflineCenter | TTPlayerCache / AVMDL |
|---|---|---|
| 触发 | 点「缓存/下载」 | 播放 |
| 清晰度 | 低档（576p / 684kbps） | 高档（1440p / 4K） |
| 完整性 | 填满 | 稀疏 |

> **"离线下载很糊"不是网络问题，是产品策略。** 想拿高画质必须走播放，或直接抓播放链路。

---

## 3. gear 模型（清晰度档位表）

从 `AwemeJXCore` 挖出的播放模型：

```
每档画质:
  gear_name          # 档位名
  quality_type       # 质量类型
  bit_rate           # 码率
  play_addr          # H.264 直链
  play_addr_265      # H.265 直链
  is_bytevc1         # 是否字节自研 VC1（HEVC）

档位表:
  gear_group
  default_gear_name
  bitrateRange
  minNetwork         # 最低网络要求
```

播放时按 `minNetwork` 自适应选档。**想拿最高画质必须在 App 里手动切档。**

---

## 4. fMP4 缓存文件结构

```
ftyp isom + moov + sidx + moof + mdat
```

- `moov` 的 `mvhd` 声明总时长（实测 4,180,326ms = 69.7min ✓）
- `tkhd` 里有真实分辨率（实测 2560×1440，**不是** 4K——之前从别处读到的 3840×2160 是另一档）
- `moof`/`mdat` 对**只出现在文件头和尾部**（稀疏文件的已下载区间）
- mdat 载荷是**明文 HEVC**，NAL 链 `[32,33,34,39,19]`

### 4.1 音视频分轨

同一部视频，视频轨和音频轨是**两个独立的 `.mdl`**：

```
dcb282cc....mdl   790MB   视频  HEVC 2560x1440  4181.4s
c98cb35....mdl    69.9MB  音频  AAC            4181.4s
```

**播放器只预下载音频轨，视频走流式不落盘**——这是最终必须走注入抓流的直接原因。

---

## 5. 事件日志里的下载任务

```
Documents/applog.tttracker/tttracker_custom_event.sqlite
  → entire_log 字段
    → bb_protocol 下载任务 JSON
      → file_Key / raw_key / group_id
      → task_cfg（App 当前在用的完整 URL 列表、fileId、bitrate、encryptVersion:0）
```

**`encryptVersion:0`** —— App 自己的任务配置里就写着未加密。这个字段早期被忽略了，其实它一开始就说明问题。

---

## 6. 从 ffprobe 反查 video_id

已下载的 mp4，`format_tags=comment` 里有 `vid:<video_id>`（盯哨器 remux 时写入的）：

```bash
ffprobe -v error -show_entries format_tags=comment -of default=nw=1 out.mp4
```

没有 comment 时，从文件名（gear 名形式）或分享链接拿。

---

## 7. 容器与目录速查

| 项 | 值 |
|---|---|
| App bundle | `com.ss.iphone.yumme.video` |
| Data 容器 UUID | `E694D148-F119-4239-A804-958C567C68FB` |
| AppGroup UUID | `DE6967E0-0083-414C-A3B6-ED48539D0CB5` |
| 主二进制 | `AwemeJXCore.framework/AwemeJXCore`（arm64 单片 922MB，含符号） |
| 音频框架 | `AudioXAAC.framework` + `TTFFmpeg.framework` + `byteaudio.framework` |
| mmkv 位置 | `Documents/mmkv/`（`BDXPrefetchStorageDomain` 16MB 环形缓冲） |
