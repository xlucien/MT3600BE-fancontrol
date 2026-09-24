# Fan Control for GL.iNet GL-MT3600BE

给 **GL.iNet GL-MT3600BE**（MediaTek Filogic，MT7987）做的 LuCI 风扇温控插件。

原厂固件里风扇由内核 thermal governor 接管，手动把 PWM 调到 0 风扇还是会转；这个插件把风扇从内核手里接过来，做成一个能真正停转、能按温度/时间自动调节、并且全过程平滑渐变的完整温控系统。

> 在 **ImmortalWrt 25.12-SNAPSHOT** 上开发并实测。OpenWrt 主线理论上通用，其他 Filogic 机型通常也能跑（硬件路径是自动探测的）。

---

## 截图

### 完整界面

![完整界面](https://raw.githubusercontent.com/xlucien/gl-mt3600be-fan-control/main/screenshots/full-ui.png)

状态卡（温度 / 转速 / PWM / 模式）、会转的风扇图标、温度 / 转速历史双轴曲线、手动 PWM 卡片、参数面板。

### 转速警戒（PWM > 80%）

![彩虹扇叶](https://raw.githubusercontent.com/xlucien/gl-mt3600be-fan-control/main/screenshots/rainbow-blades.png)

手动 PWM 超过 80% 时五片扇叶依次染红 / 橙 / 黄 / 绿 / 蓝，轮毂转深灰；回落自动恢复蓝色。0.5s 平滑过渡，不会闪变。

---

## 功能

| 功能 | 说明 |
|---|---|
| **四种模式** | `system` 交还内核 / `auto` 三档温控 / `auto_curve` 线性曲线 / `manual` 固定占空比 |
| **真正停转** | 手动 0% 就是 0%，不会被内核重新拉起 |
| **平滑渐入** | 转速变化不跳变。时长按改动幅度折算——小改一两秒到位，满档才用满设定值 |
| **夜间静音** | 指定时间窗（支持跨天，如 23:00 → 07:00）内固定用夜间转速 |
| **温度守护** | 升到守护温度强制散热，降到退出温度才交还常规。带回差，避免在阈值附近抖动 |
| **转速警戒** | 手动 PWM > 80% 时扇叶变彩虹色，一眼看出"我已经拉到很高了" |
| **网页控制台** | GL.iNet 风格界面，会转的风扇图标，转速变化无跳变；温度/转速/PWM 实时曲线，参数改动即时保存 |
| **中文界面** | 全中文，用户只看百分比，不接触 0-255 原始值 |

### 优先级

```
温度守护  >  夜间静音  >  常规模式（auto / auto_curve / manual）
```

`system` 模式下插件不干预，全部交还内核。

也就是：夜间风扇很安静，但**只要温度冲到守护温度，立刻强制散热**；等降回退出温度，又自动回到夜间静音。

---

## 界面

- **状态卡**：温度 / 转速 / PWM / 模式，四格实时读数
- **风扇图标**：运转时按 PWM 比例旋转（无跳变平滑）；手动 PWM > 80% 时变彩虹色
- **温度 / 转速历史**：双轴曲线，PWM 用虚线叠加
- **手动 PWM**：停转 0% / 静音 30% / 中速 50% / 全速 100% 四个快捷档（圆角钢琴键）
- **参数面板**：温控曲线、夜间模式、温度守护分组，数值可直接键入

渐入进行时，PWM 格内会显示进度条与剩余秒数，顶部状态栏同步显示「渐入 xx% → yy%」。

---

## 安装

### 方式一：直接拷贝（最简单）

把 `root/` 下的文件按目录结构拷到路由器：

```sh
scp -r root/* root@192.168.1.1:/
ssh root@192.168.1.1
chmod +x /usr/libexec/fancontrol-loop
/etc/init.d/fancontrol enable
/etc/init.d/fancontrol start
```

然后清一下 LuCI 缓存，刷新页面：

```sh
rm -f /tmp/luci-modulecache/* /tmp/luci-indexcache
```

### 方式二：编译 ipk

把 `luci-app-fancontrol/` 放进 OpenWrt/ImmortalWrt SDK 的 `package/` 目录：

```sh
make package/luci-app-fancontrol/compile V=s
```

产物在 `bin/packages/*/base/luci-app-fancontrol_*.ipk`。

---

## 配置项

配置文件 `/etc/config/fancontrol`，也可以直接在网页里改。

| 项 | 默认 | 说明 |
|---|---|---|
| `enabled` | `1` | 总开关 |
| `temp_source` | 空 | CPU 温度路径。留空自动探测 |
| `pwm_control` | 空 | PWM 路径。留空自动探测 |
| `pwm_enable` | 空 | PWM 使能路径。留空自动探测 |
| `interval` | `1` | 采样间隔（秒） |
| `mode` | `auto` | `system` / `auto` / `auto_curve` / `manual` |
| `manual_speed` | `128` | 手动模式占空比（0-255） |
| `auto_temp_low/mid/high` | `50/60/75` | auto 模式三档温度阈值 |
| `auto_pwm_low/mid/high` | `50/128/255` | auto 模式三档占空比 |
| `min_temp` / `max_temp` | `40` / `70` | auto_curve 曲线端点温度 |
| `min_speed` / `max_speed` | `50` / `255` | auto_curve 曲线端点占空比 |
| `night_enabled` | `0` | 夜间模式开关 |
| `night_start` / `night_end` | `23:00` / `07:00` | 夜间窗口，支持跨天 |
| `night_speed` | `0` | 夜间固定占空比 |
| `guard_enabled` | `1` | 温度守护开关 |
| `guard_temp` | `90` | 触发守护的温度（℃） |
| `guard_exit` | `80` | 退出守护的温度（℃），必须低于 `guard_temp` |
| `guard_speed` | `178` | 守护期间占空比 |
| `ramp_up` | `30` | 渐入最长时间（秒），`0` 关闭渐变 |
| `history_size` | `60` | 历史保留条数 |

---

## 工作原理

### 接管风扇

内核的 thermal `step_wise` governor 会周期性改写 pwm-fan 的 cooling state，和插件抢风扇——这就是「手动调到 0 风扇还在转」的根因。

插件接管时做三件事：

1. `thermal_zone*/mode` 置 `disabled`，停掉内核轮询
2. 所有 cooling device 的 policy 设为 `user_space`
3. `pwm1_enable` 写 `1`（手动模式）

`system` 模式则全部还原：`mode=enabled`、policy `step_wise`、`pwm1_enable` 写 `2`。

### 渐入按幅度折算

固定时长会让 10% 的小改动也磨满 30 秒，观感很差。实际时长按占空比量程折算：

```
时长 = ramp_up × |Δ| / 255        再夹在 [ramp_up/8, ramp_up]，硬底 2 秒
```

所以：改 10% 约 1/8 时长，改满档才用满。插值按「已流逝秒数」线性计算，不依赖小数 sleep。

### 采样与刷新的分工

这台固件的 busybox 把所有亚秒等待都裁掉了——`sleep 0.25` 报 `invalid number`、`read -t 0.25` 报 `invalid timeout`、没有 `usleep` applet。忙等硬凑 250ms 实测吃 4 个 jiffy（约 16% 单核），不划算。

所以拆成两层：

- **守护进程**：整数秒节拍（`interval`，默认 1 秒），负责写 PWM
- **页面**：稳态跟随 `interval`，**「保存 → PWM 到位」期间提速到 250ms**

进度条的流畅度不靠采样频率，而是守护进程把渐入的起止时刻与总时长落盘到 `/tmp/fancontrol_ramp`，页面按服务端快照插值绘制。这样即使 PWM 一秒才跳一档，进度条仍是 250ms 一帧。

### 温度守护的回差

触发用 `guard_temp`，退出用 `guard_exit`，中间是回差区间。温度在区间内时保持当前状态，不会因为几个小数点的波动反复切换——CPU 温度一秒内跳 1~2℃ 是常事。

**`guard_exit` 必须低于 `guard_temp`。** 如果配置反序，温度落在 `[guard_temp, guard_exit]` 区间会永久闭锁（触发条件成立后退出条件也成立，但 `elif` 分支不会被求值，风扇卡在守护转速退不出来）。守护进程会自动把 `guard_exit` 夹到 `guard_temp - 1` 兜底，保证必然存在退出点。

### 状态持久化

渐入进度（`cur_speed`）与守护闭锁（`guard_active`）落盘到 `/tmp/fancontrol_state`，进程重启或「保存并生效」触发热重载后能接着跑，不会从 -1 重置导致转速跳变。

---

## 硬件适配

硬件路径全部自动探测，优先读 uci 配置，为空时按顺序找：

- **PWM**：`/sys/class/hwmon/hwmon*/` 里 name 为 `pwmfan`/`pwm-fan`，或含 `fan` 的节点
- **温度**：`thermal_zone*` 里 type 含 `cpu`/`soc`/`tzts` 的节点；WiFi 温度额外支持 `mt76` 的 `mwctl` 查询
- **转速**：`fan1_input`

换机型一般不用改配置。若探测不准，把路径直接写进 uci 即可。

---

## 目录结构

```
luci-app-fancontrol/
├── Makefile
└── root/
    ├── etc/
    │   ├── config/fancontrol          # 默认配置
    │   └── init.d/fancontrol          # procd 启动脚本（带 respawn）
    └── usr/
        ├── lib/lua/luci/
        │   ├── controller/fancontrol.lua   # 控制器：data / save 接口
        │   └── view/fancontrol.htm         # 页面
        └── libexec/fancontrol-loop         # 守护进程（POSIX sh）
```

---

## 已知限制

- **sub-250ms 采样做不到**：固件裁掉了所有亚秒等待手段，忙等代价过高。页面侧的 250ms 快档负责观感，PWM 写入粒度仍是 1 秒。
- **`system` 模式下夜间/守护不生效**：该模式的设计意图就是完全交还内核。
- **`night_speed` 与 `guard_speed` 都填 0 时**，风扇会停转。这是配置意图，不是 bug。

---

## 近期更新

- **页面迁移到 ucode**：controller + 模板全部改为 ucode（`/usr/share/ucode/luci/`），LuCI 主题外壳照常（argon 侧边栏/顶栏）。模板经 `dispatcher` 的 template action 渲染，作用域自带 `include()`/`media`/`resource`/`dispatcher`，但**没有** `url()`——所有地址用 `dispatcher.build_url()` 或写死路径。老 Lua 控制器与视图仍保留作回退
- **手动 PWM 快捷键**：从 5 档（停转 / 超静音 20% / 静音 30% / 中速 50% / 全速 100%）精简为 4 档（停转 0% / 静音 30% / 中速 50% / 全速 100%），键改为统一圆角的钢琴键样式
- **风扇转子 rAF 驱动**：以前靠 CSS `animation-duration` 变速，PWM 改一次角度就跳变；改为 `requestAnimationFrame` 角速度积分后，加减速全程平滑
- **转速警戒配色**：手动 PWM > 80% 时五片扇叶依次染红/橙/黄/绿/蓝（轮毂转深灰），回落自动恢复蓝色。0.5s 平滑过渡，不会闪变
- **扇叶居中修复**：上一版 rAF 改完顺手把旋转写成了 SVG 属性形式，与 CSS `transform-origin` 叠加成三维旋转导致扇叶被甩出。已统一回 CSS transform + `transform-box: view-box`

---

## 许可

MIT
