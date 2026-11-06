-- ============================================================================
-- view/px/SmallExplosion.lua — explosions/small-explosion 的 Lua 版
--
-- 原版：pixelfx src/fx/explosions/small-explosion.js（粒子配方改写自 Sprite Fusion 的开源
-- explosion，MIT；这份文件里的 stone / scorch / rock 是它自己的私有版本，不是 _lib.js 的）
--
-- 长什么样：一次贴地的爆炸。先是白闪 + 两圈冲击波，火焰往上炸开、烧成一根翻滚的烟柱，
-- 火花四射、烧着的木条甩出去落地继续烧，碎石翻滚弹跳，地面上留下一块发光的烧痕，
-- 最后 1 秒烧痕淡出，整段 5.4 秒。游戏里什么时候放：手雷 / 火药桶 / 爆炸陷阱命中的那一帧，
-- 原点放在炸点的地面上（origin 的 y 已经落在地面线上）。
--
-- 这个特效几乎把 Particles 的所有种类都用上了（FIRE / SMOKE / SPARK / EMBER / BRAND /
-- GRIT / DUST），还叠了 Bits（翻滚的碎石）和 Blazes（落点的小火苗），所以 Rng 的抽取顺序
-- 是最要紧的东西：原版所有 R.range / R.sign / R.pick / R.chance 都按**实参从左到右**的顺序
-- 抽，下面每一处都按原版逐字对齐，改动任何一行的取值顺序都会让整条序列错位。
-- ============================================================================

local Core = require "tap-pixelfx.core.Core"
local MathX = require "tap-pixelfx.core.Math"
local Sim = require "tap-pixelfx.core.Sim"
local Lib = require "tap-pixelfx.effects.SmallExplosionLib"

local SmallExplosion = {}

local floor, ceil, sqrt, sin, cos, abs, min, max, pi = math.floor, math.ceil, math.sqrt, math.sin, math.cos,
    math.abs, math.min, math.max, math.pi
local TAU = pi * 2

local P, PF, B = Sim.P, Sim.PF, Sim.B

--- JS 的 Math.round（这份特效里的取值全是正数，四舍五入到最近整数即可）
local function round(v)
    return floor(v + 0.5)
end

SmallExplosion.meta = {
    name = "Explosion",
    desc = "A ground blast: a white flash and shock rings, fire that cools into a rolling smoke column, sparks, burning brands that land and keep burning, tumbling rocks and a glowing scorch.",
    tags = { "explosion", "fire", "smoke", "debris", "impact", "one-shot" },
    size = { 300, 240 },
    origin = { 150, 196 },
    duration = 5.4,
    loop = false,
    fps = 30,
    bg = "ground",
    options = {
        palette = { "#4a1712", "#c9281f", "#f2561d", "#ff8a2a", "#ffc23d", "#ffe26b", "#fff3a6", "#ffffff" },
        stone = "#4a3f69",
        size = 1,
        seed = 7,
    },
}

--- 地面：原点就摆在脚下，所以整条 y = 0 都是地面
local function ground()
    return 0
end

