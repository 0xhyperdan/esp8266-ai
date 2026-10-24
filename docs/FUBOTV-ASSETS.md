# FuBoTV 原厂天气素材

天气页面复用了 FuBoTV 原厂开源固件中的显示素材：

- `Weather/0.jpeg` 至 `Weather/7.jpeg`：天气状态图标。
- `Astronaut/T1.jpg` 至 `Astronaut/T20.jpg`：宇航员动画帧。
- `Indicators/W0.jpeg`、`Indicators/S0.jpeg`：温度和湿度图标。

文件保留原厂名称和 JPEG 编码，没有重新压缩。它们由
`tools/extract_fubotv_weather_assets.py` 从完整的 4 MiB 原厂备份的 LittleFS 分区提取，
并随 AIClockBridge 的 SwiftPM 资源包一起发布。

Mac 应用把 20 张宇航员图片缩放为 72×72 RGB565 帧并打包，设备按资源版本下载到
LittleFS 后本地循环播放。动画区域固定在右下角，不与日期、星期、温度和湿度文字重叠。

应用只复用显示素材，不包含原厂固件中的账号、第三方 API 密钥、Wi-Fi 配置或其他设备数据。
天气和空气质量数据继续来自 Open-Meteo。
