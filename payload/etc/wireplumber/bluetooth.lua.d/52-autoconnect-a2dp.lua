-- 让 WirePlumber/BlueZ 在设备进入范围时自动建立 A2DP 连接，
-- 这样就不需要外部脚本轮询 bluetoothctl connect（那是笨办法）。
if bluez_monitor then
	bluez_monitor.properties["bluez5.auto-connect"] = {
		"a2dp_sink",
		"hfp_hf",
		"hsp_hs",
	}
end
