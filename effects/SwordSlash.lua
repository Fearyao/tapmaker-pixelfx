-- ============================================================================
-- fx/effects/SwordSlash.lua — melee/sword-slash 的 Lua 版
-- 原版：pixelfx src/fx/melee/sword-slash.js
--
-- 一道倾斜的月牙横扫两帧，从白往深蓝凉下去；刃尖反光、抛火花；月牙身后留一串点状残迹。
-- 同一套画法画两遍（主带 A + 延迟一拍、更细的回声 E），所以对 Rng/色带台阶的索引
-- 差一位就会两把刀一起错。
--
-- 原版还导出了 GUARD/WIND/CUT/DOWN 姿势表和 act（角色的挥剑动作），那是 act/rig 那一层
-- （本目录没搬），对渲染没有影响，故略过；fx 本体只用到 create()。
-- ============================================================================

local Core = require "tap-pixelfx.core.Core"
local MathX = require "tap-pixelfx.core.Math"
local Sim = require "tap-pixelfx.core.Sim"

local SwordSlash = {}

local floor, ceil, sqrt, sin, cos, abs, min, max, pi = math.floor, math.ceil, math.sqrt,
    math.sin, math.cos, math.abs, math.min, math.max, math.pi

local TAU = pi * 2
local ease = MathX.ease
local clamp = Core.clamp
local smooth = MathX.smooth
local round = function(v)
    return floor(v + 0.5)
end

--- JS 的 `%` 是截断取余（符号跟被除数），Lua 的 `%` 是向下取整取余，两者在负数上差一个 TAU。
--- 月牙的 u 只可能落在 (-2π, 2π)，这个写法在 |x| < 2π 时和 fmod 逐位一致。
local function jsmod(x, m)
    if x >= 0 then
        return x - m * floor(x / m)
    end
    return x - m * ceil(x / m)
end

SwordSlash.meta = {
    name = "Sword slash",
    desc = "A tilted crescent whips round in two frames, cools from white to deep blue as it trails off, glints at the tip and throws sparks.",
    tags = { "melee", "slash", "sword", "combat", "directional", "one-shot" },
    size = { 136, 104 },
    origin = { 44, 92 },
    duration = 0.75,
    loop = false,
    fps = 30,
    bg = "ground",
    actor = 2,
    options = {
        palette = { "#212f6b", "#2c58aa", "#3a8bd8", "#62c8f4", "#b8c9e8", "#e8f1ff", "#ffffff" },
        sparks = { "#fff3a6", "#ffe26b", "#ff8a2a", "#f2561d" },
        radius = 42,
        seed = 2,
    },
}

local P = Sim.P

--- 倾斜椭圆上的一点（s.sy 压扁成「斜着砍下去」的透视）
local function onArc(s, r, a)
    local lx, ly = cos(a) * r, sin(a) * r * s.sy
    local c, n = cos(s.rot), sin(s.rot)
    return s.cx + lx * c - ly * n, s.cy + lx * n + ly * c
end

--- 抹痕：最厚处在刃口后面一点，往尾端收成一根头发丝；外缘白、往里 + 随时间往里压暗，
--- 尾端靠 dither 化掉。ta = 尾端角，L = 扫过的角度（带符号），W = 厚度，age = 0..1
local function crescent(p, s, ta, L, W, age)
    if abs(L) < 0.02 or W < 0.3 then
        return
    end
    local R, n = s.ramp, #s.ramp
    local dir = (L > 0 and 1) or (L < 0 and -1) or 0
    local span = abs(L)
    local c, sn = cos(s.rot), sin(s.rot)
    local cx, cy, sy, RR = s.cx, s.cy, s.sy, s.R
    local B = RR + 2
    p:shade(cx - B, cy - B, cx + B, cy + B, function(x, y, o)
        local dx, dy = x - cx, y - cy
        local lx = dx * c + dy * sn
        local ly = (-dx * sn + dy * c) / sy
        local r = sqrt(lx * lx + ly * ly)
        if r > RR + 0.5 or r < RR - W - 1 then
            return
        end
        local u = jsmod(dir * (math.atan(ly, lx) - ta), TAU)
        if u < 0 then
            u = u + TAU
        end
        if u > span then
            return
        end
        local v = u / span
        local w = W * sin(pi * v ^ 2.2) ^ 0.6
        if w < 0.35 then
            return
        end
        local q = (RR - r) / w
        if q < 0 or q > 1 then
            return
        end
        -- 年轻时最亮的一阶贴在刃口，之后往里、随时间、往尾端逐级压暗
        local ci
        if q < 0.22 and age < 0.5 then
            ci = 0
        else
            ci = round(q * (n - 1) * 0.75 + age * 2.4 - v * 0.8 + 0.4)
        end
        o.c = R[n - clamp(ci, 0, n - 1)]
        o.a = min(1, v / 0.4)
    end)
    -- 沿弧加一排光：刃附近亮、尾端淡
    local u = 0
    while u <= span do
        local x, y = onArc(s, RR - W * 0.4, ta + dir * u)
        p:glow(x, y, 5 + W, R[n - 2], 0.22 * (1 - age) * (u / span))
        u = u + 0.3
    end
end

