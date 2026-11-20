# Z-Link for iOS

极核（ZEEHO）第三方 iOS 客户端，SwiftUI 原生实现，构建产物为未签名 ipa。

## 不需要 Mac 的构建方式

GitHub Actions 提供免费的 macOS 机器，编译产物直接从 Actions 下载。

1. 在 GitHub 新建一个空仓库（建议 **Public**，Actions 免费无时长限制；Private 每月约 200 分钟 macOS 额度）。
2. 把这个目录作为仓库根推送：
   ```bash
   cd D:/桌面/ZLink_iOS
   git init -b main
   git add .
   git commit -m "init"
   git remote add origin https://github.com/<你的账号>/<仓库名>.git
   git push -u origin main
   ```
3. 打开仓库的 **Actions** 页，等 `Unsigned IPA` 跑完（约 3–5 分钟）。
4. 在运行详情页底部 **Artifacts** 下载 `ZLink-unsigned-ipa`，解压得到 `ZLink-unsigned.ipa`。

## 安装到 iPhone

Windows 上用 [Sideloadly](https://sideloadly.io/)：

1. 电脑装 iTunes（或 iCloud 版 iTunes 驱动），iPhone 用数据线连上并「信任」。
2. Sideloadly 拖入 ipa，Apple ID 填自己的免费账号，点 Start。
3. iPhone 上「设置 → 通用 → VPN与设备管理」信任该开发者证书。
4. 首次打开若提示不受信任，回上一步重新信任。

免费账号的限制：

- 证书 **7 天**过期，到期用 Sideloadly 重签一次
- 同时最多 **3 个**自签 App
- 没有推送、CarPlay 等受限能力

## 工程结构

独立工程，与 Flutter 版 `jihe_ride` 完全分开（不同目录、不同仓库、互不引用）。

```
project.yml                 XcodeGen 工程描述（xcodeproj 由它生成，不入库）
ZLink/
  App/                      入口、根视图、悬浮玻璃 TabBar
  Core/                     签名、网络、Keychain、模型、配色令牌
  Core/Design/              HIG 组件：卡片/标题/胶囊/环形进度、动效、按压反馈、主控按钮
  Core/Personalization/     背景视频存储、内置动态主题、静态主题目录、本地照片
  Core/BatteryInfo.swift    电池数据解析（候选键递归查找）
  Features/
    Login/                  手机号 + 验证码登录
    Vehicle/                车辆页：主视觉、主控、快捷条、电池卡、地图、骑行、信息
                            + 车辆切换 / 电池详情 / 背景主题 三个弹层
    Map/                    地图：MapKit 容器、自定义标注、轨迹、全屏位置页
    Settings/               我的：账号、车辆管理、电池、主题、壁纸、关于、退出
.github/workflows/          云端编译，产出 unsigned ipa
```

## 功能清单

| 功能 | 状态 | 说明 |
|---|---|---|
| 手机号验证码登录 | 已完成 | token 存 Keychain，401 自动登出 |
| 车辆列表 / 切换 | 已完成 | 底部弹层，卡片显示车图、SOC、在线与锁车状态 |
| 一键解锁 / 关锁 | 已完成 | `network/unlock` |
| 寻车闪灯 / 开坐垫 | 已完成 | `control/{vin}`、`propertyTwo/one`（commond 28） |
| 电量 / 续航 / 里程 | 已完成 | 来自 `vehicle/list` |
| 电池信息 | 已完成 | `batteryInfo/{vin}`，空数据回退 `vehicleHomePage/{vin}`；电压、温度、循环、容量、异常提示 |
| 背景视频 | 已完成 | 相册选视频（≤120MB），转 1080p mp4 存 Documents，静音无缝循环，进后台自动暂停 |
| 内置动态主题 | 已完成 | 极光 / 星云 / 熔岩 / 光雨，SwiftUI Canvas 实时绘制，不占存储、离线可用；低电量与「减弱动态」自动降级为静态帧 |
| 静态主题 / 照片 | 已完成 | 5 套渐变 + 5 套云端封面 + 相册照片（压缩到 2200px），本地持久化 |
| 车辆位置地图 | 已完成 | MapKit + GCJ-02 换算，全屏页可调起系统导航 |
| 骑行轨迹回放 | 未做 | `RideTrack` 解析和地图 polyline 已就绪，缺 `ridetrack_v2` 列表页 |
| 设置页 | 已完成 | 账号、车辆管理、电池、车辆背景、关于、退出 |
| 下拉 / 回前台刷新 | 已完成 | 车辆列表与电池一起刷新；后台回到前台自动刷一次 |
| 低电量提醒 | 已完成 | SOC ≤ 20% 且未充电时在首页提示 |
| 车辆设置指令 | 未做 | 限速、动能回收、自动锁车、OTA 等官方指令尚未接入 |
| 骑行记录列表 | 未做 | 接口 `ridetrack_v2`、`myRideInfo` 已探明，需单独页面 |
| BLE 直连（电池/灯具） | 未做 | iOS 无 FlutterBluePlus 等价封装，需手写 CoreBluetooth |
| 投屏 / 横屏驾驶舱 | 未做 | 依赖 Android 车机端，iOS 不适用 |


## 设计系统（Apple HIG）

全部走系统语义色与 SF Pro 字号，浅色 / 深色自动适配，没有硬编码的品牌色阶。

| 类别 | 取值 |
|---|---|
| 强调色 | `systemBlue` #007AFF（`Theme.brand`） |
| 页面底 | `systemBackground` / `systemGroupedBackground` #F2F2F7 |
| 卡片 | `secondarySystemGroupedBackground` + 12 圆角 |
| 文字 | `label` / `secondaryLabel` / `tertiaryLabel` |
| 分行 | `separator`（0.5pt） |
| 阴影 | `0 4 24 rgba(0,0,0,0.04)`，仅此一种 |
| 字号 | 34 LargeTitle / 28 Title1 / 22 Title2 / 17 Headline·Body / 16 Callout / 15 Subhead / 13 Footnote / 12 Caption |
| 网格 | 8pt 基准、4pt 细分；页边距 16；卡片 12；按钮 10；触控区 ≥44 |

- **车辆页**：268pt 主视觉（背景优先级：背景视频 → 照片 → 内置动态主题 → 云端封面 → 内置渐变；全部按深底处理，文字恒为白色）→ 60pt 主控键 → 三个快捷块（寻车 / 坐垫 / 电池）→ 电池卡（环形电量 + 电压/温度/循环）→ 地图卡 → 骑行与车辆信息
- **主控按钮** `PowerButton`：锁定态 `systemBlue` 实心（解锁），解锁态弱填充（关锁），靠填充度区分状态；按压 0.985 缩放 + 轻触反馈，无渐变、无光晕
- **背景层**：视频用 `AVQueuePlayer` + `AVPlayerLooper` 无声循环，首帧封面兜底避免黑闪；动态主题用 `TimelineView(.animation)` + `Canvas` 30fps 绘制，切后台/低电量自动静止
- **材质**：TabBar 用 `.regularMaterial` + 顶部 0.5pt 分隔；地图悬浮标签、Toast、头部圆按钮、玻璃标签用 `.ultraThinMaterial`
- **数据小件**：`MetricChip` 弱填充底 + 次要色标题；`RingProgress` 进场从 0 扫到位，颜色只承担语义（蓝=常态、绿=充电、橙=告警）
- **入场**：`.staggerIn(index)` 按 60ms 阶梯淡入上移；切页 0.2s 淡入
- **弹层**：`SheetShell` 统一拖拽条 + 22pt 标题 + 关闭；均为系统 sheet，背景为分组底色

改颜色只动 `Core/Theme.swift`（全是语义色，不要写死 hex）；改节奏动 `Core/Design/Motion.swift`。

本地有 Mac 时：

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project ZLink.xcodeproj -scheme ZLink -configuration Release \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

## 接口与签名

- 域名：`https://tapi.zeehoev.com`
- 签名：`md5(sha1(query + bodyJson + "appId=...&nonce=...&timestamp=..." + secret))`
- 请求头：`Cfmoto-X-Sign` / `Cfmoto-X-Param` / `signature` / `appid` / `timestamp` / `nonce` / `x-app-info`
- 登录接口 `loginByPhone` 必须用 `Authorization: Basic bWNrOjEyMzQ1Ng==`，且签名包含 body
- 凭据存 Keychain，service = `com.liruixin.zlink`

appId / secret 在 `ZLink/Core/ZeehoSigner.swift`。

## 地图：MapKit

定为系统 MapKit，不接第三方地图 SDK，工程保持零依赖——`Frameworks/` 里没有动态库，自签时不会因为嵌套库漏签而失败。

- **容器** `VehicleMapView`（`UIViewRepresentable`）：只在坐标 / 轨迹真正变化时刷新，用户拖动地图不会被 SwiftUI 重绘弹回；关闭旋转、俯仰和 POI 干扰
- **标注** `VehiclePinView`：品牌蓝渐变圆形气泡 + 白色尖角 + 车形图标，图片用 `UIGraphicsImageRenderer` 画一次后复用
- **轨迹**：白色 9pt 打底 + 蓝色 5pt 覆盖的双层 `MKPolyline`，圆角线帽；有轨迹时自动按 boundingRect 取景
- **车辆页内嵌预览**：164pt 高、不可交互（`allowsHitTesting(false)` 保证滚动不被地图吃掉），点击展开全屏
- **全屏页**：顶部悬浮信息卡（坐标 + 上报时间 + 锁车状态）、定位回中、底部「在地图中导航过去」调起系统地图
- **坐标系**：`Core/Map/MapCoordinate.swift` 内置 WGS-84 → GCJ-02 换算。MapKit 在中国大陆渲染的是 GCJ-02 底图，接口坐标若同为 GCJ-02 可直接投图；**真机上如果车辆位置整体偏 300–500 米，把 `MapDatum.api` 从 `.gcj02` 改成 `.wgs84` 即可**

不需要 `NSLocationWhenInUseUsageDescription`：这里只显示车辆位置，不取手机自身定位，少了权限请求也少了隐私说明。

## 免责

非官方客户端，接口随时可能变更或加入风控；仅供个人调试，不要分发或商用。
