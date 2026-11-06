-- ============================================================================
-- view/px/HitSpark.lua — impacts/hit-spark 的 Lua 版（粒子套件的验收样本）
--
-- 原版：.tmp/pixelfx/src/fx/impacts/hit-spark.js
-- 这个特效把粒子套件能踩的坑都踩了一遍：Rng 序列、Particles 的 SPARK/GRIT 两套物理
-- （含地面弹跳 + 随机判定）、Lights 的平方衰减、以及 create(o) 这种有状态的写法。
-- 所以它是「粒子套件是否移植成功」的判据。
-- ============================================================================

local Core = require "tap-pixelfx.core.Core"
local MathX = require "tap-pixelfx.core.Math"
local Sim = require "tap-pixelfx.core.Sim"

local HitSpark = {}

local floor, ceil, abs, sin, cos, sqrt, min, max, pi = math.floor, math.ceil, math.abs, math.sin, math.cos,
    math.sqrt, math.min, math.max, math.pi

HitSpark.meta = {
    name = "Hit spark",
    size = { 136, 80 },
    origin = { 44, 64 },
    duration = 0.5,
    loop = false,
    fps = 30,
    options = {
        palette = { "#4a1712", "#c9281f", "#f2561d", "#ff8a2a", "#ffe26b", "#fff3a6", "#ffffff" },
        height = 20,
        aim = 0.1,
        seed = 4,
    },
}

local P = Sim.P

--- 十字的一道光：根部粗、尖端细，从白往色带里凉下去；from..to 只画中间一段
local function ray(p, x, y, a, L, w, C, from)
    from = from or 0
    local c, s = cos(a), sin(a)
    local d = from * L
    while d <= L do
        local u = d / L
        local hw = w * (1 - u) ^ 1.6
        local col
        if u < 0.3 then
            col = Core.WHITE
        elseif u < 0.62 then
            col = C[6]
        elseif u < 0.88 then
            col = C[5]
        else
            col = C[4]
        end
        p:px(x + c * d, y + s * d, col)
        if hw > 0.45 then
            local o = 0.5
            while o <= hw do
                local cc = (u < 0.3 and o < 1) and C[6] or C[5]
                p:px(x + c * d - s * o, y + s * d + c * o, cc)
                p:px(x + c * d + s * o, y + s * d - c * o, cc)
                o = o + 0.5
            end
        end
        d = d + 0.5
    end
end

--- 芯：干净的白色菱形，外圈一道淡边
local function diamond(p, x, y, r, C)
    for dy = -r - 1, r + 1 do
        for dx = -r - 1, r + 1 do
            local m = abs(dx) + abs(dy)
            if m <= r then
                p:px(x + dx, y + dy, Core.WHITE)
            elseif m == r + 1 then
                p:px(x + dx, y + dy, C[4])
            end
        end
    end
end

--- 建一个实例（对齐 createFx：dt 一律细分到 120Hz 以上再步进）
function HitSpark.new(opts)
    opts = opts or HitSpark.meta.options
    local C = Core.fit(opts.palette, 7)
    local R = MathX.newRng(opts.seed)
    local X, Y, A = 0, -(opts.height), opts.aim
    local ps = Sim.newParticles({ rng = R, ground = function() return 0 end, sparks = { C[7], C[6], C[5], C[3] } })
    local lights = Sim.newLights()

    -- 十字：沿打击方向一道长光、身后一截、两侧两条不等长的臂、一道斜的碎光
    local tilt = R:range(-0.08, 0.08)
    local rays = {
        { a = A + tilt, L = R:range(33, 37), w = 2.2 },
        { a = A + pi + tilt, L = R:range(8, 10), w = 2.2 },
        { a = A - pi / 2 + tilt, L = R:range(15, 18), w = 2.6 },
        { a = A + pi / 2 + tilt, L = R:range(10, 12), w = 2.3 },
        { a = A - pi / 4 + tilt, L = R:range(5, 7), w = 1 },
    }
    lights:add(X, Y, 38, C[5], 0.35, 0.18)
    lights:add(X + cos(A) * 10, Y + sin(A) * 10, 22, C[6], 0.45, 0.1)
    lights:add(X, -2, 26, C[4], 0.22, 0.22)

    -- 沿打击方向喷一锥火花：会落、会在地上弹、会死
    for i = 0, 8 do
        local a = A + R:range(-0.6, 0.6) - 0.15
        local v = R:range(170, 360)
        local life = R:range(0.25, 0.45)
        local delay = (i > 6) and R:range(0.01, 0.03) or 0
        ps:spawn(P.SPARK, X + 1, Y, cos(a) * v, sin(a) * v - 40, life, Core.WHITE, 1, delay)
    end
    -- 崩下来的热铁屑，翻滚落地后挑一下地面
    local chipCols = { C[6], C[5], C[5], C[4] }
    for i = 0, 5 do
        local a = A + R:range(-1.1, 0.5) - 0.3
        local v = R:range(70, 170)
        -- ⚠️ 这里的取值顺序必须和 JS 的实参求值顺序一字不差，否则 Rng 序列就错位了：
        -- JS 是 cos/sin 里先算 range(30,80)，再 range(0.35,0.45)，最后 pick()
        local vy = sin(a) * v - R:range(30, 80)
        local life = R:range(0.35, 0.45)
        local col = R:pick(chipCols)
        ps:spawn(P.GRIT, X + 1, Y, cos(a) * v, vy, life, col, 1)
    end

    local self = { t = 0, ps = ps, lights = lights, rays = rays, C = C, X = X, Y = Y, A = A }
    return setmetatable(self, { __index = HitSpark })
end

function HitSpark:update(dt)
    self.t = self.t + dt
    local n = max(1, ceil(dt * 120 - 1e-9))
    for _ = 1, n do
        self.ps:update(dt / n)
    end
    self.lights:update(dt)
end

function HitSpark:draw(p)
    local C, X, Y, A, t = self.C, self.X, self.Y, self.A, self.t
    self.ps:draw(p)
    if t < 0.025 then
        for _, r in ipairs(self.rays) do
            ray(p, X, Y, r.a, r.L, r.w, C)
        end
        diamond(p, X, Y, 4, C)
    elseif t < 0.058 then
        for _, r in ipairs(self.rays) do
            ray(p, X, Y, r.a, r.L * 1.2, r.w * 0.55, C, 0.12)
        end
        diamond(p, X, Y, 3, C)
    elseif t < 0.092 then
        local r = self.rays[1]
        ray(p, X, Y, r.a, r.L * 1.3, 0.6, { C[1], C[2], C[3], C[4], C[4], C[5] }, 0.4)
    end
    local pop = math.exp(-t / 0.045)
    if pop > 0.02 then
        p:glow(X, Y, 22, C[5], 0.3 * pop)
        p:glow(X, Y, 7, Core.WHITE, 0.15 * pop)
        p:glowLine(X, Y, X + cos(A) * 26, Y + sin(A) * 26, 4, C[6], 0.25 * pop)
    end
    self.lights:draw(p)
end

return HitSpark
