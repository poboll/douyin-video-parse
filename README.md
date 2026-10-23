# 抖音视频解析（含抖音精选付费版权视频）

> **仓库名说明**：原定仓库名「抖音视频解析含抖音精选付费版权视频」被 GitHub 的名称规范化规则 stripping 成 `-`（非 ASCII 字符被移除，实测 `gh repo create` 与 REST PATCH 均如此，中文可正常用于 description 与文档标题）。故仓库名用 ASCII 的 `douyin-video-parse`，完整中文名保留在标题、description 与 `git remote` 备注里。

一套在 iPad / iPhone 上实践打通的抖音 & 抖音精选（AwemeJX）视频解析方案，覆盖三类目标：

| 目标 | 状态 | 路线 |
|---|---|---|
| 普通抖音视频（含无水印） | ✅ 已跑通，可复现 | 纯 HTTP，见 [docs/01](docs/01-普通抖音视频解析.md) |
| 抖音精选付费版权视频 | ✅ 已跑通，69.7 分钟正片完整交付 | 缓存逆向 + 注入抓流，见 [docs/02](docs/02-抖音精选视频解析.md) |
| 加密 / DRM 相关研究 | ✅ 已定案：**视频根本没加密** | 完整复盘与误判修正，见 [docs/03](docs/03-加密研究完整复盘.md) |

本仓库只做技术沉淀与思路复盘，**不提供任何破解后的成品内容**。

---

## 三个问题的回答

### Q1：目前我们的路线是仅适用巨魔（TrollStore）的吗？

**不是。分三层，越往里越依赖巨魔：**

| 层 | 手段 | 依赖 |
|---|---|---|
| ① 拿播放直链 | `api-play dash` / `iesdouyin` 端点、mmkv 里的新鲜直链 | **零依赖**，Mac 上裸 curl 就行 |
| ② 读 App 沙盒/缓存 | WebDAV 暴露、iTunes 备份、砸壳 IPA 静态分析 | 需要能碰到设备文件，但不限定巨魔 |
| ③ 注入抓流 | `ep2dump.dylib` / `frida-gadget.dylib` | **依赖 TrollStore 或同类永久签名环境** |

第 ① 层是关键：`api-play.amemv.com` 的 dash 端点从 Mac 直连就返回 302 跳到**新签名的 `er=0` 无水印 CDN 直链**，不需要 cookie、不需要任何设备端配合。这一层任何设备、任何网络位置都能用。

巨魔的价值集中在第 ③ 层——让注入的 dylib 拥有**永久有效签名**，不用每次重签、不用管证书过期。同样的事情越狱环境能做，非越狱用自签 IPA + `insert_dylib` 也能做（7 天有效期，烦但可行）。所以准确说法是：**巨魔是第 ③ 层的捷径，不是整条路的前提。**

另外用户环境本来也装不了 deb（frida-server.ipa 有后台挂起死穴），所以走 dylib 注入而不是 frida-server，这也是方案选择的一部分原因。

### Q2：你觉得会被抖音官方发现吗？

**分两层看，结论不一样：**

**第 ① 层（HTTP 直链）——几乎不会被发现，但有边界。**
- 用的全是 App 和浏览器自己也在打的公开端点，请求特征与正常客户端无异。
- 真正的边界在**风控而非检测**：CDN 直链自带 `l=` 新鲜度 token 和 `x-expires` 有效期，过期自然失效；服务端已经表现出"按视频 ID 封锁"的能力，说明有内容级策略在跑。
- 单设备、低频、自用，风险很低。规模化、分发、高频拉取，就是另一回事了。

**第 ③ 层（注入）——有风险，风险不在网络侧而在完整性校验侧。**
- TrollStore 注入会改 App 二进制，签名变化是可检测的；dylib 加载也会改变进程特征。`dumper.m` 源码注释里就明确写了"注入会改变 App 二进制，有登录风控风险"。
- 整个实践过程中**没有触发封号**，但也没有做任何大规模压测——这个结论只对"低频单设备自用"成立。
- 想再降一档，可以让 dylib 只在回前台时跑一次、跑完自动卸载，把驻留时间压到最短。

