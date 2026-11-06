-- ============================================================================
-- fx/effects/DamageNumber.lua — ui/damage-number 的 Lua 版
--
-- 原版：pixelfx src/fx/ui/damage-number.js（排字 / 上色来自 ui/_lib.js，见 DamageNumberLib.lua）
-- 长什么样：一记伤害数字从打击火花里「打」出来——前两帧是一颗带刺的白热心芒，
-- 接着一个闪点、一圈环；数字本身像个小身板：先大得离谱、全白，然后弹回原尺寸，
-- 往上抛出去再落回来，落地压扁一下、小跳一次才停下，最后一边上浮一边淡出。
-- 游戏里什么时候放：任何造成伤害的瞬间，放在受击点上方（数字自己会往上抛）。
-- ============================================================================

local Core = require "tap-pixelfx.core.Core"
local MathX = require "tap-pixelfx.core.Math"
local Sim = require "tap-pixelfx.core.Sim"
local Lib = require "tap-pixelfx.effects.DamageNumberLib"

local DamageNumber = {}

local floor, ceil, sqrt, sin, cos, abs, min, max, pi = math.floor, math.ceil, math.sqrt, math.sin, math.cos,
    math.abs, math.min, math.max, math.pi
local TAU = pi * 2
local exp = math.exp

DamageNumber.meta = {
    name = "Damage number",
    desc = "A red -27 punches out of a hit spark, white for a frame, arcs up, lands with a squash and a little hop, then fades as it lifts away.",
    tags = { "ui", "damage", "number", "combat", "text", "hit", "one-shot" },
    size = { 76, 68 },
    origin = { 30, 52 },
    duration = 1.05,
    loop = false,
    fps = 30,
    bg = "dark",
    options = {
        palette = { "#1a0508", "#4a0b12", "#8c1420", "#d42a2e", "#ff5a4a", "#ff9a86", "#ffd8cc", "#ffffff" },
        text = "-27",
        seed = 2,
    },
}

-- 数字落地的 y（局部像素）、开始淡出的 t
local LAND = -8
local FADE = 0.84

local P = Sim.P

