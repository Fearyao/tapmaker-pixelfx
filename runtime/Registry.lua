-- ============================================================================
-- tap-pixelfx/runtime/Registry.lua — 已移植特效的注册表
--
-- 三条约定：
--   1. **id 和 pixelfx 的目录名保持一致**（"impacts/hit-spark"），回头查原版、
--      重导参考帧都能直接对上。
--   2. `Registry.presets` 那组语义别名（HIT / CRIT / …）是给调用方用的便利映射：
--      写 `Pixelfx.presets.HIT`，想换特效只改这里一行。
--   3. DEFAULT_SCALE 是「一个特效像素占多少基础像素」。参考基准是 32×48 的美术像素
--      角色（1.2 倍后 38×58 基础像素），pixelfx 的画布按 48 高的角色设计，
--      所以默认值在 0.42~0.9。换项目调手感只改这张表，不用碰特效代码。
-- ============================================================================

local Bake = require "tap-pixelfx.runtime.Bake"

local Arrow = require "tap-pixelfx.effects.Arrow"
local CritHit = require "tap-pixelfx.effects.CritHit"
local DamageNumber = require "tap-pixelfx.effects.DamageNumber"
local Heal = require "tap-pixelfx.effects.Heal"
local HitSpark = require "tap-pixelfx.effects.HitSpark"
local Poof = require "tap-pixelfx.effects.Poof"
local SmallExplosion = require "tap-pixelfx.effects.SmallExplosion"
local SwordSlash = require "tap-pixelfx.effects.SwordSlash"

local Registry = {}

-- ---- 特效 id（= pixelfx 的 src/fx/<category>/<name>.js） ----
Registry.HIT = "impacts/hit-spark"                -- 普通命中
Registry.CRIT = "impacts/crit-hit"                -- 暴击命中
Registry.SLASH = "melee/sword-slash"              -- 近战挥砍
Registry.ARROW = "projectiles/arrow"              -- 飞行中的箭（循环）
Registry.HEAL = "holy/heal"                       -- 治疗
Registry.DEATH = "spawn/poof"                     -- 死亡烟团
Registry.SPLASH = "explosions/small-explosion"    -- 溅射 / 死亡爆炸
Registry.DAMAGE_NUMBER = "ui/damage-number"       -- 伤害数字（已移植，未接战斗）

--- 语义别名表（调用方直接 `Pixelfx.presets.HIT`）
---@type table<string, string>
Registry.presets = {
    HIT = Registry.HIT,
    CRIT = Registry.CRIT,
    SLASH = Registry.SLASH,
    ARROW = Registry.ARROW,
    HEAL = Registry.HEAL,
    DEATH = Registry.DEATH,
    SPLASH = Registry.SPLASH,
    DAMAGE_NUMBER = Registry.DAMAGE_NUMBER,
}

--- 每个特效的默认显示缩放（特效像素 → 基础像素）
--- 基准：32×48 的美术像素角色（1.2 倍后 38×58 基础像素）
Registry.DEFAULT_SCALE = {
    [Registry.HIT] = 0.55,
    [Registry.CRIT] = 0.5,
    [Registry.SLASH] = 0.55,
    [Registry.ARROW] = 0.5,
    [Registry.HEAL] = 0.7,
    [Registry.DEATH] = 0.6,
    [Registry.SPLASH] = 0.42,
    [Registry.DAMAGE_NUMBER] = 0.9,
}

--- 构建期烤好、随包发的图集（tap-pixelfx/atlas/**，位于 scripts/ 资源目录下）。
--- 有 sheet 的特效运行期零烘焙成本；调用方一旦传了 palette/seed/frames，
--- 播放器会自动退回运行期烘焙（见 fx.Px.resolveSource）。
--- 生成命令：`.cli/UrhoXRuntime scripts/tap-pixelfx/dev/ExportSheets.lua ...`（见 PORTING.md）
---@type table<string, { json: string }>
Registry.SHEETS = {
    [Registry.HIT] = { json = "tap-pixelfx/atlas/impacts/hit-spark.json" },
    [Registry.CRIT] = { json = "tap-pixelfx/atlas/impacts/crit-hit.json" },
    [Registry.SLASH] = { json = "tap-pixelfx/atlas/melee/sword-slash.json" },
    [Registry.ARROW] = { json = "tap-pixelfx/atlas/projectiles/arrow.json" },
    [Registry.HEAL] = { json = "tap-pixelfx/atlas/holy/heal.json" },
    [Registry.DEATH] = { json = "tap-pixelfx/atlas/spawn/poof.json" },
    -- 原作是 5.4 秒的地面爆炸（163 帧）；战斗里只需要「炸开」那一下，
    -- 所以烤前 45 帧（1.5 秒）——再往后是余烬和焦痕，玩起来根本看不到。
    [Registry.SPLASH] = { json = "tap-pixelfx/atlas/explosions/small-explosion.json", opts = { frames = 45 } },
    [Registry.DAMAGE_NUMBER] = { json = "tap-pixelfx/atlas/ui/damage-number.json" },
}

--- 开局预热的条目：只列**没有**构建期 sheet 的特效（有 sheet 的不必预热）。
--- opts 必须和运行时用的一致，否则缓存键不同会白烤一份。
---@type (string|table)[]
Registry.PREWARM = {}

local registered_ = false

--- 把已移植的特效登记进 Bake（幂等；init.lua 加载时已经调过）
function Registry.register()
    if registered_ then
        return
    end
    registered_ = true
    Bake.register(Registry.HIT, Bake.instSpec(HitSpark.meta, HitSpark))
    Bake.register(Registry.CRIT, Bake.instSpec(CritHit.meta, CritHit))
    Bake.register(Registry.SLASH, Bake.instSpec(SwordSlash.meta, SwordSlash))
    Bake.register(Registry.ARROW, Bake.pureSpec(Arrow.meta, Arrow))
    Bake.register(Registry.HEAL, Bake.instSpec(Heal.meta, Heal))
    Bake.register(Registry.DEATH, Bake.instSpec(Poof.meta, Poof))
    Bake.register(Registry.SPLASH, Bake.instSpec(SmallExplosion.meta, SmallExplosion))
    Bake.register(Registry.DAMAGE_NUMBER, Bake.instSpec(DamageNumber.meta, DamageNumber))
end

--- 已注册（= 已移植）的特效 id
---@return string[]
function Registry.ids()
    return Bake.ids()
end

--- 某个特效的元信息（没注册返回 nil）
---@param id string
---@return table|nil
function Registry.meta(id)
    return Bake.meta(id)
end

return Registry