--- 一条月牙的一帧：扫开（outExpo）、停住、再化掉
local function drawSlash(p, s, t)
    local u = t - s.t0
    if u < 0 then
        return
    end
    local span = s.a1 - s.a0
    local head = ease.outExpo(clamp(u / s.sweep))
    local tail = smooth(s.sweep + s.hold, s.sweep + s.hold + s.trail, u)
    local age = clamp(u / (s.sweep + s.hold + s.trail))
    if tail < 1 then
        crescent(p, s, s.a0 + span * tail, span * (head - tail), s.W * (1 - tail * 0.55), age)
    end
    -- 刃已经扫过的地方留一串点，标出刀路
    local th = 0.7 * (1 - clamp((u - s.sweep - s.hold) / (s.trail + 0.2)))
    if tail > 0.02 and th > 0 then
        local step = 0.6 / (abs(span) * s.R)
        local k = 0
        while k <= tail do
            local x, y = onArc(s, s.R - 0.5, s.a0 + span * k)
            p:dot(x, y, s.ramp[2], th * (0.4 + 0.6 * k))
            k = k + step
        end
    end
end

--- 刃尖：位置 + 沿弧切向的单位向量（火花顺着它飞出去）
local function tipOf(s)
    local x, y = onArc(s, s.R - s.W * 0.3, s.a1)
    local sign = (s.a1 - s.a0 >= 0) and 1 or -1
    local x2, y2 = onArc(s, s.R - s.W * 0.3, s.a1 + sign * 0.05)
    local l = sqrt((x2 - x) * (x2 - x) + (y2 - y) * (y2 - y))
    if l == 0 then
        l = 1
    end
    return { x = x, y = y, dx = (x2 - x) / l, dy = (y2 - y) / l }
end

--- 建一个实例
function SwordSlash.new(opts)
    opts = opts or SwordSlash.meta.options
    local C = Core.fit(opts.palette, 7)
    local R = MathX.newRng(opts.seed)
    local ps = Sim.newParticles({ rng = R, ground = function() return 0 end, sparks = opts.sparks })
    local R0, a0, a1 = opts.radius, -2.55, 0.95
    -- 主带；以及紧贴内侧、慢一拍的一道更细的回声
    local A = {
        cx = 6, cy = -26, R = R0, sy = 0.6, rot = -0.38, a0 = a0, a1 = a1, W = 12,
        t0 = 0, sweep = 0.06, hold = 0.06, trail = 0.24, ramp = C,
    }
    local E = {
        cx = 6, cy = -26, R = R0 * (33 / 42), sy = 0.6, rot = -0.38,
        a0 = a0 + (a1 - a0) * 0.1, a1 = a1 - (a1 - a0) * (0.15 / 3.5),
        W = R0 * (4.5 / 42), t0 = 0.017, sweep = 0.06, hold = 0.03, trail = 0.2,
        ramp = { C[1], C[2], C[3], C[4], C[5], C[6] },
    }
    local self = {
        C = C, R = R, ps = ps, A = A, E = E,
        a0 = a0, a1 = a1,
        tip = tipOf(A),
        t = 0, landed = false,
    }
    return setmetatable(self, { __index = SwordSlash })
end

function SwordSlash:update(dt)
    -- 对齐 createFx：模拟一律细分到 120Hz 以上再步进；t 和 landed 判定都跟着细分走
    local n = max(1, ceil(dt * 120 - 1e-9))
    local d = dt / n
    local R, ps, A = self.R, self.ps, self.A
    for _ = 1, n do
        self.t = self.t + d
        if not self.landed and self.t >= A.sweep then
            self.landed = true
            -- 停在刃口处崩出来的火花：顺着刃的切向喷一锥
            local tip = self.tip
            local baseA = math.atan(tip.dy, tip.dx)
            for _ = 1, 10 do
                local a = baseA + R:range(-0.5, 0.5)
                local sp = R:range(150, 400)
                local vx, vy = cos(a) * sp, sin(a) * sp
                -- ⚠️ 实参求值顺序：vx/vy 先算（无随机），life 最后；spawn 内部还会取一次 rng 当 seed
                local life = R:range(0.12, 0.35)
                ps:spawn(P.SPARK, tip.x, tip.y, vx, vy, life)
            end
            -- 从弧上甩下来的亮屑：沿法线往外飞，颜色在 5/6 阶之间二选一
            for _ = 1, 16 do
                local a = self.a0 + (self.a1 - self.a0) * R:range(0.3, 1)
                local x, y = onArc(A, A.R, a)
                local ox, oy = x - A.cx, y - A.cy
                local l = sqrt(ox * ox + oy * oy)
                if l == 0 then
                    l = 1
                end
                local sp = R:range(30, 100)
                local vx, vy = (ox / l) * sp, (oy / l) * sp - 10
                local life = R:range(0.25, 0.55)
                local col = self.C[5 + R:int(0, 1)]
                ps:spawn(P.MOTE, x, y, vx, vy, life, col, 0.6)
            end
        end
        ps:update(d)
    end
end

function SwordSlash:draw(p)
    local t, A, C, tip = self.t, self.A, self.C, self.tip
    -- 先回声后主带：原版就是这个顺序，换过来叠色就不一样
    drawSlash(p, self.E, t)
    drawSlash(p, self.A, t)
    -- 刃尖到达时闪一下
    local g = t - A.sweep * 0.6
    if g > 0 and g < 0.22 then
        Sim.sparkle(p, tip.x, tip.y, 9 * ease.outBack(min(1, g / 0.05)) * (1 - g / 0.22), C[6], C[4], 0.6)
    end
    -- 光跟着刀头的扫动走
    if t < 0.3 then
        local x, y = onArc(A, A.R - 4, A.a0 + (A.a1 - A.a0) * ease.outExpo(clamp(t / A.sweep)))
        p:glow(x, y, 40, C[4], 0.5 * (1 - t / 0.3))
    end
    self.ps:draw(p)
end

return SwordSlash
