# 极核智行 · JiheDrive

极核（ZEEHO）电动车主的非官方 iOS 客户端，SwiftUI 纯原生实现，零第三方依赖。

- 工程：`JiheDrive`（XcodeGen 生成 xcodeproj，`project.yml` 是唯一来源）
- 最低系统：iOS 17，仅 iPhone，竖屏
- 包名：`com.liruixin.jihedrive`，显示名 `极核智行`

## 功能

| 模块 | 状态 | 说明 |
|---|---|---|
| 登录 | 已完成 | 手机号 + 短信验证码；也支持直接粘贴 access token。token 存钥匙串，401 自动登出 |
| 主视觉 | 已完成 | 360pt 整块铺满，左上角电量玻璃卡，底部续航/总里程条 |
| 车辆背景 | 已完成 | 相册视频（1080p 转码、静音循环）/ 相册照片 / 12 套内置壁纸 / 4 套动态主题 / 云端封面 |
| 主控 | 已完成 | 一键开解锁、寻车、开坐垫 |
| 电池 | 已完成 | SOC、电压、温度、循环次数；详情页字段自适应解析 |
| 胎压 | 已完成 | 前后轮 bar 值 + 警戒配色（<1.8 红 / 偏离区间橙） |
| 3D 看车 | 已完成 | SceneKit 实时渲染，可旋转缩放、四种涂装 |
| 地图 | 已完成 | MapKit + GCJ-02 换算，全屏页可调起系统导航 |
| 骑行 | 已完成 | 里程概览 + 轨迹列表 + 单条回放（进度、倍速、跟随） |
| 设置 | 已完成 | 账号、车辆管理、背景、关于、退出 |

## 目录

```
JiheDrive/
  App/          JiheDriveApp / RootView / MainTabView（液态悬浮导航）
  Core/
    Theme.swift            语义色与字号令牌
    Design/                AppleUI 组件、动效、按压反馈、循环视频层
    Personalization/       背景存储、内置壁纸绘制、动态主题、主题目录
    Models.swift           Vehicle / Coordinate / RideTrack
    AppModel.swift         车辆、电池、登录状态
    ZeehoClient.swift      签名与请求
  Features/
    Login/                 手机号 / Token 两种登录
    Vehicle/               主视觉、操作区、电池胎压、3D 看车、背景面板
    Map/                   车辆位置地图、轨迹地图
    Ride/                  骑行页、轨迹回放、回放地图
    Settings/              我的
```

## 背景视频

相册选视频 → 统一转 1080p mp4 存 `Documents/Themes/vehicle-backdrop.mp4`，上限 120MB，排除 iCloud 备份。播放用 `AVQueuePlayer + AVPlayerLooper` 无声无缝循环，进后台暂停、回前台续播，首帧做封面避免黑闪。

## 3D 车辆

`Vehicle3DView` 用 `SCNBox / SCNCylinder / SCNTorus / SCNSphere` 按踏板车比例拼出车身、座椅、前叉、车把、轮组、灯组，PBR 材质 + 三灯照明，模型自转、相机可拖动缩放。

## 构建

推送到 `main` 后 GitHub Actions（macos-15）自动执行 `xcodegen generate` + `xcodebuild`，产出未签名 ipa。

- Actions：`https://github.com/chenyulong1130/jihe-drive-ios/actions`
- 产物：`JiheDrive-unsigned`（结构 `Payload/JiheDrive.app`）
- 本地安装：Windows 用 [Sideloadly](https://sideloadly.io/) 自签，免费证书 7 天

## 待办

- 车锁指令方向 `lockFlag` 需真机确认（现在 `isLocked ? 1 : 0`）
- 地图坐标基准：位置整体偏 300–500 米时把 `MapDatum.api` 改成 `.wgs84`
- 云端轨迹接口未确认，骑行页暂时展示示例路线
- 车辆设置指令（限速、动能回收、自动锁车、OTA）尚未接入

## 免责

非官方客户端，接口随时可能变更或加入风控；仅供个人调试，不要分发或商用。