--- 建一个实例（对齐 create(o)：所有粒子在这一刻一次性排好，之后只做模拟）
function SmallExplosion.new(opts)
    opts = opts or SmallExplosion.meta.options
    local F = Core.fit(opts.palette, 8) -- 8 阶火色带（暗 → 亮）
    local S = opts.size or 1
    local RAD = 18 * S -- 火球半径
    local POWER = 0.9 * S ^ 0.8 -- 爆炸强度：决定粒子的数量和速度
    local EARTH = 1.6 -- 土的量
    local st = Lib.stone(opts.stone or "#4a3f69")
    local R = MathX.newRng(opts.seed or 7)
    local smokeCol = Core.rgb(34, 29, 38) -- 起爆时那口浓烟的颜色（不跟火色带走）

    local blazes
    local ps = Sim.newParticles({
        rng = R,
        ground = ground,
        sparks = { F[7], F[6], F[4], F[3] },
        -- 烧着的木条落地：在那一点起一小簇火
        -- ⚠️ 两次 range 的顺序就是原版实参顺序（先 life 再 power），而且 Blazes:add 里
        -- 还会再抽一次 acc，别把这里改成先算 power。
        onLand = function(x, y)
            local life = R:range(0.9, 1.5)
            local power = R:range(0.55, 0.85)
            blazes:add(x, y - 0.25, life, power)
        end,
    })
    blazes = Sim.newBlazes(ps)
    local rocks = Sim.newBits({ ground = ground })
    local lights = Sim.newLights()
    local flashes, rings = {}, {}
    local Y = -RAD * 0.3 -- 火球的中心比地面略高一点

    -- 白闪 + 两圈冲击波（都不抽随机数）
    flashes[1] = { r = RAD * 1.05, life = 0.06, max = 0.06 }
    rings[1] = { r0 = RAD * 0.45, r1 = RAD * 2.7, life = 0.34, max = 0.34, thick = 3, c = F[6] }
    rings[2] = { r0 = RAD * 0.3, r1 = RAD * 1.6, life = 0.22, max = 0.22, thick = 1.8, c = F[4] }
    lights:add(0, Y, RAD * 3.4, Lib.WARM, 0.6 * POWER, 0.7)
    lights:add(0, Y, RAD * 1.6, Core.WHITE, 0.6, 0.08)

    -- 火球芯子：5 团几乎不动的白热
    for _ = 1, 5 do
        local x = R:range(-2.5, 2.5)
        local y = Y + R:range(-2.5, 2.5)
        local vx = R:range(-20, 20)
        local vy = R:range(-40, -10)
        local life = R:range(0.18, 0.3)
        local size = R:range(RAD * 0.4, RAD * 0.55)
        ps:spawn(P.FIRE, x, y, vx, vy, life, 0, size)
    end
    -- 炸开的火团：向外飞、边烧边缩，近一半烧完留烟
    for _ = 1, round(28 * POWER) do
        local a = R:range(0, TAU)
        local d = R:range(0, RAD * 0.55)
        local sp = R:range(40, 210) * POWER
        local x = cos(a) * d
        local y = Y + sin(a) * d
        local vx = cos(a) * sp
        local vy = sin(a) * sp * 0.8 - 40
        local life = R:range(0.55, 1.15)
        local size = R:range(RAD * 0.22, RAD * 0.46)
        local flag = R:chance(0.45) and (PF.SMOKES | PF.BIG) or 0
        ps:spawn(P.FIRE, x, y, vx, vy, life, 0, size, 0, flag)
    end
    -- 起爆那口浓烟：慢、大、稍后才出现
    for _ = 1, 5 do
        local a = R:range(0, TAU)
        local d = R:range(RAD * 0.1, RAD * 0.5)
        local x = cos(a) * d
        local y = Y + sin(a) * d
        local vx = cos(a) * 30
        local vy = sin(a) * 20 - 30
        local life = R:range(0.9, 1.5)
        local size = R:range(RAD * 0.15, RAD * 0.26)
        local delay = R:range(0.06, 0.2)
        ps:spawn(P.SMOKE, x, y, vx, vy, life, smokeCol, size, delay, PF.BIG)
    end
    -- 冲到很高的一柱火：烟柱的骨架
    for _ = 1, 5 do
        local x = R:range(-RAD * 0.25, RAD * 0.25)
        local vx = R:range(-12, 12)
        local vy = R:range(-180, -100)
        local life = R:range(0.8, 1.3)
        local size = R:range(RAD * 0.24, RAD * 0.36)
        local delay = R:range(0, 0.1)
        local flag = R:chance(0.6) and (PF.SMOKES | PF.BIG) or 0
        ps:spawn(P.FIRE, x, Y, vx, vy, life, 0, size, delay, flag)
    end
    -- 翻滚上升的烟
    for _ = 1, round(10 * POWER) do
        local a = R:range(0, TAU)
        local d = R:range(0, RAD * 0.7)
        local sp = R:range(15, 100)
        local x = cos(a) * d
        local y = Y + sin(a) * d
        local vx = cos(a) * sp
        local vy = sin(a) * sp * 0.6 - 35
        local life = R:range(1.8, 2.8)
        local size = R:range(RAD * 0.26, RAD * 0.44)
        local delay = R:range(0.12, 0.45)
        ps:spawn(P.SMOKE, x, y, vx, vy, life, 0, size, delay, PF.BIG)
    end
    -- 火花：从炸点往四面八方拉线
    for _ = 1, round(80 * POWER) do
        local a = R:range(0, TAU)
        local sp = R:range(140, 380) * POWER
        local vx = cos(a) * sp
        local vy = sin(a) * sp - 70
        local life = R:range(0.18, 0.6)
        ps:spawn(P.SPARK, 0, Y, vx, vy, life, Core.WHITE, 1, 0, 0)
    end
    -- 飞升的余烬
    for _ = 1, round(40 * POWER) do
        local a = R:range(0, TAU)
        local sp = R:range(30, 150)
        local x = cos(a) * RAD * 0.4
        local y = Y + sin(a) * RAD * 0.4
        local vx = cos(a) * sp
        local vy = sin(a) * sp - 75
        local life = R:range(1.2, 2.6)
        ps:spawn(P.EMBER, x, y, vx, vy, life, F[4])
    end
    -- 烧着的木条：往斜上方甩
    -- ⚠️ 原版把 R.range(9, 14) 写在 for 的**循环条件**里，于是每判断一次就抽一次 Rng
    --（含最后退出循环的那一次）。必须原样照抄；先算好次数再 for 会整条序列错位。
    local bi = 0
    while bi < round(R:range(9, 14) * max(0, POWER - 0.55)) do
        local a = -pi / 2 + R:range(-1.35, 1.35)
        local sp = R:range(170, 330)
        local vx = cos(a) * sp
        local vy = sin(a) * sp
        local life = R:range(0.7, 1.3)
        ps:spawn(P.BRAND, 0, Y, vx, vy, life, Core.WHITE, 1, 0, 0)
        bi = bi + 1
    end
    -- 地面那一半：贴地往外滚的尘、掀起来的石头和碎土、一根升起来的尘柱
    for _ = 1, round(RAD * 0.5) do
        local s = R:sign()
        local x = s * R:range(0, RAD * 0.6)
        local y = -R:range(1, 5 + RAD * 0.04)
        local vx = s * R:range(3, 9.5) * RAD
        local vy = -R:range(2, 15)
        local life = R:range(1.1, 2.0)
        local size = R:range(4, 7) + RAD / 6
        local delay = R:range(0, 0.06)
        ps:spawn(P.SMOKE, x, y, vx, vy, life, st.dust, size, delay, PF.BIG)
    end
    for _ = 1, ceil(26 * min(1.5, S)) do
        local x = R:range(-0.4, 0.4) * RAD
        local vx = R:range(-9, 9) * RAD * 0.25
        local vy = -R:range(7, 16) * RAD * 0.9
        local life = R:range(1.8, 2.6)
        local a = R:range(0, TAU)
        local va = R:range(-16, 16)
        local s = R:int(1, 3)
        rocks:add({
            kind = B.CHUNK,
            x = x,
            y = -3,
            vx = vx,
            vy = vy,
            g = 1,
            drag = 0.4,
            bounce = 0.3,
            life = life,
            a = a,
            va = va,
            s = s,
        })
    end
    local gritCols = { st.light, st.body, st.body, st.shade }
    for _ = 1, round(EARTH * RAD * 4) do
        local u = R:range(-1, 1)
        local a = -pi / 2 + u * 0.5
        local sp = R:range(5, 15) * RAD * (1 - 0.45 * abs(u))
        local x = u * 0.25 * RAD
        local life = R:range(1.2, 2.2)
        local col = R:pick(gritCols)
        local size = R:chance(0.45) and 2 or 1
        ps:spawn(P.GRIT, x, -1, cos(a) * sp, sin(a) * sp, life, col, size)
    end
    for _ = 1, round(EARTH * 12) do
        local x = R:range(-0.3, 0.3) * RAD
        local y = -R:range(2, RAD * 0.6)
        local vx = R:range(-15, 15)
        local vy = -R:range(60, 190) * EARTH * 0.6
        local life = R:range(1.6, 2.6)
        local size = R:range(5, 9) * sqrt(S) + RAD / 7
        local delay = R:range(0, 0.15)
        ps:spawn(P.SMOKE, x, y, vx, vy, life, st.dust, size, delay, PF.BIG)
    end

    local self = {
        t = 0,
        F = F,
        S = S,
        RAD = RAD,
        st = st,
        Y = Y,
        R = R,
        ps = ps,
        blazes = blazes,
        rocks = rocks,
        lights = lights,
        flashes = flashes,
        rings = rings,
    }
    return setmetatable(self, { __index = SmallExplosion })
