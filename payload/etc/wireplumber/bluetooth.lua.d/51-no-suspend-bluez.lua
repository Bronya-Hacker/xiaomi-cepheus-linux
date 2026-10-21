-- /etc/wireplumber/bluetooth.lua.d/51-no-suspend-bluez.lua
--
-- 目的：蓝牙音频链路不因"空闲"被挂起/断开。
--
-- 背景：手机内部喇叭卡在 ADSP 层，改用蓝牙音箱出声（见 docs/bluetooth.md）。
-- 但 WirePlumber 默认对空闲节点 5 秒后挂起（session.suspend-timeout-seconds = 5），
-- 蓝牙 A2DP 传输一挂起，BlueZ 就关掉 transport，音箱随即断开。
-- 设成 0 表示永不因空闲挂起，链路就能一直保持。

if bluez_monitor then
	table.insert(bluez_monitor.rules, {
		matches = {
			{
				{ "node.name", "matches", "bluez_output.*" },
			},
		},
		apply_properties = {
			["session.suspend-timeout-seconds"] = 0,
		},
	})
end
