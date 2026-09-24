// LuCI 风扇温控插件 —— GL.iNet GL-MT3600BE
// ucode controller 版（从 fancontrol.lua 翻译而来）
// Licensed under the MIT License.

'use strict';

import { readfile, popen } from 'fs';
import { cursor } from 'uci';

const CONFIG = 'fancontrol';
const SECTION = 'main';

// 【坑】controller 里 uci 不是全局对象（只有在 .ut template 里才是）。
// 必须显式 import { cursor } from 'uci' 再 cursor() 拿实例，
// 否则 uci.get() 静默返回 null → config 段输出成 {"config":{null}}。
const UC = cursor();

// 取命令 stdout（stderr 丢弃）
// 注意：ucode 的 popen 只接受 1 个参数（command），传模式参数会导致异常
function shell_out(cmd) {
	let fd = popen(cmd + ' 2>/dev/null');
	if (!fd)
		return '';
	let out = fd.read(65536) ?? '';
	fd.close();
	return out;
}

// 只取命令 exit code
function shell_rc(cmd) {
	return system(cmd);
}

// 解析 /tmp/fancontrol_ramp（key=value 逐行）。
// daemon 落的「最近一段渐入」快照，含准确的总时长与起止时刻，
// 页面据此显示「还要多久」；比让前端靠轮询采样反推可靠得多
// （轮询间隔远大于 1 秒，反推出来的剩余秒数会跳）。
function read_file_str(path) {
	return readfile(path) ?? '';
}

function trim(s) {
	if (s == null)
		return '';
	return replace(replace('' + s, /^\s+/, ''), /\s+$/, '');
}

