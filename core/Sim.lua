-- ============================================================================
-- view/px/Sim.lua — pixelfx `src/core/sim.js` 的移植
--
-- 带真物理的粒子（火花、碎屑、烟、火）、刚体碎片、闪光灯、以及 star/flare/band/crystal
-- 这几个画法。单位是「美术像素 + 秒」，全部通过 Painter 画，所以跟其它特效一样可以镜像旋转。
--
-- 和原版一致：所有随机都走 Particles 自己的 Rng，同一 dt 序列重放出来逐像素相同。
-- ============================================================================

local Core = require "tap-pixelfx.core.Core"
local MathX = require "tap-pixelfx.core.Math"
local Painter = Core.Painter

local floor, ceil, sqrt, sin, cos, abs, min, max, pi = math.floor, math.ceil, math.sqrt, math.sin, math.cos,
    math.abs, math.min, math.max, math.pi

local Sim = {}

Sim.GRAVITY = 950 -- px/s²

local CROSS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
local DIAG = { { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }

local function ramp(list)
    local r = {}
    for i = 1, #list do
        r[i] = Core.hex(list[i])
    end
    return r
end

local HOT = ramp({ "#fff3a6", "#ffe26b", "#ff8a2a", "#f2561d" })
Sim.HOT = HOT
Sim.FIRE_RAMP = ramp({ "#ffffff", "#fff3a6", "#ffe26b", "#ffc23d", "#ff8a2a", "#f2561d", "#c9281f", "#8a1f17", "#4a1712" })
Sim.SMOKE_RAMP = ramp({ "#7b6f72", "#5d5660", "#433d48", "#2b2630", "#1a171e" })

local function rampAt(r, t)
    local i = floor(t * #r) + 1
    if i < 1 then
        i = 1
    elseif i > #r then
        i = #r
    end
    return r[i]
end

--- 粒子种类
Sim.P = {
    SPARK = 0, MOTE = 1, STREAK = 2, FLAKE = 3, VAPOUR = 4, DUST = 5,
    STAR = 6, EMBER = 7, SMOKE = 8, FIRE = 9, BRAND = 10, GRIT = 11,
}
--- 标志位：SMOKES = 火苗烧完留烟，BIG = 更大更慢的烟，BACK = 画在角色后面
Sim.PF = { SMOKES = 1, BIG = 2, BACK = 4 }
--- 碎片种类
Sim.B = { SHARD = 0, CHUNK = 1, DRIP = 2 }

local P, PF, B = Sim.P, Sim.PF, Sim.B

local SOFT = {}
SOFT[P.VAPOUR] = true
SOFT[P.DUST] = true
SOFT[P.SMOKE] = true

-- ---------------------------------------------------------------------------
-- Particles：带物理的粒子系统
-- opts: { seed | rng, ground(x) -> 地面 y, sparks = 火花色带, haze = 蒸汽辉光色, onLand(x,y) }
-- ---------------------------------------------------------------------------
local Particles = {}
Particles.__index = Particles
Sim.Particles = Particles

function Sim.newParticles(opts)
    opts = opts or {}
    local self = setmetatable({}, Particles)
    self.R = opts.rng or MathX.newRng(opts.seed or 1)
    self.list = {}
    self.t = 0
    self.ground = opts.ground or function()
        return math.huge
    end
    self.sparks = ramp(opts.sparks or { "#fff3a6", "#ffe26b", "#ff8a2a", "#f2561d" })
    -- 烟/墨的色带可覆盖：海怪的墨要一路压到近黑，默认的 SMOKE_RAMP 是灰的会读成蒸汽
    self.smoke = opts.smoke and ramp(opts.smoke) or nil
    self.haze = opts.haze and Core.hex(opts.haze) or nil
    self.onLand = opts.onLand or nil
    return self
end

--- delay: 出现前的秒数；flag: PF 位；col 传 0 让 FIRE / SMOKE 用自己的色带
function Particles:spawn(k, x, y, vx, vy, life, col, size, delay, flag)
    self.list[#self.list + 1] = {
        k = k,
        x = x,
        y = y,
        vx = vx,
        vy = vy,
        life = life,
        max = life,
        col = (col ~= nil and col ~= 0) and Core.hex(col) or 0,
        size = size or 1,
        seed = self.R:next() * 100,
        delay = delay or 0,
        flag = flag or 0,
    }
    return self.list[#self.list]
end

function Particles:count()
    return #self.list
end

function Particles:update(dt)
    self.t = self.t + dt
    local R, list, t = self.R, self.list, self.t
    for i = #list, 1, -1 do
        local p = list[i]
        if p.delay > 0 then
            p.delay = p.delay - dt
        else
            p.life = p.life - dt
            if p.life <= 0 then
                if p.k == P.FIRE and (p.flag & PF.SMOKES) ~= 0 then
                    local big = (p.flag & PF.BIG) ~= 0
                    self:spawn(P.SMOKE, p.x, p.y, p.vx * 0.6, p.vy * 0.6 - 6,
                        big and R:range(1.3, 2.3) or R:range(0.8, 1.4), 0,
                        p.size * (big and 0.85 or 0.7), 0, big and PF.BIG or 0)
                end
                table.remove(list, i)
            else
                local continued = false
                if p.k == P.FIRE then
                    p.vy = p.vy - 95 * dt
                    p.vx = p.vx + sin(t * 17 + p.seed) * 30 * dt
                    p.vx = p.vx - p.vx * 5 * dt
                    p.vy = p.vy - p.vy * 3.2 * dt
                elseif p.k == P.GRIT then
                    p.vy = p.vy + Sim.GRAVITY * dt
                    p.vx = p.vx - p.vx * 0.8 * dt
                    local g = self.ground(p.x)
                    local ny = p.y + p.vy * dt
                    p.x = p.x + p.vx * dt
                    if p.vy > 0 and p.y <= g and ny >= g then
                        p.y = g - 0.25
                        if p.vy > 130 and R:chance(0.4) then
                            p.vy = -p.vy * 0.25
                            p.vx = p.vx * 0.5 + R:range(-10, 10)
                        else
                            p.vx = 0
                            p.vy = 0
                            p.life = min(p.life, 0.5)
                        end
                    else
                        p.y = ny
                    end
                    continued = true
                elseif p.k == P.BRAND then
                    p.vy = p.vy + Sim.GRAVITY * 0.8 * dt
                    p.vx = p.vx - p.vx * 0.9 * dt
                    if R:chance(0.9 * min(1, dt * 60)) then
                        self:spawn(P.FIRE, p.x, p.y, p.vx * 0.1 + R:range(-7, 7), p.vy * 0.1 - 10,
                            R:range(0.16, 0.32), 0,
                            R:range(0.9, 1.7) * (0.5 + (p.life / p.max) * 0.6), 0,
                            R:chance(0.4) and PF.SMOKES or 0)
                    end
                    local g = self.ground(p.x)
                    local ny = p.y + p.vy * dt
                    p.x = p.x + p.vx * dt
                    if p.vy > 0 and p.y <= g and ny >= g then
                        if self.onLand then
                            self.onLand(p.x, g)
                        end
                        table.remove(list, i)
                    else
                        p.y = ny
                    end
                    continued = true
                elseif p.k == P.SPARK then
                    p.vy = p.vy + Sim.GRAVITY * 0.45 * dt
                    p.vx = p.vx - p.vx * 2.2 * dt
                    p.vy = p.vy - p.vy * 2.2 * dt
                    local g = self.ground(p.x)
                    local ny = p.y + p.vy * dt
                    p.x = p.x + p.vx * dt
                    if p.vy > 0 and p.y <= g and ny >= g then
                        p.vy = -p.vy * 0.45
                        p.vx = p.vx * 0.7
                        p.y = g - 0.25
                    else
                        p.y = ny
                    end
                    continued = true
                elseif p.k == P.STREAK then
                    p.vx = p.vx + p.vx * 3 * dt
                    p.vy = p.vy + p.vy * 3 * dt
                elseif p.k == P.FLAKE then
                    p.vx = p.vx - p.vx * 2.2 * dt
                    p.vy = p.vy - p.vy * 2.2 * dt + 35 * dt
                    p.x = p.x + sin(self.t * 2.5 + p.seed) * 7 * dt
                elseif p.k == P.EMBER then
                    p.vy = p.vy + (-30 + sin(t * 3 + p.seed) * 20) * dt
                    p.vx = p.vx + cos(t * 2.3 + p.seed) * 45 * dt
                    p.vx = p.vx - p.vx * 1.6 * dt
                    p.vy = p.vy - p.vy * 1.6 * dt
                elseif p.k == P.SMOKE then
                    local big = (p.flag & PF.BIG) ~= 0
                    p.vy = p.vy - (big and 23 or 16) * dt
                    p.vx = p.vx + sin(t * 1.3 + p.seed) * 8 * dt
                    p.vx = p.vx - p.vx * 1.6 * dt
                    p.vy = p.vy - p.vy * 1.2 * dt
                elseif p.k == P.MOTE then
                    p.vx = p.vx - p.vx * 0.6 * dt
                    p.vy = p.vy - p.vy * 0.6 * dt
                else
                    local drag = SOFT[p.k] and 4 or 1.6
                    p.vx = p.vx - p.vx * drag * dt
                    -- ⚠️ 原版是 `p.vy -= p.vy * drag * dt + 5 * dt`：那个 +5*dt 也在被减的括号里。
                    -- 少一层括号会让 STAR 这类落进 default 的粒子每帧往上飘（0.5s 差 0.22px，
                    -- 光晕层直接差到通道 255）。
                    p.vy = p.vy - (p.vy * drag * dt + 5 * dt)
                end
                if not continued then
                    p.x = p.x + p.vx * dt
                    p.y = p.y + p.vy * dt
                end
            end
        end
    end
end

function Particles:draw(p, layer)
    local R = self.R
    for _, q in ipairs(self.list) do
        local softOrBack = SOFT[q.k] or (q.flag & PF.BACK) ~= 0
        local myLayer = softOrBack and "back" or "front"
        if q.delay <= 0 and (layer == nil or layer == myLayer) then
            local k = q.life / q.max
            local x, y = q.x, q.y
            local sp = sqrt(q.vx * q.vx + q.vy * q.vy)
            if sp == 0 then
                sp = 1
            end
            local ux, uy = q.vx / sp, q.vy / sp

            if q.k == P.SPARK then
                local S = self.sparks
                local head = k > 0.6 and S[1] or (k > 0.3 and S[2] or S[3])
                local len = min(9, 1 + sp * 0.022)
                p:line(x - ux * len, y - uy * len, x - ux * len * 0.4, y - uy * len * 0.4,
                    k > 0.5 and head or S[#S])
                p:line(x - ux * len * 0.45, y - uy * len * 0.45, x, y, head)
                p:glow(x, y, 3, head, 0.45 * k)
            elseif q.k == P.MOTE then
                local len = min(16, 0.5 + sp * 0.026) * q.size
                local a = k < 0.35 and (k / 0.35) or 1
                p:line(x - ux * len, y - uy * len, x - ux * len * 0.35, y - uy * len * 0.35,
                    Core.scale(q.col, 0.55), a)
                p:line(x - ux * len * 0.4, y - uy * len * 0.4, x, y, q.col, a)
                p:glow(x, y, 2.5 + q.size, q.col, 0.4 * k)
            elseif q.k == P.STREAK then
                local L = MathX.clamp(sp / 30, 1, 7)
                local d = L
                while d >= 0 do
                    local c
                    if d < 1 then
                        c = Core.WHITE
                    elseif d < L * 0.5 then
                        c = q.col
                    else
                        c = Core.scale(q.col, 0.6)
                    end
                    p:dot(x - ux * d, y - uy * d, c, (d < L * 0.5) and 1 or (1.2 - d / L))
                    d = d - 0.5
                end
                p:glow(x, y, 4, q.col, 0.4)
            elseif q.k == P.FLAKE then
                local a = min(1, k * 3)
                p:dot(x, y, q.col, a)
                if q.size > 1.3 then
                    for i = 1, 4 do
                        p:dot(x + CROSS[i][1], y + CROSS[i][2], Core.scale(q.col, 0.8), a * 0.8)
                    end
                end
            elseif q.k == P.VAPOUR then
                local r = q.size * (0.6 + (1 - k) * 0.9)
                p:disc(x, y, r, q.col, k ^ 1.3 * 0.45)
                if self.haze then
                    p:glow(x, y, r * 1.8, self.haze, 0.16 * k)
                end
            elseif q.k == P.DUST then
                p:disc(x, y, q.size * (0.6 + (1 - k) * 0.9), q.col, k ^ 1.3 * 0.7)
            elseif q.k == P.SMOKE then
                local age = 1 - k
                local big = (q.flag & PF.BIG) ~= 0
                local r = q.size * (0.65 + min(1, age * 2.5) * 0.45 + age * (big and 0.5 or 0.4))
                local a = min(1, age * 12) * min(1, k * 2.4) * (big and 0.7 or 0.58)
                local SR = self.smoke or Sim.SMOKE_RAMP
                local c = (q.col ~= 0) and Core.mix(q.col, rampAt(SR, age), age)
                    or rampAt(SR, age * 1.05)
                p:disc(x, y, r, c, a * 0.45)
                p:disc(x + r * 0.05, y + r * 0.06, r * 0.74, c, a * 0.62)
                if age < 0.5 then
                    p:disc(x - r * 0.22, y - r * 0.3, r * 0.5, Core.mix(c, Core.WHITE, 0.12), a * 0.4 * (1 - age * 2))
                end
            elseif q.k == P.FIRE then
                local age = 1 - k
                local heat = min(0.999, age ^ 0.62 + (q.seed % 1) * 0.1)
                local F, n = Sim.FIRE_RAMP, #Sim.FIRE_RAMP
                local idx = min(n - 2, floor(heat * (n - 1))) + 1
                local r = q.size * (0.55 + 0.45 * min(1, age * 7)) * (1 - age * 0.55)
                local c = F[idx]
                if idx >= n - 1 then
                    p:disc(x, y, r, c, min(1, k * 3) * 0.85)
                else
                    p:circle(x, y, r, F[min(n, idx + 2)])
                    p:circle(x - r * 0.16, y - r * 0.22, r * 0.78, c)
                    if r > 1.6 then
                        p:circle(x, y - r * 0.9, r * 0.42, c)
                    end
                    if idx <= 4 and r > 1.8 then
                        p:circle(x - r * 0.28, y - r * 0.34, r * 0.36, F[max(1, idx - 1)])
                    end
                    if idx < 7 then
                        p:glow(x, y, r * 2.4 + 2, c, 0.18 * k)
                    end
                end
            elseif q.k == P.BRAND then
                p:circle(x, y, 1.6, HOT[4])
                p:px(x, y, sin(self.t * 40 + q.seed) > 0 and HOT[1] or HOT[2])
                p:px(x + 1, y, HOT[2])
                p:glow(x, y, 7, HOT[3], 0.45)
            elseif q.k == P.GRIT then
                if k > 0.25 or k * 4 > 0.5 then
                    p:px(x, y, q.col)
                    if q.size >= 2 then
                        p:px(x + 1, y, q.col)
                        p:px(x, y + 1, Core.scale(q.col, 0.8))
                        p:px(x + 1, y + 1, Core.scale(q.col, 0.7))
                    end
                end
            elseif q.k == P.EMBER then
                local c = k > 0.6 and self.sparks[1] or (k > 0.3 and self.sparks[2] or self.sparks[3])
                if not (k < 0.25 and sin(self.t * 40 + q.seed) < 0) then
                    p:px(x, y, c)
                    if q.size > 1.5 then
                        p:px(x, y + 1, self.sparks[#self.sparks])
                    end
                    p:glow(x, y, 3 + q.size, c, 0.35 * k)
                end
            else
                -- STAR：闪烁的十字，臂长由 size 决定
                local tw = 0.6 + 0.4 * sin(self.t * (8 + (q.seed % 5)) + q.seed)
                if q.size < 1 then
                    if tw * k > 0.25 then
                        p:px(x, y, tw > 0.8 and Core.WHITE or q.col)
                    end
                    p:glow(x, y, 3, q.col, 0.4 * k * tw)
                else
                    Sim.sparkle(p, x, y, q.size * tw * min(1, k * 3), q.col, Core.scale(q.col, 0.75), 0.5 * k * tw)
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Blazes：落点处烧起来的小火苗
-- ---------------------------------------------------------------------------
local Blazes = {}
Blazes.__index = Blazes
Sim.Blazes = Blazes

function Sim.newBlazes(ps)
    return setmetatable({ ps = ps, list = {} }, Blazes)
end

function Blazes:add(x, y, life, power)
    self.list[#self.list + 1] = { x = x, y = y, life = life, max = life, acc = self.ps.R:next(), power = power }
end

function Blazes:count()
    return #self.list
end

function Blazes:update(dt)
    local ps, R = self.ps, self.ps.R
    for i = #self.list, 1, -1 do
        local b = self.list[i]
        b.life = b.life - dt
        if b.life <= 0 then
            table.remove(self.list, i)
        else
            local k = b.life / b.max
            local intensity = b.power * (k > 0.7 and 1 or (0.35 + (k / 0.7) * 0.65))
            b.acc = b.acc + dt * (6 + 16 * intensity)
            while b.acc > 1 do
                b.acc = b.acc - 1
                local s = R:range(1.2, 2.8) * intensity
                ps:spawn(P.FIRE, b.x + R:range(-1.5, 1.5), b.y - s * 0.6, R:range(-6, 6), R:range(-30, -12),
                    R:range(0.28, 0.6), 0, s, 0, PF.BACK | (R:chance(0.3) and PF.SMOKES or 0))
                if R:chance(0.06) then
                    ps:spawn(P.EMBER, b.x, b.y - 1.5, R:range(-15, 15), R:range(-45, -15), R:range(0.6, 1.4),
                        HOT[3], 1, 0, PF.BACK)
                end
            end
        end
    end
end

function Blazes:drawBack(p)
    for _, b in ipairs(self.list) do
        local k = b.life / b.max
        p:px(b.x, b.y, k > 0.4 and (sin(b.life * 31 + b.x) > 0 and HOT[2] or HOT[3]) or HOT[4])
        p:glow(b.x, b.y, 6 + 5 * k * b.power, HOT[3], 0.3 * k * b.power)
    end
end

-- ---------------------------------------------------------------------------
-- Bits：会翻滚、弹跳、最终停住的刚体碎片
-- ---------------------------------------------------------------------------
local Bits = {}
Bits.__index = Bits
Sim.Bits = Bits

function Sim.newBits(opts)
    opts = opts or {}
    local self = setmetatable({ list = {} }, Bits)
    self.ground = opts.ground or function()
        return math.huge
    end
    return self
end

function Bits:add(b)
    local life = b.life or 1
    local o = {
        kind = b.kind or B.SHARD,
        vx = b.vx or 0,
        vy = b.vy or 0,
        a = b.a or 0,
        va = b.va or 0,
        s = b.s or 1,
        c = b.c or Core.WHITE,
        g = b.g or 1,
        drag = b.drag or 0,
        bounce = b.bounce or 0,
        rest = false,
        x = b.x,
        y = b.y,
        ramp = b.ramp,
        life = life,
        max = life,
    }
    self.list[#self.list + 1] = o
    return o
end

function Bits:count()
    return #self.list
end

function Bits:update(dt)
    for i = #self.list, 1, -1 do
        local b = self.list[i]
        b.life = b.life - dt
        if b.life <= 0 then
            table.remove(self.list, i)
        elseif not b.rest then
            b.vy = b.vy + Sim.GRAVITY * b.g * dt
            b.vx = b.vx - b.vx * b.drag * dt
            b.vy = b.vy - b.vy * b.drag * dt
            b.x = b.x + b.vx * dt
            b.y = b.y + b.vy * dt
            b.a = b.a + b.va * dt
            local fl = self.ground(b.x)
            local sp = b.vy
            if not (b.g <= 0 or b.y < fl or sp <= 0) then
                b.y = fl - 0.01
                if b.kind == B.DRIP then
                    b.life = 0
                elseif b.bounce > 0 and sp > 70 then
                    b.vy = -sp * b.bounce
                    b.vx = b.vx * 0.7
                    b.va = b.va * 0.6
                else
                    b.rest = true
                    b.vx = 0
                    b.vy = 0
                end
            end
        end
    end
end

function Bits:draw(p)
    for _, b in ipairs(self.list) do
        local a = min(1, b.life / 0.4)
        local ca, sa = cos(b.a), sin(b.a)
        if b.kind == B.SHARD then
            local d = -b.s / 2
            while d <= b.s / 2 do
                p:dot(b.x + ca * d, b.y + sa * d, (d > b.s / 2 - 0.6) and Core.WHITE or Core.hex(b.c), a)
                d = d + 0.5
            end
        elseif b.kind == B.DRIP then
            p:dot(b.x, b.y, Core.hex(b.c), a)
            p:dot(b.x, b.y - 1, Core.hex(b.c), a * 0.5)
        else
            local R = ramp(b.ramp or { "#1c2030", "#3a4a66", "#6e86a8", "#a8c0dc", "#e8f2ff" })
            local n = #R
            local x, y = floor(b.x + 0.5), floor(b.y + 0.5)
            local r = ceil(b.s) + 1
            for py = -r, r do
                for px = -r, r do
                    local u = (px + 0.5) * ca + (py + 0.5) * sa
                    local v = -(px + 0.5) * sa + (py + 0.5) * ca
                    local d = abs(u) / b.s + abs(v) / (b.s * 0.62)
                    if d <= 1.3 then
                        local c
                        if d > 1 then
                            c = R[1]
                        elseif v < 0 then
                            c = (u < 0) and R[n] or R[n - 1]
                        else
                            c = (u < 0) and R[n - 2] or R[max(1, n - 3)]
                        end
                        p:dot(x + px, y + py, c, a)
                    end
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Lights：闪一下就没的灯
-- ---------------------------------------------------------------------------
local Lights = {}
Lights.__index = Lights
Sim.Lights = Lights

function Sim.newLights()
    return setmetatable({ list = {} }, Lights)
end

function Lights:add(x, y, r, color, k, life)
    self.list[#self.list + 1] = { x = x, y = y, r = r, color = Core.hex(color), k = k, life = life, max = life }
end

function Lights:update(dt)
    for i = #self.list, 1, -1 do
        local l = self.list[i]
        l.life = l.life - dt
        if l.life <= 0 then
            table.remove(self.list, i)
        end
    end
end

function Lights:count()
    return #self.list
end

function Lights:draw(p)
    for _, l in ipairs(self.list) do
        local k = l.life / l.max
        p:glow(l.x, l.y, l.r * (0.55 + 0.45 * k), l.color, l.k * k * k)
    end
end

-- ---------------------------------------------------------------------------
-- 画法：star / flare / band / crystal
-- ---------------------------------------------------------------------------

--- 十字星芒：臂长 arm，芯白，带光
function Sim.sparkle(p, x, y, arm, c, tip, k)
    tip = tip or c
    k = k or 0.6
    local n = floor(arm + 0.5)
    if n < 1 then
        return
    end
    local X, Y = floor(x), floor(y)
    for d = 1, n do
        local cc = (d > n * 0.6) and tip or c
        for i = 1, 4 do
            p:px(X + CROSS[i][1] * d, Y + CROSS[i][2] * d, cc)
        end
    end
    if n >= 3 then
        for i = 1, 4 do
            p:px(X + DIAG[i][1], Y + DIAG[i][2], c)
        end
    end
    if n >= 6 then
        for i = 1, 4 do
            p:px(X + DIAG[i][1] * 2, Y + DIAG[i][2] * 2, tip)
        end
    end
    p:px(X, Y, Core.WHITE)
    p:glow(x, y, 4 + n * 2, c, k)
end

--- 八道光晕：轴向长、斜向短，沿长度衰减
function Sim.flare(p, x, y, L, k, rampList)
    if L < 1 then
        return
    end
    local R = ramp(rampList)
    local n = #R
    for i = 0, 7 do
        local an = (i * pi) / 4
        local len = (i % 4 == 0) and L or ((i % 2 == 0) and L * 0.6 or L * 0.3)
        local ca, sa = cos(an), sin(an)
        local d = 0
        while d <= len do
            local u = d / len
            local c = (u < 0.35) and Core.WHITE or ((u < 0.7) and R[n - 1] or R[n - 2])
            p:dot(x + ca * d, y + sa * d, c, (u < 0.6) and 1 or (k * 1.5 * (1 - u) + 0.2))
            d = d + 0.5
        end
    end
end

--- 倾斜平面上的一圈（sy 压扁：0.16 躺地上，1 立起来），th 向内厚度
--- keep(ang) 决定画哪一段：(ang) => sin(ang) < 0 是远半圈
function Sim.band(p, cx, cy, r, sy, th, k, rampList, keep, hot)
    if r <= 0 or k <= 0 then
        return
    end
    local R = ramp(rampList)
    local n = #R
    local m = ceil(r * MathX.TAU * 1.2)
    for j = 0, m - 1 do
        local ang = (j / m) * MathX.TAU
        local ca, sa = cos(ang), sin(ang)
        if keep == nil or keep(ang) then
            local o = th
            while o >= 0 do
                local u = o / th
                local c
                if u < 0.15 then
                    c = hot and Core.WHITE or R[n]
                elseif u < 0.4 then
                    c = R[n - 1]
                elseif u < 0.7 then
                    c = R[n - 2]
                else
                    c = R[n - 3]
                end
                p:dot(cx + ca * (r - o), cy + sa * (r - o) * sy, c, k * ((u < 0.4) and 1.2 or (1.15 - u)))
                o = o - 0.5
            end
        end
    end
end

--- 立在 (x, base) 上的棱面晶体：高 h，底宽 w，尖端偏 lean，ramp 由暗到亮
--- opts: { a, white, glint }
function Sim.crystal(p, x, base, h, w, lean, rampList, opts)
    opts = opts or {}
    if h < 1.5 then
        return
    end
    local R = ramp(rampList)
    local n = #R
    local function C(i)
        return R[max(1, n - i)]
    end
    local a = opts.a or 1
    local top = base - h
    local ridge0 = x - w * 0.14
    local glint = opts.glint or -1
    local function inside(px, py)
        local u = (base - (py + 0.5)) / h
        return u >= 0 and u <= 1 and abs(px + 0.5 - (x + lean * u)) <= (w / 2) * (1 - u) + 0.35
    end
    for py = floor(top) - 1, ceil(base) - 1 do
        for px = floor(x - w / 2 - abs(lean) - 2), ceil(x + w / 2 + abs(lean) + 2) do
            if not inside(px, py) then
                if inside(px - 1, py) or inside(px + 1, py) or inside(px, py + 1) or (inside(px, py - 1) and py < base - 1) then
                    p:dot(px, py, R[1], a)
                end
            elseif opts.white then
                p:dot(px, py, Core.WHITE, a)
            else
                local u = (base - (py + 0.5)) / h
                local rx = ridge0 + (x + lean - ridge0) * u
                local c = x + lean * u
                local hw = (w / 2) * (1 - u) + 0.35
                local fx = px + 0.5
                local col
                if u > 0.9 then
                    col = Core.WHITE
                elseif abs(fx - rx) < 0.55 then
                    col = C(1)
                elseif fx < rx then
                    if fx - (c - hw) < 1 then
                        col = C(1)
                    elseif (fx - (c - hw)) / max(1, rx - (c - hw)) > 0.55 then
                        col = C(2)
                    else
                        col = C(3)
                    end
                else
                    if c + hw - fx < 1.2 then
                        col = C(min(n - 1, 6))
                    elseif (fx - rx) / max(1, c + hw - rx) > 0.5 then
                        col = C(5)
                    else
                        col = C(4)
                    end
                end
                if glint >= 0 and fx <= rx + 0.6 then
                    local g = abs(u - glint)
                    if g < 0.05 then
                        col = Core.WHITE
                    elseif g < 0.1 then
                        col = C(1)
                    end
                end
                p:dot(px, py, col, a)
            end
        end
    end
end

return Sim
