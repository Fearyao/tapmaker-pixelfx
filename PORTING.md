# pixelfx → Lua 移植与验收

本包把 [pixelfx](https://patch-gg.github.io/pixelfx/)（244 个纯代码像素特效，ESM/JS）的
**运行能力**搬到 Lua 5.4：特效不是序列图，而是每帧算出来的像素，所以色板 / 种子 / 尺寸都能
在运行期决定（也可以按你的节奏预烤成图集）。

移植的验收标准只有一条：**和 JS 原版逐像素一致**。本包里的每个特效都跑过对拍。

## 目录

| 文件 | 对应 pixelfx | 说明 |
|---|---|---|
| `core/Core.lua` | `src/core/{color,painter,fx}.js` | 颜色打包、Painter（put/add/dot/blend/blendPx/each/shade/line/circle/ellipse/disc/ring/arc/beam/rect/poly/tri/glow/glowLine/glowRing/sprite/text/mask/outline）、frame + composite |
| `core/Font.lua` | `src/core/font.js` | mini（3×5）/ big（5×7）像素字 + textWidth + rasterText |
| `core/Math.lua` | `src/core/{math,particles}.js` | `hash` / `Rng`(mulberry32) / `rand` / `noise` / `noise2` / `fbm` / `tileNoise` / `tileFbm` / `loopNoise` / `ease` / `fly` / `burst` / `cycle` / `stream` |
| `core/Sim.lua` | `src/core/sim.js` | `Particles` / `Blazes` / `Bits` / `Lights` + `sparkle` / `flare` / `band` / `crystal` + `FIRE_RAMP` / `SMOKE_RAMP` |
| `core/Shapes.lua` | `src/core/shapes.js` | `bolt` / `forks` / `star` / `ngon` / `trail` |
| `core/Grid.lua` | `src/fx/critters/_lib.js` 的 `Grid`/`shift` + 描边/封顶 | 网格化像素块（等距/像素块类特效用） |
| `runtime/Bake.lua` | — | 运行期烘焙：把特效按帧烤进一张 `Texture2D` 图集（带预算、带缓存） |
| `runtime/Sheets.lua` | — | 随包图集（`atlas/**` + JSON 描述符）的读取 |
| `runtime/Layer.lua` | — | 播放器：`layer:Spawn(id, x, y, opts)`，逐帧只改 image pattern |
| `runtime/Registry.lua` | — | 注册表（id → 烘焙规格 / 语义别名 / 默认缩放 / 图集路径） |
| `init.lua` | — | 包入口：`require("tap-pixelfx")`，加载即注册 |
| `atlas/**` | — | 构建期烤好的图集（PNG + JSON），随包发 |
| `dev/*.lua` | — | 验收台：运行期自检、表现层自检、图集导出 |
| `dev/harness/*` | — | 对拍台：node 跑 JS 原版 + wasmoon 跑 Lua 版，逐帧比 RGBA |
| `effects/*.lua` | `src/fx/<category>/<name>.js` | 一个特效一个文件 |

没搬：`act.js` / `rig.js`（角色骨骼动作）、`scene.js`（背景板）。需要时按原文件补。

## 两条出图路线

| 路线 | 谁在用 | 成本 |
|---|---|---|
| **随包图集** `dev/ExportSheets.lua` + `runtime/Layer` | 默认全部走这条：`atlas/**` 里 PNG + JSON 随包发 | 运行期零烘焙，只有一次 `nvgCreateImage` |
| **运行期烘焙** `Bake.lua` | 调用方改色板/种子/帧数时自动退回（缓存键不同） | 按画布面积计费，见下面的成本表 |

判断标准：**形态固定**的特效进构建期图集；需要「同一份代码多个配色/形态」的，要么提前把
几个配色都烤成图集（推荐），要么接受运行期烘焙的启动成本。

两条路线在播放器里是同一个实例结构，所以调用方不需要关心用的哪条。

## 加一个特效（完整流程）

### 1. 读原版

```bash
PIXELFX=~/game/pixelfx          # pixelfx 仓库
cat $PIXELFX/src/fx/impacts/crit-hit.js
grep -n "export function" $PIXELFX/src/fx/impacts/_lib.js    # 只搬用得到的那几个
```

原版有两种写法，移植后保持同样的形态：

- **纯函数**：`export function draw(p, t, o)`（可选 `drawBack`）。Lua 侧同样导出
  `M.draw(p, t, opts)` / `M.drawBack`。
- **有状态**：`export function create(o)` 返回 `{ update(dt, o), draw(p, t, o) }`。Lua 侧导出
  `M.new(opts)` 返回带 `:update(dt)` / `:draw(p)` 的实例。

### 2. 照抄 meta

`meta` 必须**逐字段照抄**（`size` / `origin` / `duration` / `loop` / `fps` / `options`）。
对拍台和烘焙都靠它算帧数、摆放原点，抄错就永远对不上。

### 3. 写 `scripts/tap-pixelfx/effects/<Name>.lua`

```lua
-- ============================================================================
-- fx/effects/CritHit.lua — impacts/crit-hit 的 Lua 版
-- 原版：pixelfx src/fx/impacts/crit-hit.js
-- （一句话说明这个特效长什么样、游戏里什么时候放）
-- ============================================================================

local Core = require "fx.Core"
local MathX = require "fx.Math"
local Sim = require "fx.Sim"

local CritHit = {}

local floor, ceil, sqrt, sin, cos, abs, min, max, pi = math.floor, math.ceil, math.sqrt,
    math.sin, math.cos, math.abs, math.min, math.max, math.pi

CritHit.meta = {
    name = "Critical hit",
    size = { 216, 136 },
    origin = { 108, 88 },
    duration = 0.9,
    loop = false,
    fps = 30,
    options = { palette = { ... }, seed = 3 },
}

function CritHit.new(opts) ... end
function CritHit:update(dt) ... end
function CritHit:draw(p) ... end

return CritHit
```

约定：

- `require` 只用 `fx.*`（`fx.Core` / `fx.Math` / `fx.Sim` / `fx.Shapes` / `fx.Grid`）。
  特效私有的小工具放同目录的 `<Name>Lib.lua`，不要去改 Core/Sim 这些共享文件。
- 颜色用 `Core.hex("#aabbcc")` 或 `Core.ramp({...})` 转；`opts.palette` 一律走
  `Core.fit(opts.palette, N)`（N = 原版 `fit(o.palette, N)` 里的 N）。
- 有状态特效的 `update` 必须和 `createFx` 一致地细分 dt：

  ```lua
  function X:update(dt)
      self.t = self.t + dt
      local n = max(1, ceil(dt * 120 - 1e-9))
      for _ = 1, n do self.ps:update(dt / n) end   -- 粒子/物理每步走 dt/n
      self.lights:update(dt)                        -- 灯光按整帧走
  end
  ```

  原版里 `impl.update(dt/n)` 拿到的是细分后的 dt，`Lights:update` 也常按整帧写；照原文件来。

### 4. 用起来

```lua
-- 新特效加进去只要两行：
--   runtime/Registry.lua：加 id 常量 + DEFAULT_SCALE + SHEETS + Bake.register
--   业务代码：在对应事件里 layer:Spawn(id, x, y, { ... })
local Pixelfx = require("tap-pixelfx")
local layer = Pixelfx.newLayer(stageWidget)      -- 挂一个覆盖层
local e = layer:Spawn(Pixelfx.presets.HIT, x, y, {
    scale = 0.55,     -- 一个特效像素占多少基础像素（默认取 Effects.DEFAULT_SCALE）
    angle = 0.4,      -- 弧度，画的时候转
    flip = false,
    life = 0.5,       -- 存活秒数（默认 = 帧数/fps）
    fade = 0.1,       -- 末段淡出
    delay = 0.06,     -- 延后出现
})
```

坐标是**容器本地的基础像素**：`x, y` 落在特效的 `meta.origin` 上（命中点 / 脚下），
特效自己围着它画。

### 5. 烤图集（构建期）

```bash
./.cli/UrhoXRuntime scripts/tap-pixelfx/dev/ExportSheets.lua -tapcode_dir="$PWD" -tool_mode \
    -graphicsheadless -validate -validate-frames=2 -validate-timeout=600 -log info
```

改了任何一个 `effects/*.lua` 的绘制逻辑都要重跑一次。只改缩放/淡入淡出不用重跑。

### 6. 对拍验收

```bash
# JS 参考帧（PIXELFX_DIR 默认 /Users/wyy19940108/game/pixelfx）
node scripts/tap-pixelfx/dev/harness/dump-js.mjs impacts/crit-hit .tmp/pxref/CritHit

# Lua 版（模块名 = scripts/tap-pixelfx/effects/<Name>.lua）
node scripts/tap-pixelfx/dev/harness/dump-lua.mjs CritHit .tmp/pxlua/CritHit

# 逐像素比
node scripts/tap-pixelfx/dev/harness/compare.mjs .tmp/pxref/CritHit .tmp/pxlua/CritHit
```

输出 `MATCH: N/N frames identical` 才算过。`DIFF` 会打印每帧差异像素数与最大通道差。

还要再验一遍**真的会进包的那张 PNG**（切格 + 去护边后和 JS 参考帧比）：

```bash
python3 scripts/tap-pixelfx/dev/harness/compare-sheet.py --all .tmp/pxref
```

### 7. 运行期自检

```bash
# 注册表 / 图集描述符 / 覆盖层 / spawn / 渲染调用 / 运行期烘焙兜底
./.cli/UrhoXRuntime scripts/tap-pixelfx/dev/FxRuntimeCheck.lua -tapcode_dir="$PWD" -tool_mode \
    -graphicsheadless -validate -validate-frames=2 -validate-timeout=180 -log info

# 表现层接线：假舞台 + 假单位，把命中/暴击/刀光/治疗/死亡/溅射/投射物走一遍
./.cli/UrhoXRuntime scripts/tap-pixelfx/dev/BattleFxCheck.lua -tapcode_dir="$PWD" -tool_mode \
    -graphicsheadless -validate -validate-frames=2 -validate-timeout=180 -log info
```

两个脚本都打印 `RESULT=PASS`；引擎 headless 没有像素，所以它们验的是接线和生命周期，
像素由上面的对拍负责。

## 移植踩过的坑（每一条都会让像素对不上）

| 坑 | 说明 |
|---|---|
| **32 位整数语义** | JS 的 `Math.imul` / `>>>` 和 Lua 的 64 位整数不是一回事。`Math.imul(a,b)` = 当有符号 32 位相乘取低 32 位；中间值全程保持无符号 32 位，`>>` 才等价于 `>>>` |
| **`n \| 0` 是向零截断** | JS 的 `ToInt32` 是 trunc，不是 floor。`hash(2.7, -3.9)` 用 floor 会得到完全不同的随机序列 |
| **mulberry32 是变体** | `Math.imul(t ^ (t >>> 7), t \| 61)` —— 注意那个 `t ^`，少了它整条 rng 序列就变味 |
| **实参求值顺序 = RNG 调用顺序** | JS 按实参从左到右求值。顺手把 `R.range(...)` 提到调用前面就会错位，这是最常见的「差 1 px」来源 |
| **Uint8ClampedArray 的取整** | JS 写 RGBA 时是「夹紧 + 四舍六入五取偶」，不是 floor。`Core.u8` 模拟了这条 |
| **Lua 里 `0` 是真值** | 原版所有 `if (!c)` 都要写成 `c == 0`，否则空像素会被当成颜色写进去 |
| **`shade` 回调的返回值** | JS 是 `fn(...) \|\| o.c`（返回 0 也算假值），Lua 侧 `shade` 只把 `nil`/`false` 当「没返回」——回调想跳过就 `return` 空返回 |
| **`Math.hypot` 不存在** | Lua 5.4 没有 `math.hypot`，写 `sqrt(dx*dx+dy*dy)` |
| **`Math.atan2` 别用** | 引擎里有 `math.atan2`，但 wasmoon（对拍用的 Lua 5.4 VM）没有。统一用 `math.atan(y, x)` |
| **`--sheet` 带 edgeFade** | `tools/render.mjs --sheet` 会把光晕在画布最外 8px 压到 0，拿它对拍会得到「最外一圈全错」的假 bug。用本目录的 `dump-js.mjs` |

## 成本模型（接进游戏前先算一遍）

引擎只有 `Image:SetPixelInt` 一条写像素的路，Lua→C 调用按像素计费：

本机 headless（macOS，UrhoXRuntime 2026-11-02 构建）实测，每帧均摊：

| 特效 | 画布 | 模拟 + 绘制 | 合成 RGBA | 上传纹理 | 合计 | 整份 |
|---|---|---|---|---|---|---|
| `projectiles/arrow` | 112×32 | 0.28 ms | 0.27 ms | 0.22 ms | 0.77 ms | 22 ms / 18 帧 |
| `impacts/hit-spark` | 136×80 | 1.18 ms | 1.04 ms | 0.46 ms | 2.68 ms | 64 ms / 16 帧 |
| `melee/sword-slash` | 136×104 | 3.35 ms | 1.60 ms | 0.79 ms | 5.74 ms | 182 ms / 24 帧 |
| `impacts/crit-hit` | 216×136 | 6.42 ms | 3.54 ms | 2.23 ms | 12.2 ms | 445 ms / 28 帧 |
| `explosions/small-explosion` | 300×240 | — | — | — | — | 1955 ms / 45 帧 |

三条结论：

1. **成本跟着画布面积走**，模拟（Lua 逐像素着色）是大头，合成和上传是次要项。
   `Core.shade` / `Core.composite` / `Bake` 的上传循环都做过内联优化（不再每像素调
   `Core.red`/`u8`），比直译快 30%~40%。
2. **别在运行期每帧现画**，也别在战斗中现烤：整份 0.02~2 秒，会卡。所以默认全部走构建期图集。
3. 需要运行期烘焙时（换色板/种子），把画布大的特效**裁帧**（`opts.frames`）：原作末尾的
   余烬、焦痕在游戏里看不到，`small-explosion` 只烤前 45 帧（1.5 秒）。