function json_escape(s) {
	s = (s == null) ? '' : '' + s;
	s = replace(s, /\\/g, '\\\\');
	s = replace(s, /"/g, '\\"');
	s = replace(s, /\n/g, '\\n');
	s = replace(s, /\r/g, '\\r');
	return '"' + s + '"';
}

function read_int(path) {
	let v = trim(readfile(path));
	let m = match(v, /\d+/);
	return m ? +m[0] : null;
}

// 按行解析 key=value。
// 【坑】不能用 match(raw, /pat/, off) 循环：ucode 的 match() 会忽略 offset 参数，
// 每次都从头匹配，且 m.index 恒为 null —— 循环变量永不前进，直接死循环。
// 改用 split(raw, "\n") 逐行 + split(line, "=") 取键值。
function read_ramp() {
	let raw = readfile('/tmp/fancontrol_ramp') ?? '';
	let t = {};
	for (let line in split(raw, '\n')) {
		let s = trim(line);
		if (s == '')
			continue;
		let kv = split(s, '=');
		if (length(kv) == 2)
			t[kv[0]] = +kv[1];
	}
	return t;
}

function slog(msg) {
	// 【坑】ucode 的字符串不支持「方法调用」形式（msg.replace(...) 会抛
	// "left-hand side expression is not an array or object"）。
	// 必须用函数形式 replace(str, pat, repl)。
	msg = '' + (msg ?? '');
	msg = replace(msg, /'/g, '');
	msg = replace(msg, /`/g, '');
	msg = replace(msg, /\$/g, '');
	msg = replace(msg, /"/g, '');
	// 【坑】ucode 的 pcall() 不支持「函数名 + 参数」形式（会抛
	// "left-hand side is not a function"）。这里用 try/catch 替代。
	try {
		shell_rc(`logger -t fanctrl '${msg}'`);
	}
	catch (e) {}
}

function uci_set(key, val) {
	// val 已经过白名单/数值/时间格式校验，这里再做一次 shell 字符剔除
	// 【坑】ucode 正则在排除字符类里不支持 \w（/[^\w_.\-:]/ 会把 "auto"
	// 整个替换掉）。必须写成显式字符集。
	val = replace('' + val, /[^0-9a-zA-Z_.:-]/g, '');
	if (val == '')
		return false;
	let rc = shell_rc(`uci set ${CONFIG}.${SECTION}.${key}='${val}' >/dev/null 2>&1`);
	return rc == 0;
}

function uci_get(k) {
	return trim(shell_out(`uci -q get ${CONFIG}.${SECTION}.${k}`));
}

function num(v, lo, hi, def) {
	let n = +v;
	if (n != n) // NaN check
		return def;
	if (n < lo)
		n = lo;
	if (n > hi)
		n = hi;
	return '' + int(n + 0.5);
}

function field(k) {
	let v = http.formvalue(k);
	if (v == null)
		return null;
	v = trim('' + v);
	if (v == '' || v == 'undefined' || v == 'null' || v == 'NaN')
		return null;
	return v;
}

function action_data() {
	let history = read_file_str('/tmp/fancontrol_history.txt');

	let temp = read_int('/sys/class/thermal/thermal_zone0/temp') ?? 0;
	if (temp > 1000)
		temp = temp / 1000;

	let pwm = read_int('/sys/class/hwmon/hwmon3/pwm1') ?? 0;
	let rpm = read_int('/sys/class/hwmon/hwmon3/fan1_input') ?? 0;
	let tz_mode = trim(readfile('/sys/class/thermal/thermal_zone0/mode') ?? '');
	let tz_policy = trim(readfile('/sys/class/thermal/thermal_zone0/policy') ?? '');

	let pid_raw = trim(shell_out('pgrep -f fancontrol-loop | head -n1'));
	let pid_m = match(pid_raw, /\d+/);
	let pid = pid_m ? pid_m[0] : '';

	let autostart = trim(shell_out('ls /etc/rc.d/S99fancontrol >/dev/null 2>&1 && echo 1 || echo 0'));

	let keys = ['mode','manual_speed','auto_temp_low','auto_temp_mid','auto_temp_high',
	            'auto_pwm_low','auto_pwm_mid','auto_pwm_high',
	            'min_temp','max_temp','min_speed','max_speed','interval',
	            'night_enabled','night_start','night_end','night_speed',
	            'guard_enabled','guard_temp','guard_exit','guard_speed','ramp_up',
	            'temp_smooth'];
	let cp = [];
	for (let i = 0; i < length(keys); i++) {
		let k = keys[i];
		let v = UC.get('fancontrol', 'main', k) ?? '';
		let n = +v;
		if (n == n && n == v) {
			// 数值：原样输出
			push(cp, json_escape(k) + ':' + n);
		}
		else {
			push(cp, json_escape(k) + ':' + json_escape(v));
		}
	}

	http.prepare_content('application/json');

	let ramp = read_ramp();
	let remain = 0;
	if ((ramp.active ?? 0) == 1 && (ramp.dur ?? 0) > 0) {
		remain = (ramp.start ?? 0) + ramp.dur - (ramp.now ?? 0);
		if (remain < 0)
			remain = 0;
	}

	// 浮点保留 1 位小数：手动实现（ucode sprintf 不一定可用）
	function fmt1(x) {
		let n = +x;
		let s = '' + (int(n * 10 + 0.5) / 10);
		let dot = index(s, '.');
		if (dot < 0)
			return s + '.0';
		return s;
	}
	let time_now = trim(shell_out('date "+%H:%M"'));

	http.write(
		'{' +
		'"history":' + json_escape(history) + ',' +
		'"now":{"temp":' + fmt1(temp) +
		    ',"pwm":' + pwm +
		    ',"rpm":' + rpm +
		    ',"ramp_active":' + (ramp.active ?? 0) +
		    ',"ramp_from":' + (ramp.from ?? 0) +
		    ',"ramp_to":' + (ramp.to ?? 0) +
		    ',"ramp_dur":' + fmt1(ramp.dur ?? 0) +
		    ',"ramp_remain":' + fmt1(remain) +
		    ',"tz_mode":' + json_escape(tz_mode) +
		    ',"tz_policy":' + json_escape(tz_policy) +
		    ',"time":' + json_escape(time_now) + '},' +
		'"service":{"pid":' + json_escape(pid) +
		    ',"autostart":' + (autostart == '1' ? 'true' : 'false') + '},' +
		'"config":{' + join(',', cp) + '}' +
		'}'
	);
}

function action_save() {
	// 鉴权说明：本节点挂在 admin 下，LuCI dispatcher 已用 sauth 强制要求登录会话，
	// 未登录请求根本到不了这里。

	// 【重要】不用 uci cursor 落盘：uhttpd 长驻进程，cursor 会缓存配置快照，
	// 第二次以后的请求拿到的是被污染的旧缓存，写入会被跳过。
	// 改用 uci 命令行：每次 fork 独立进程、无缓存，写入必定落盘。

	let seen = [];
	let seenkeys = ['mode','manual_speed','auto_temp_low','auto_temp_mid','auto_temp_high',
	                'auto_pwm_low','auto_pwm_mid','auto_pwm_high',
	                'min_temp','max_temp','min_speed','max_speed',
	                'night_enabled','night_start','night_end','night_speed',
	                'guard_enabled','guard_temp','guard_exit','guard_speed','ramp_up',
	                'temp_smooth'];
	// 诊断用：把任何异常都返回给调用方，避免只看到 500 空白页
	try {

	for (let i = 0; i < length(seenkeys); i++) {
		let k = seenkeys[i];
		let v = field(k);
		push(seen, k + '=' + (v == null ? '-' : replace(v, /[^0-9a-zA-Z_.:-]/g, '?')));
	}

	slog('SAVE ' + join(' ', seen));

	let applied = 0;
	let failed = [];

	let mode = field('mode');
	if (mode == 'system' || mode == 'auto' || mode == 'auto_curve' || mode == 'manual') {
		if (uci_set('mode', mode))
			applied++;
		else
			push(failed, 'mode');
	}

	let specs = [
		['manual_speed', 0, 255, 128],
		['auto_temp_low', 20, 100, 50],
		['auto_temp_mid', 20, 110, 60],
		['auto_temp_high', 30, 120, 75],
		['auto_pwm_low', 0, 255, 50],
		['auto_pwm_mid', 0, 255, 128],
		['auto_pwm_high', 0, 255, 255],
		['min_temp', 20, 100, 40],
		['max_temp', 30, 110, 70],
		['min_speed', 0, 255, 50],
		['max_speed', 0, 255, 255],
		['night_speed', 0, 255, 0],
		['guard_temp', 40, 120, 90],
		['guard_exit', 30, 120, 80],
		['guard_speed', 0, 255, 178],
		['ramp_up', 0, 120, 30],
		// 控制温度平滑窗口（秒）。0 = 关闭平滑。
		// 传感器噪声约 ±1.9°C，经曲线增益放大后会让目标每秒都变，0 会退化成抽搐。
		['temp_smooth', 0, 60, 5]
	];
	for (let i = 0; i < length(specs); i++) {
		let s = specs[i];
		let v = field(s[0]);
		if (v != null) {
			if (uci_set(s[0], num(v, s[1], s[2], s[3])))
				applied++;
			else
				push(failed, s[0]);
		}
	}

	// 时间窗（HH:MM，24 小时制）
	let timekeys = ['night_start', 'night_end'];
	for (let i = 0; i < length(timekeys); i++) {
		let k = timekeys[i];
		let v = field(k);
		if (v != null) {
			let m = match(v, /^(\d{1,2}):(\d{2})$/);
			if (m) {
				let h = +m[1];
				let min = +m[2];
				if (h < 24 && min < 60) {
					let h_str = (h < 10 ? '0' : '') + h;
					let min_str = (min < 10 ? '0' : '') + min;
					if (uci_set(k, h_str + ':' + min_str))
						applied++;
					else
						push(failed, k);
				}
			}
		}
	}


	// 开关
	let swkeys = ['night_enabled', 'guard_enabled'];
	for (let i = 0; i < length(swkeys); i++) {
		let k = swkeys[i];
		let v = field(k);
		if (v == '1' || v == '0') {
			if (uci_set(k, v))
				applied++;
			else
				push(failed, k);
		}
	}

	// 一次性提交（同样走命令行，避免 cursor 缓存）
	let rc = shell_rc(`uci commit ${CONFIG} >/dev/null 2>&1`);
	let committed = (rc == 0);

	// 跨字段校验：退出温度必须低于守护温度。
	// 反序时（exit >= temp）温度落在 [temp, exit] 区间会出现永久闭锁死区 ——
	// 触发条件成立后，退出条件也成立，但 elif 分支不会被求值，于是风扇卡在
	// 守护转速退不出来。这里只警告、不擅自改写用户设置；真正的兜底在
	// fancontrol-loop 里：它会把 exit 夹到「guard_temp − 1」，保证必然存在退出点。
	let gtmp = +uci_get('guard_temp');
	let gexit = +uci_get('guard_exit');
	let warn = '';
	if (gtmp == gtmp && gexit == gexit && gexit >= gtmp) {
		warn = 'guard_exit>=guard_temp';
		slog(`WARN guard order invalid: guard_temp=${gtmp} guard_exit=${gexit} (daemon will clamp exit to ${gtmp - 1})`);
	}

	let verifykeys = ['mode', 'manual_speed', 'guard_temp', 'guard_exit', 'guard_speed',
	                 'night_enabled', 'night_speed', 'ramp_up'];
	let verify = [];
	for (let i = 0; i < length(verifykeys); i++) {
		let k = verifykeys[i];
		push(verify, json_escape(k) + ':' + json_escape(uci_get(k)));
	}

	slog(`SAVE-DONE applied=${applied} failed=${(length(failed) == 0 ? 'none' : join(',', failed))} committed=${committed} mode=${uci_get('mode')} manual_speed=${uci_get('manual_speed')}`);

	// 唤醒守护进程立刻重跑一轮，实现「保存后立即生效」
	shell_rc('touch /tmp/fancontrol_reload >/dev/null 2>&1');

	// 仅在显式要求时重启服务（会清空历史曲线）
	if (http.formvalue('restart') == '1') {
		shell_rc('/etc/init.d/fancontrol restart >/dev/null 2>&1');
	}

	http.prepare_content('application/json');
	http.write(
		'{"status":"' + (committed ? 'ok' : 'commit_failed') +
		'","applied":' + applied +
		',"failed":' + json_escape(join(',', failed)) +
		',"warn":' + json_escape(warn) +
		',"config":{' + join(',', verify) + '}}'
	);
	}
	catch (e) {
		http.prepare_content('application/json');
		http.write('{"status":"exception","msg":' + json_escape('' + e) +
		           '}');
	}
}

// 渲染首页模板。
// 【坑】菜单里不能用 "type":"template" —— dispatcher 那边传的 scope 是空 {}，
// 而 header.ut / footer.ut 需要 theme、resource、media、ctx、config 等变量，
// 空 scope 会让 include(`themes/${theme}/header`) 抛
// "left-hand side is not a function"。
// 改用 "type":"function" 走 render_action，dispatcher 会把 runtime.env
// （含全部模板全局）作为第一个参数传进来，scope 才完整。
function action_index(env) {
	// 【坑】模板渲染的 include 由 runtime 注入到 env 上：
	// runtime.uc:183 `self.env.include = (...args) => self.render_any(...args)`
	// 必须用 env.include；ucode 另有一个内置的全局 include（模块导入用），
	// 直接写 include(...) 会命中它并抛 "left-hand side is not a function"。
	env.include('fancontrol');
}

return {
	action_index: action_index,
	action_data: action_data,
	action_save: action_save
};