--- 建一个实例（对齐 createFx：dt 一律细分到 120Hz 以上再步进）
function DamageNumber.new(opts)
    opts = opts or DamageNumber.meta.options
    -- ⚠️ 色带下标：原版 C 是 0 基，Lua 是 1 基，下面所有 C[k] 都已经 +1
    local C = Core.fit(opts.palette, 8)
    local R = MathX.newRng(opts.seed)
    local word = Lib.spell(opts.text)
    local ps = Sim.newParticles({ rng = R, sparks = { C[8], C[7], C[5], C[3] } })
    local stars = Lib.newStars()
    local lights = Sim.newLights()
    -- 数字是个小身板：被打上天，落回地面，弹一下才停
    local n = { x = 0, y = LAND, vx = 34, vy = -175, sq = 0, hops = 0 }
    -- 打击心芒的九根刺：绕一圈，角度带抖动
    local spikes = {}
    for i = 0, 8 do
        -- ⚠️ RNG 顺序 = 原版 Array.from 回调里「角度抖动 → 长度」的求值顺序
        local an = (i / 9) * TAU + R:range(-0.2, 0.2)
        local len = R:range(8, 14)
        spikes[#spikes + 1] = { an, len }
    end

    local self = {
        t = 0,
        hit = false,
        C = C,
        R = R,
        word = word,
        ps = ps,
        stars = stars,
        lights = lights,
        n = n,
        spikes = spikes,
    }
    return setmetatable(self, { __index = DamageNumber })
end

--- 单步（原版 update 的整个函数体，dt 是细分后的）
function DamageNumber:step(dt)
    local C, R, ps, lights, n, stars = self.C, self.R, self.ps, self.lights, self.n, self.stars
    self.t = self.t + dt

    -- 第一帧：打击的光 + 一蓬朝左上喷的火花
    if not self.hit then
        self.hit = true
        lights:add(0, -4, 30, C[6], 0.7, 0.25)
        lights:add(0, -4, 14, Core.WHITE, 0.6, 0.08)
        for i = 0, 8 do
            -- ⚠️ 每一次 range 的先后 = 原版实参求值顺序（角度 → 速度 → 寿命）
            local an = R:range(-pi * 0.95, -0.05) + ((i % 2 ~= 0) and (pi * 0.08) or 0)
            local sp = R:range(90, 200)
            ps:spawn(P.SPARK, 0, -4, cos(an) * sp, sin(an) * sp, R:range(0.1, 0.25))
        end
    end

    -- 数字的抛物线：重力 + 横向阻尼，落地就压扁、反射（只弹一次）
    if n.hops < 2 then
        n.vy = n.vy + 900 * dt
        n.vx = n.vx - n.vx * 2 * dt
        n.x = n.x + n.vx * dt
        n.y = n.y + n.vy * dt
        if n.y >= LAND and n.vy > 0 then
            n.y = LAND
            n.sq = 1
            n.hops = n.hops + 1
            n.vy = (n.hops < 2) and (-n.vy * 0.36) or 0
            if n.hops == 1 then
                for _, s in ipairs({ -1, 1 }) do
                    -- ⚠️ 仍然是原版实参顺序：y 抖动 → vx → vy → 寿命 → 尺寸
                    local yy = LAND + R:range(-2, 1)
                    local vx = s * R:range(15, 35)
                    local vy = -R:range(5, 20)
                    local life = R:range(0.2, 0.35)
                    stars:add(n.x + s * 14, yy, vx, vy, life, C[7], R:range(0.5, 1.2), R)
                end
            end
        end
    end
    n.sq = max(0, n.sq - dt / 0.09)

    ps:update(dt)
    stars:update(dt)
    lights:update(dt)
end

function DamageNumber:update(dt)
    local steps = max(1, ceil(dt * 120 - 1e-9))
    for _ = 1, steps do
        self:step(dt / steps)
    end
end

function DamageNumber:draw(p)
    local C, n, t = self.C, self.n, self.t

    -- 打击：两帧带刺的白热心芒（第一帧更粗），随后一个闪点
    if t < 0.07 then
        local big = t < 0.035
        for i = 0, #self.spikes - 1 do
            local sp = self.spikes[i + 1]
            local an, L = sp[1], sp[2]
            local l = L * (big and 1 or 1.3)
            local ca, sa = cos(an), sin(an)
            if big then
                -- 一根粗刺：中间白热芯，两侧各一道红边，往尖上收
                p:line(-sa, -4 + ca, ca * l * 0.7 - sa, -4 + sa * l * 0.7 + ca, C[5])
                p:line(sa, -4 - ca, ca * l * 0.7 + sa, -4 + sa * l * 0.7 - ca, C[5])
            end
            local u = big and 0 or l * 0.45
            local col = big and Core.WHITE or ((i % 2 ~= 0) and C[7] or C[6])
            p:line(ca * u, -4 + sa * u, ca * l, -4 + sa * l, col)
        end
        if big then
            p:circle(0, -4, 3.2, Core.WHITE)
        end
    elseif t < 0.16 then
        Sim.sparkle(p, 0, -4, 5 * (1 - (t - 0.07) / 0.09), Core.WHITE, C[6], 0.6)
    end

    -- 打点处胀开的一圈环
    local rk = t / 0.22
    if rk < 1 then
        p:ring(0, -4, 3 + 10 * MathX.ease.outCubic(rk), max(1, 2 * (1 - rk)), (rk < 0.4) and Core.WHITE or C[6], 1.2 - rk)
    end

    self.ps:draw(p)
    self.stars:draw(p)

    -- 数字：先大得离谱、全白，弹回原尺寸，落地压扁，最后上浮淡出
    local out = MathX.seg(t, FADE, DamageNumber.meta.duration - 0.04)
    if out < 1 then
        local s = 2 + 1.4 * exp(-t * 22) * cos(t * 30)
        local sx, sy = s, s
        if n.sq > 0 then
            sx = s * (1 + 0.18 * n.sq)
            sy = s * (1 - 0.2 * n.sq)
        elseif n.hops < 2 and abs(n.vy) > 120 then
            sx = s * 0.92
            sy = s * 1.1
        end
        local W = self.word.w * sx
        local H = 7 * sy
        local x0 = n.x - W / 2
        local y0 = n.y - H - 6 * MathX.ease.inQuad(out)
        local flash = (t < 0.035) and 1 or ((t < 0.07) and 0.4 or 0)
        local items = {}
        for _, L in ipairs(self.word.letters) do
            if L.g then
                items[#items + 1] = { g = L.g, x = x0 + L.x * sx, y = y0, sx = sx, sy = sy, flash = flash, a = 1 - out }
            end
        end
        Lib.drawWord(p, items, {
            fill = { C[4], C[4], C[5], C[6] },
            edge = C[7],
            under = C[3],
            outline = C[1],
            shadow = Core.scale(C[1], 0.5),
        })
        p:glow(n.x, y0 + H / 2, 18, C[5], 0.3 * (1 - out) + ((t < 0.1) and 0.4 * (1 - t / 0.1) or 0))
    end

    self.lights:draw(p)
end

return DamageNumber
