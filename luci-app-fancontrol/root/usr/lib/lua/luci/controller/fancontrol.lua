module("luci.controller.fancontrol", package.seeall)

local CONFIG  = "fancontrol"
local SECTION = "main"

function index()
    entry({"admin", "system", "fancontrol"}, template("fancontrol"), _("风扇控制"), 60)
    entry({"admin", "system", "fancontrol", "data"}, call("action_data")).leaf = true
    entry({"admin", "system", "fancontrol", "save"}, call("action_save")).leaf = true
end

local function readfile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function trim(s)
    if not s then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function json_escape(s)
    s = tostring(s or "")
    s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r")
    return '"' .. s .. '"'
end

local function read_int(path)
    local v = trim(readfile(path) or "")
    return tonumber(v:match("%d+"))
end

-- 解析 /tmp/fancontrol_ramp（key=value 逐行）。
-- 这是 daemon 落的「最近一段渐入」快照，含准确的总时长与起止时刻，
-- 页面据此显示「还要多久」；比让前端靠轮询采样反推可靠得多
-- （轮询间隔远大于 1 秒，反推出来的剩余秒数会跳）。
local function read_ramp()
    local raw = readfile("/tmp/fancontrol_ramp") or ""
    local t = {}
    for k, v in raw:gmatch("(%w+)=(%-?%d+)") do t[k] = tonumber(v) end
    return t
end