### Q3：为什么 api 接口是投毒的，现在 app 获取的却是未加密的？

**因为"投毒"投在准入层，不在载荷层。** 这是本次研究最重要的结论，完整证据链见 [docs/03](docs/03-加密研究完整复盘.md)，这里说结论：

**抖音的版权保护模型不是 DRM（内容加密），而是「链路准入 + 水印 + 缓存策略」三件套：**

1. **链路准入**：`api-play dash` / `api.amemv.com` / `iesdouyin` / `douyin.com` 网页端，四个端点对目标视频**全部 404**。这不是"内容加密所以不给你"，是"不让你问"。
2. **水印是烧录的，不是加密的**：URL 带 `lr=aweme_search_suffix` 就会多渲染一路带抖音号的版本，右下角水印直接压在画面像素里。
3. **清晰度由 gear 模型控制**：离线下载走 `AWEOfflineCenter` 只给 576p/684kbps，播放才给高档——这是**产品策略**，不是技术封锁。
4. **视频走流式不落盘**：播放器只预下载音频轨，视频走流式解码——这是**防落盘**，不是加密。

所以 App 从 CDN 拿到的就是**明文 HEVC 码流**，VideoToolbox 直接解，中间没有任何解密步骤。这正是我们下了 14 个 AES hook（含 `av_aes_gcm_256_decrypt`）却**零调用**的原因——不是 hook 失败，是本来就没有东西要解密。

**404 的根因我们最终没有完全定案**（可能是签名不新鲜，也可能是服务端策略），但可以确定**它不是 DRM**——因为同一部视频 App 侧拿到的是明文码流，最终从 `VTDecompressionSessionDecodeFrame` 解码入口完整抓出 790MB 并成功出片。

**那"投毒"到底投在哪？** 投在**给你的结果**上：对外部请求，要么 404，要么给带水印的搜索 prefetch 链，要么给低档位。给你能用的东西，但要么是残次品，要么直接没有。而不是给你一份加密的内容让你去解。

---

## 端点速查表

| 端点 | 用途 | 是否需要签名 |
|---|---|---|
| `api-play.amemv.com/aweme/v1/play/dash/?video_id=<vXXXX>&line=0&file_id=<dash_fkey>&sign=<sign>&is_play_url=1&source=PackSourceEnum_COLLECTION` | **明文母版源**，302 到 `er=0` 无水印 CDN 直链 | 带 Aweme UA 即可 |
| `api-play.amemv.com/aweme/v1/play/?video_id=<vXXXXfg...>&line=0&ratio=<540p/720p/1080p>&biz_sign=<base64blob>&logo_name=aweme&source=PackSourceEnum_COLLECTION` | 换档跳转服务，`ratio` 任选，服务端按实际最高档回落 | `biz_sign` 绑定 video_id，不可伪造 |
| `www.iesdouyin.com/aweme/v1/play/?video_id=..&ratio=1080p&line=0&is_play_url=1` | Web 端点，支持选档且无水印 | 普通浏览器 UA，无签名 |
| `api.amemv.com/aweme/v1/play/dash/...` | 同上，备用域 | 带 Aweme UA |

**URL 参数与内容的关系：**

| 参数 | 含义 |
|---|---|
| `er=0` | 无水印干净链 |
| `lr=aweme_search_suffix` | 带抖音号水印（搜索 prefetch 链） |
| `ch` / `cr` | 加密相关开关（实测改参数内容不变，签名 `l=` 不覆盖它们） |
| `l=20261021154102AA6A4EC...` | 新鲜度 token = 14 位时间戳 + hex |
| `x-expires` | 有效期，Unix 时间戳 |

---

## 快速开始

### 普通抖音视频（零依赖）