end

--- 单个子步：原版 update(dt) 的正文，顺序一字节也不能动
function SmallExplosion:step(dt)
    self.t = self.t + dt
    -- 闪光 / 冲击环：倒序数寿命，到点删除
    for _, list in ipairs({ self.flashes, self.rings }) do
        for i = #list, 1, -1 do
            local e = list[i]
            e.life = e.life - dt
            if e.life <= 0 then
                table.remove(list, i)
            end
        end
    end
    self.rocks:update(dt)
    -- 石头砸在地上会扬起一撮尘：每块石头只扬一次（rest 由 Bits 置上）
    for _, b in ipairs(self.rocks.list) do
        if b.rest and not b.dusted then
            b.dusted = true
            for _ = 1, 3 do
                -- ⚠️ 实参顺序：x 的 range → vx 的 sign+range → vy 的 range → life → size
                local x = b.x + self.R:range(-1.5, 1.5)
                local vx = self.R:sign() * self.R:range(10, 55) * 0.6
                local vy = -self.R:range(2, 22)
                local life = self.R:range(0.3, 0.65)
                local size = self.R:range(1.3, 2.8)
                self.ps:spawn(P.DUST, x, -0.5, vx, vy, life, self.st.dust, size)
            end
        end
    end
    self.blazes:update(dt)
    self.ps:update(dt)
    self.lights:update(dt)