function action_data()
    local sys = require("luci.sys")
    local uci = require("luci.model.uci").cursor()

    local history = readfile("/tmp/fancontrol_history.txt") or ""

    local temp = read_int("/sys/class/thermal/thermal_zone0/temp") or 0
    if temp > 1000 then temp = temp / 1000 end

    local pwm = read_int("/sys/class/hwmon/hwmon3/pwm1") or 0
    local rpm = read_int("/sys/class/hwmon/hwmon3/fan1_input") or 0
    local tz_mode = trim(readfile("/sys/class/thermal/thermal_zone0/mode") or "")
    local tz_policy = trim(readfile("/sys/class/thermal/thermal_zone0/policy") or "")

    local pid = trim(sys.exec("pgrep -f fancontrol-loop | head -n1"))
    pid = pid:match("%d+") or ""
    local autostart = trim(sys.exec("ls /etc/rc.d/S99fancontrol >/dev/null 2>&1 && echo 1 || echo 0"))

    local keys = {"mode","manual_speed","auto_temp_low","auto_temp_mid","auto_temp_high",
                  "auto_pwm_low","auto_pwm_mid","auto_pwm_high",
                  "min_temp","max_temp","min_speed","max_speed","interval",
                  "night_enabled","night_start","night_end","night_speed",
                  "guard_enabled","guard_temp","guard_exit","guard_speed","ramp_up"}
    local cp = {}
    for _, k in ipairs(keys) do
        local v = uci:get("fancontrol", "main", k) or ""
        local n = tonumber(v)
        if n then
            cp[#cp+1] = json_escape(k) .. ":" .. tostring(n)
        else
            cp[#cp+1] = json_escape(k) .. ":" .. json_escape(v)
        end
    end

    luci.http.prepare_content("application/json")
    local ramp = read_ramp()
    -- 剩余秒数由服务端算好：now 是 daemon 落盘时刻，dur 是这段渐入的总时长。
    -- 到点后 dur 会被清成 0，这里一并输出 active 让页面决定要不要显示进度。
    local remain = 0
    if (ramp.active or 0) == 1 and (ramp.dur or 0) > 0 then
        remain = (ramp.start or 0) + ramp.dur - (ramp.now or 0)
        if remain < 0 then remain = 0 end
    end
    luci.http.write(
        "{" ..
        '"history":' .. json_escape(history) .. "," ..
        '"now":{"temp":' .. string.format("%.1f", temp) ..
            ',"pwm":' .. tostring(pwm) ..
            ',"rpm":' .. tostring(rpm) ..
            ',"ramp_active":' .. tostring(ramp.active or 0) ..
            ',"ramp_from":' .. tostring(ramp.from or 0) ..
            ',"ramp_to":' .. tostring(ramp.to or 0) ..
            ',"ramp_dur":' .. string.format("%.1f", ramp.dur or 0) ..
            ',"ramp_remain":' .. string.format("%.1f", remain) ..
            ',"tz_mode":' .. json_escape(tz_mode) ..
            ',"tz_policy":' .. json_escape(tz_policy) ..
            ',"time":' .. json_escape(os.date("%H:%M")) .. "}," ..
        '"service":{"pid":' .. json_escape(pid) ..
            ',"autostart":' .. (autostart == "1" and "true" or "false") .. "}," ..
        '"config":{' .. table.concat(cp, ",") .. "}" ..
        "}"
    )
end

local function slog(msg)
    msg = tostring(msg):gsub("'", ""):gsub("`", ""):gsub("%$", ""):gsub('"', "")
    pcall(function() luci.sys.exec("logger -t fanctrl '" .. msg .. "'") end)
end

function action_save()
    local http = require("luci.http")
    local sys = require("luci.sys")

    -- 鉴权说明：本节点挂在 admin 下，LuCI dispatcher 已用 sauth 强制要求登录会话，
    -- 未登录请求根本到不了这里。此版本 dispatcher 从不写入 context.authtoken，
    -- 模板里的 <%%=token%%> 恒为空，若在此再比对 token 会把所有保存 403 掉。

    -- 【重要】不用 luci.model.uci 的 cursor 落盘：
    -- uhttpd 是长驻进程，其 cursor 会缓存配置快照；第二次以后的请求拿到的是被
    -- 污染的旧缓存，uci:set + uci:commit 与磁盘内容比对后判定「无变化」而跳过写入，
    -- 表现为「页面提示保存成功，但 /etc/config 纹丝不动、mtime 不变」。
    -- 改用 uci 命令行：每次 fork 独立进程、无缓存，写入必定落盘。
    local function uci_set(key, val)
        -- val 已经过白名单/数值/时间格式校验，这里再做一次 shell 字符剔除
        val = tostring(val):gsub("[^%w_%.%-:]", "")
        if val == "" then return false end
        local rc = sys.call("uci set " .. CONFIG .. "." .. SECTION .. "." .. key .. "='" .. val .. "' >/dev/null 2>&1")
        return rc == 0
    end

    -- 规范化取值：formvalue 可能返回 nil / "" / "undefined" / "null"（前端 JS undefined 被序列化的结果），
    -- 这些一律视为“未提供”，绝不写入 uci，避免把好参数清空。
    local function field(k)
        local v = http.formvalue(k)
        if v == nil then return nil end
        v = tostring(v):match("^%s*(.-)%s*$")
        if v == "" or v == "undefined" or v == "null" or v == "NaN" then return nil end
        return v
    end

    local seen = {}
    local seenkeys = {"mode","manual_speed","auto_temp_low","auto_temp_mid","auto_temp_high",
                      "auto_pwm_low","auto_pwm_mid","auto_pwm_high",
                      "min_temp","max_temp","min_speed","max_speed",
                      "night_enabled","night_start","night_end","night_speed",
                      "guard_enabled","guard_temp","guard_exit","guard_speed","ramp_up"}
    for _, k in ipairs(seenkeys) do
        local v = field(k)
        seen[#seen+1] = k .. "=" .. (v == nil and "-" or v:gsub("[^%w_%.%-:]", "?"))
    end
    slog("SAVE " .. table.concat(seen, " "))

    local function num(v, lo, hi, def)
        local n = tonumber(v)
        if not n then return def end
        if n < lo then n = lo end
        if n > hi then n = hi end
        return tostring(math.floor(n + 0.5))
    end

    local applied, failed = 0, {}

    local mode = field("mode")
    if mode == "system" or mode == "auto" or mode == "auto_curve" or mode == "manual" then
        if uci_set("mode", mode) then applied = applied + 1 else failed[#failed+1] = "mode" end
    end

    local specs = {
        {"manual_speed", 0, 255, 128},
        {"auto_temp_low", 20, 100, 50},
        {"auto_temp_mid", 20, 110, 60},
        {"auto_temp_high", 30, 120, 75},
        {"auto_pwm_low", 0, 255, 50},
        {"auto_pwm_mid", 0, 255, 128},
        {"auto_pwm_high", 0, 255, 255},
        {"min_temp", 20, 100, 40},
        {"max_temp", 30, 110, 70},
        {"min_speed", 0, 255, 50},
        {"max_speed", 0, 255, 255},
        {"night_speed", 0, 255, 0},
        {"guard_temp", 40, 120, 90},
        {"guard_exit", 30, 120, 80},
        {"guard_speed", 0, 255, 178},
        {"ramp_up", 0, 120, 30}
    }
    for _, s in ipairs(specs) do
        local v = field(s[1])
        if v ~= nil then
            if uci_set(s[1], num(v, s[2], s[3], s[4])) then applied = applied + 1
            else failed[#failed+1] = s[1] end
        end
    end

    -- 时间窗（HH:MM，24 小时制）
    for _, k in ipairs({"night_start", "night_end"}) do
        local v = field(k)
        if v ~= nil then
            local h, m = v:match("^(%d%d?):(%d%d)$")
            h, m = tonumber(h), tonumber(m)
            if h and m and h < 24 and m < 60 then
                if uci_set(k, string.format("%02d:%02d", h, m)) then applied = applied + 1
                else failed[#failed+1] = k end
            end
        end
    end

    -- 开关
    for _, k in ipairs({"night_enabled", "guard_enabled"}) do
        local v = field(k)
        if v == "1" or v == "0" then
            if uci_set(k, v) then applied = applied + 1 else failed[#failed+1] = k end
        end
    end

    -- 一次性提交（同样走命令行，避免 cursor 缓存）
    local rc = sys.call("uci commit " .. CONFIG .. " >/dev/null 2>&1")
    local committed = (rc == 0)

    -- 提交后再独立读回磁盘真实值，作为返回给前端的权威数据（不走缓存）
    local function uci_get(k)
        return trim(sys.exec("uci -q get " .. CONFIG .. "." .. SECTION .. "." .. k .. " 2>/dev/null") or "")
    end

    -- 跨字段校验：退出温度必须低于守护温度。
    -- 反序时（exit >= temp）温度落在 [temp, exit] 区间会出现永久闭锁死区 ——
    -- 触发条件成立后，退出条件也成立，但 elif 分支不会被求值，于是风扇卡在
    -- 守护转速退不出来。这里只警告、不擅自改写用户设置；真正的兜底在
    -- fancontrol-loop 里：它会把 exit 夹到「guard_temp − 1」，保证必然存在退出点。
    local gtmp = tonumber(uci_get("guard_temp"))
    local gexit = tonumber(uci_get("guard_exit"))
    local warn = ""
    if gtmp and gexit and gexit >= gtmp then
        warn = "guard_exit>=guard_temp"
        slog(string.format("WARN guard order invalid: guard_temp=%s guard_exit=%s (daemon will clamp exit to %d)",
             tostring(gtmp), tostring(gexit), gtmp - 1))
    end

    local verify = {}
    for _, k in ipairs({"mode", "manual_speed", "guard_temp", "guard_exit", "guard_speed",
                        "night_enabled", "night_speed", "ramp_up"}) do
        verify[#verify+1] = json_escape(k) .. ":" .. json_escape(uci_get(k))
    end

    slog(string.format("SAVE-DONE applied=%d failed=%s committed=%s mode=%s manual_speed=%s",
        applied, (#failed == 0 and "none" or table.concat(failed, ",")),
        tostring(committed), uci_get("mode"), uci_get("manual_speed")))

    -- 唤醒守护进程立刻重跑一轮，实现「保存后立即生效」（否则最多要等一个采样周期）
    sys.call("touch /tmp/fancontrol_reload >/dev/null 2>&1")

    -- 仅在显式要求时重启服务（会清空历史曲线）
    if http.formvalue("restart") == "1" then
        sys.call("/etc/init.d/fancontrol restart >/dev/null 2>&1")
    end

    http.prepare_content("application/json")
    http.write('{"status":"' .. (committed and "ok" or "commit_failed") ..
               '","applied":' .. tostring(applied) ..
               ',"failed":' .. json_escape(table.concat(failed, ",")) ..
               ',"warn":' .. json_escape(warn) ..
               ',"config":{' .. table.concat(verify, ",") .. '}}')
end
