# TODO

## 股票页遗留项（主体已于 2026-07-13 实现）
- 备用数据源故障切换：新浪 `hq.sinajs.cn`（需 Referer 头）作腾讯接口的 fallback，参考 [Ashare](https://github.com/mpquant/Ashare) 双核心设计
- 设备网页配置自选股（目前只有 Mac/Win 菜单）

## USB 有线直连（本轮做了 Mac + 固件，遗留项）
- Windows 桥接串口支持（System.IO.Ports，扫 COM 口并接入 #HELLO/#STATUS/#STOCK/#WEATHER/#CMD 协议）
- 有线模式下音乐页二进制数据（封面/文字条尚未走串口分帧，纯 USB 时只能显示基础占位内容）
