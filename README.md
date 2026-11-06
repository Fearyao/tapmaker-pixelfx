# tap-pixelfx

[pixelfx](https://patch-gg.github.io/pixelfx/) 的像素特效运行时，UrhoX / TapMaker 工程直接可用。
特效是**纯代码画出来的**（不是序列图），图集在包内随包发，导入即播，不需要预烘焙、不需要改配置。

## 安装（一步）

把整个 `tap-pixelfx/` 目录拷进工程的 `scripts/` 下：

```bash
cp -R tap-pixelfx <你的工程>/scripts/
```

然后在代码里：

```lua
local Pixelfx = require("tap-pixelfx")     -- 加载即完成注册，没有额外初始化
```

**依赖**：只有 `scripts/urhox-libs/`（Maker 工程默认就有）。包本身不依赖任何第三方库、不需要网络、不需要构建工具。

## 作为共享库维护（推荐）

这个目录可以独立成一个仓库，多个工程都从它拷入：

```
~/game/tap-pixelfx/            ← 源（独立 git 仓库，只在这里改）
<工程>/scripts/tap-pixelfx/    ← 各工程的副本，不要手改
```

同步进一个工程：

```bash
~/game/tap-pixelfx/install.sh <工程根目录>
```

工程侧想改手感（缩放、默认淡出、用哪个特效）不要改副本，用调用参数：
`layer:Spawn(id, x, y, { scale = ..., fade = ... })`，或改业务层自己的映射表。
副本与源不一致时，以源为准重新同步。

`.meta` 不进共享库：导入后由工程的 Maker 工具生成（`urhox-libs` 也是这个约定）。

## 用起来

覆盖层挂到任意 UI 容器上（战斗中就是舞台根节点），之后 `Spawn` 即可：

```lua
local ImplosionStage = require("urhox-libs/UI/Core/Widget")   -- 你的舞台组件

local layer = Pixelfx.newLayer(stageWidget, { maxLive = 48 })

-- 命中
layer:Spawn(Pixelfx.presets.HIT, x, y, { angle = 0.3 })

-- 暴击（同一套代码，换 id）
layer:Spawn(Pixelfx.presets.CRIT, x, y, { scale = 0.7 })

-- 换色板：自动走运行期烘焙（第一次略慢，之后有缓存）
layer:Spawn(Pixelfx.presets.HIT, x, y, { palette = { "#102030", "#40a0ff", "#ffffff" } })

-- 循环特效要自己给存活时间
layer:Spawn(Pixelfx.presets.ARROW, x, y, { life = 0.6, angle = math.atan(vy, vx) })
```

### 坐标

`x, y` 是**父容器的基础像素坐标**，落在特效的 `meta.origin` 上（命中点 / 脚下），特效自己围着这个点画。
不同特效画布大小不同（见下表），但锚点语义一致，所以调用方不需要知道画布尺寸。

### 实例选项

| 选项 | 默认 | 说明 |
|---|---|---|
| `scale` | 该特效的 `DEFAULT_SCALE` | 一个特效像素占多少基础像素；纯显示参数，不触发重烤 |
| `angle` | `0` | 弧度，绕锚点旋转；纯显示参数 |
| `flip` | `false` | 水平镜像；纯显示参数 |
| `alpha` | `1` | 整体透明度 |
| `life` | 帧数 / fps | 存活秒数（循环特效必须给，或用 `loops`） |
| `loops` | `1` | 循环特效播几轮（未给 `life` 时生效） |
| `fade` | `0.14` | 末段淡出秒数 |
| `delay` | `0` | 延后出现秒数（配合“命中火花晚于弹道”这类时序） |
| `palette` / `seed` / `frames` | — | **会改变像素**的选项，触发运行期烘焙（见下） |

`layer` 上还有：`Count()` / `Stats()` / `Clear()` / `enabled_`。

## 已包含的特效

| id | 画布 | 帧数 | 类型 | 默认缩放 |
|---|---|---|---|---|
| `impacts/hit-spark` | 136×80 | 16 | one-shot 0.53s | 0.55 |
| `impacts/crit-hit` | 216×136 | 28 | one-shot 0.93s | 0.5 |
| `melee/sword-slash` | 136×104 | 24 | one-shot 0.8s | 0.55 |
| `projectiles/arrow` | 112×32 | 18 | **loop** 0.6s | 0.5 |
| `holy/heal` | 80×104 | 58 | one-shot 1.93s | 0.7 |
| `spawn/poof` | 112×92 | 49 | one-shot 1.63s | 0.6 |
| `explosions/small-explosion` | 300×240 | 45（裁自 163） | one-shot 1.5s | 0.42 |
| `ui/damage-number` | 76×68 | 33 | one-shot 1.1s | 0.9 |

`presets` 里的语义别名：`HIT` / `CRIT` / `SLASH` / `ARROW` / `HEAL` / `DEATH` / `SPLASH` / `DAMAGE_NUMBER`。

> `ui/damage-number` 的文字是**烘焙时固定**的（原版 options.text，默认 `-27`），
> 所以它适合“固定文案的伤害/暴击提示”，不适合每一下都显示真实数字。
> 要显示真实数值，正解是“烤无字底板 + 现场用 `core/Font.lua` 排数字”。

## 两条出图路线

| 路线 | 什么时候走 | 成本 |
|---|---|---|
| **随包图集**（`atlas/**`，PNG + JSON） | 默认，参数是默认值时 | 运行期 0 烘焙；每帧只是 NanoVG image pattern |
| **运行期烘焙**（`runtime/Bake.lua`） | 传了 `palette` / `seed` / `frames` | 按画布面积计费，有每帧预算 + 缓存 |

运行期烘焙的成本（本机 headless 实测，每帧均摊）：arrow 0.8 ms、hit-spark 2.7 ms、
sword-slash 5.7 ms、crit-hit 12.2 ms、small-explosion 整份约 2 s。所以**热路径特效请用随包图集**，
需要换色的地方尽量提前定好色板、开机预热（`Pixelfx.flush(ms)`）。

## 自检与验收

```bash
# 运行期接线（图集 / 覆盖层 / spawn / 渲染 / 烘焙兜底）
./.cli/UrhoXRuntime scripts/tap-pixelfx/dev/FxRuntimeCheck.lua -tapcode_dir="$PWD" -tool_mode \
    -graphicsheadless -validate -validate-frames=2 -validate-timeout=180 -log info

# 逐像素对拍（需要 pixelfx 原版仓库；Lua↔JS 必须 MATCH 才能收）
node scripts/tap-pixelfx/dev/harness/dump-js.mjs  impacts/hit-spark .tmp/pxref/HitSpark
node scripts/tap-pixelfx/dev/harness/dump-lua.mjs HitSpark            .tmp/pxlua/HitSpark
node scripts/tap-pixelfx/dev/harness/compare.mjs  .tmp/pxref/HitSpark .tmp/pxlua/HitSpark

# 随包图集 vs JS 原版参考帧
python3 scripts/tap-pixelfx/dev/harness/compare-sheet.py --all .tmp/pxref
```

## 加一个新特效

见 [PORTING.md](PORTING.md)：读原版 JS → 照抄 `meta` → 写 `effects/<Name>.lua` →
对拍必须 `MATCH` → `dev/ExportSheets.lua` 重烤图集 → `runtime/Registry.lua` 注册两行。

`dev/harness` 里的对拍台其实就是这套流程的自动化：它用 wasmoon（Lua 5.4 WASM）跑移植版，
和 pixelfx 原版（node 跑 ESM）逐帧比 RGBA。

## 已知限制

- **只覆盖 NanoVG/UI 渲染**。要在 3D 世界里当公告板贴（俯视/跟随相机的场景），需要另写一个
  用 `CustomGeometry` + `UV` 的适配层，本包不提供。
- **`act` / `rig` 没搬**（角色骨骼 + 动作时间轴）。pixelfx 的 `moves/*` 那类“角色起手—命中—收招”
  的整段动画依赖它们，本包不含。
- **图集与代码是两份truth**：改了 `effects/*.lua` 的绘制逻辑必须重跑 `dev/ExportSheets.lua`，
  否则随包图集和源码静默不一致（对拍台 + `compare-sheet.py` 就是为了拦住这件事）。
- 缩放基准按 32×48 的美术像素角色估的；换项目请按自己的单位尺寸调 `Registry.DEFAULT_SCALE`。