```bash
# 拿到 video_id 后，直接要 1080p 无水印
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
L=$(curl -s -m 15 -A "$UA" -o /dev/null -w "%{redirect_url}" \
    "https://www.iesdouyin.com/aweme/v1/play/?video_id=<video_id>&ratio=1080p&line=0&is_play_url=1")
curl -s -L --retry 3 -A "$UA" "$L" -o out.mp4
```

### 抖音精选（需要 iPad）

```bash
# 1. 盯梢器：App 解析出新鲜直链后自动抓下载
cd scripts
WEBDAV=http://<iPad-IP>:11111 CONTAINER=<容器UUID> ./watch2.sh 20

# 2. 缓存导出插件（TrollStore 注入）
xcrun -sdk iphoneos clang -arch arm64 -isysroot "$(xcrun -sdk iphoneos --show-sdk-path)" \
  -mios-version-min=15.0 -fobjc-arc -dynamiclib \
  -framework Foundation -framework UIKit -o dumper.dylib dumper.m

# 3. 解码入口抓流（拿到明文码流后重封装）
cat ps.h265 sess_X.h265 > all.h265
ffmpeg -f hevc -i all.h265 -c copy -movflags +faststart out.mp4
```

---

## 目录结构

```
├── README.md                          ← 你在这里
├── docs/
│   ├── 01-普通抖音视频解析.md           # api-play dash / iesdouyin / mmkv 直链
│   ├── 02-抖音精选视频解析.md           # 缓存逆向、gear 模型、注入抓流
│   ├── 03-加密研究完整复盘.md           # DRM 误判修正全过程 + 最终结论
│   └── 04-踩坑记录.md                  # 全部踩过的坑，按"症状→根因→修法"组织
├── scripts/
│   ├── watch_urls.sh                  # 盯梢器 v1：mmkv 新鲜直链
│   ├── watch2.sh                      # 盯梢器 v2：直链 + 播放缓存大文件
│   ├── fetch_offline.sh               # 轮询 TTPlayerCache 拉 .mdl
│   ├── probe_cache.sh                 # 缓存目录探测
│   ├── sweep3.py                      # 全容器递归爬取（找含直链的中小文件）
│   ├── dumper.m / build.sh            # TrollStore 缓存导出插件
│   ├── ep2dump.m                      # 注入抓流插件源码（v1 基线）
│   ├── ep2dump.js                     # frida agent（recon/dump 双模）
│   ├── frida_run.py                   # Mac 端 frida 驱动
│   ├── 注入操作说明.md                 # 三条注入路线对比
│   └── ep2抓取.py                     # WebDAV 拉 dump → 合并 → 定起点
└── notes/
    ├── 缓存格式与gear模型.md            # .mdl / .mdlnodeconf / gear API 字段
    └── 关键事实速查.md                 # itemID / video_id / 容器 UUID 等
```

---

## 实测成果

| 成片 | 规格 | 大小 |
|---|---|---|
| 143 分钟纪录片 | HEVC 3840×2160 / 60fps / 无水印 | 3.5 GB |
| 竖屏 35.7 分钟 | H.264 1080×1920 / 无水印 | 705 MB |
| 10:28 视频 | HEVC 4K / 无水印 | 250 MB |
| **《女主》第二集** | HEVC 2560×1440 / 69.7 分钟 / 完整音画 | 1.5 GB |

最后一部是付费版权内容，走的是第 ③ 层路线（`VTDecompressionSessionDecodeFrame` 抓明文码流），完整过程见 [docs/02](docs/02-抖音精选视频解析.md) 和 [docs/03](docs/03-加密研究完整复盘.md)。

---

## 免责声明

本仓库内容**仅用于技术研究与学习交流**，所有分析均基于作者自己的设备与自己的账号内容。

- 请勿用于传播、分发他人版权内容，或任何商业用途
- 请遵守抖音平台服务条款与当地法律法规
- 作者不对使用本仓库内容造成的任何后果负责
- 如果你在自己的设备上复现，请注意文中提到的安全风险（注入改签名、免认证 WebDAV 暴露全盘等）