end

function SmallExplosion:update(dt)
    -- 和 createFx 一样把 dt 细分到 120Hz 以上，每个子步都走一遍上面整套模拟
    local n = max(1, ceil(dt * 120 - 1e-9))
    for _ = 1, n do
        self:step(dt / n)
    end
end

--- 原版拆成 drawBack / draw 两个回调，因为 createFx 会分两趟画到同一张帧上。Lua 侧的
--- 有状态特效只有一个 draw（FrameDump / Bake 都只调它），所以这里把两层按原顺序接起来：
--- 先背层（烧痕、软烟、火苗、土浪的远半圈），再前层。顺序错一点像素就不一样。
local function drawBack(self, p)
    local t, F, st, S, RAD = self.t, self.F, self.st, self.S, self.RAD
    -- 地面的烧痕：白热 → 沿火色带冷却 → 炭黑，最后 1 秒淡出
    Lib.scorch(p, F, t, 22 * S, 1.2 + RAD / 14,
        1 - MathX.smooth(SmallExplosion.meta.duration - 1.2, SmallExplosion.meta.duration - 0.2, t))
    -- 烟 / 尘这类软粒子画在角色后面
    self.ps:draw(p, "back")
    self.blazes:drawBack(p)
    -- 贴地往外推的一圈土浪：远半圈（sin < 0）在这里，近半圈在 draw 里
    local k = t / 0.5
    if k < 1 then
        Sim.band(p, 0, 0.5, 80 * S * MathX.ease.outCubic(k), 0.16, max(1, (2 + RAD / 9) * (1 - k)), 1.15 - k,
            { st.body, st.light, F[4], F[7] }, function(g)
                return sin(g) < 0
            end)
    end
end

function SmallExplosion:draw(p)
    drawBack(self, p)
    local t, F, st, S, RAD, Y = self.t, self.F, self.st, self.S, self.RAD, self.Y
    local k = t / 0.5
    if k < 1 then
        Sim.band(p, 0, 0.5, 80 * S * MathX.ease.outCubic(k), 0.16, max(1, (2 + RAD / 9) * (1 - k)), 1.15 - k,
            { st.body, st.light, F[4], F[7] }, function(g)
                return sin(g) >= 0
            end)
    end
    -- 碎石自己画（不走 Bits:draw）：亮面 / 暗面 / 描边，随自转翻面
    for _, b in ipairs(self.rocks.list) do
        Lib.rock(p, b, st)
    end
    self.ps:draw(p, "front")
    -- 起爆的白闪：三个同心圆，越白越小
    for _, f in ipairs(self.flashes) do
        local k2 = f.life / f.max
        local r = f.r * (0.8 + 0.2 * k2)
        p:circle(0, Y, r + 1.2, F[3])
        p:circle(0, Y, r, k2 > 0.45 and F[7] or F[6])
        p:circle(0, Y, r * 0.6, k2 > 0.45 and Core.WHITE or F[7])
    end
    -- 冲击波：半径按 1 - k³ 冲出去，同时变薄变淡
    for _, r in ipairs(self.rings) do
        local k2 = r.life / r.max
        local e = 1 - k2 ^ 3
        p:ring(0, Y, r.r0 + (r.r1 - r.r0) * e, max(1, r.thick * k2 + 0.4), r.c, min(1, k2 * 1.6))
    end
    self.lights:draw(p)
end

return SmallExplosion
