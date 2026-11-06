-- ============================================================================
-- tap-pixelfx — pixelfx 特效运行时（UrhoX / TapMaker 版）
--
-- 一个目录拷进 `scripts/` 就能用：特效图集随包发在 `tap-pixelfx/atlas/**`，
-- 不需要额外拷资源、不需要预先烘焙、不需要改工程配置。
--
-- ```lua
-- local Pixelfx = require("tap-pixelfx")
--
-- local layer = Pixelfx.newLayer(stageWidget, { maxLive = 48 })  -- 挂在战斗舞台根节点
-- layer:Spawn(Pixelfx.presets.HIT, x, y, { angle = 0.3 })        -- 命中火花
-- layer:Spawn(Pixelfx.presets.CRIT, x, y, { scale = 0.7 })       -- 暴击
-- layer:Spawn(Pixelfx.presets.HIT, x, y, { palette = { "#102030", "#40a0ff", "#ffffff" } })
-- ```
--
-- 坐标是**父容器的基础像素**，锚点落在特效的 `meta.origin`（命中点 / 脚下）。
-- 覆盖层 Widget 自带 Update/Render，挂了就不用再管；`props.fx = false` 这类开关由调用方自己实现。
--
-- 模块分工：
--   core/     像素绘制核心（Core / Math / Sim / Shapes / Grid / Font）
--   effects/  已移植的特效，一个特效一个文件
--   runtime/  Bake（运行期烘焙）/ Sheets（图集描述符）/ Layer（播放器）/ Registry（注册表）
--   atlas/    构建期烤好的图集（PNG + JSON），随包发
--   dev/      验收台（对拍、自检、图集导出），运行时用不到
-- ============================================================================

local Bake = require "tap-pixelfx.runtime.Bake"
local Effects = require "tap-pixelfx.runtime.Registry"
local Layer = require "tap-pixelfx.runtime.Layer"
local Sheets = require "tap-pixelfx.runtime.Sheets"

local Pixelfx = {}

Pixelfx.VERSION = "1.0.0"

--- 注册表（特效 id / 默认缩放 / 图集路径 / presets）
Pixelfx.registry = Effects
--- 语义别名：presets.HIT / CRIT / SLASH / ARROW / HEAL / DEATH / SPLASH / DAMAGE_NUMBER
Pixelfx.presets = Effects.presets
--- 播放器类（想自己派生覆盖层时用）
Pixelfx.Layer = Layer

-- 加载即注册：调用方不需要额外的初始化步骤（Register 自身幂等）
Effects.register()

--- 建一个特效覆盖层并挂到 parent 上
---@param parent Widget 任意 UI 容器（战斗舞台根节点即可）
---@param props table|nil { maxLive, zIndex, enabled }
---@return table layer
function Pixelfx.newLayer(parent, props)
    return Layer.new(parent, props)
end

--- 已移植的特效 id 列表
---@return string[]
function Pixelfx.ids()
    return Effects.ids()
end

--- 某个特效的元信息（未移植返回 nil）
---@param id string
---@return table|nil
function Pixelfx.meta(id)
    return Effects.meta(id)
end

--- 某个特效的默认显示缩放
---@param id string
---@return number|nil
function Pixelfx.defaultScale(id)
    return Effects.DEFAULT_SCALE[id]
end

--- 当前是否走「构建期图集」；false 表示这个 id/参数组合需要运行期烘焙
---@param id string
---@return boolean
function Pixelfx.hasAtlas(id)
    local sheet = Effects.SHEETS[id]
    return sheet ~= nil and Sheets.descriptor(sheet.json) ~= nil
end

--- 同步把烘焙队列烤掉（只在需要运行期烘焙时有意义）
---@param maxMs number|nil
---@return integer pending 还有多少帧没烤
function Pixelfx.flush(maxMs)
    return Bake.flush(maxMs)
end

--- 烘焙统计（调试用）
---@return table
function Pixelfx.bakeStats()
    return Bake.stats()
end

return Pixelfx
