-- ============================================================================
-- view/px/Math.lua — pixelfx `src/core/math.js` 的移植
--
-- 这层的全部难度在 32 位整数语义：JS 的 hash/mulberry32 用的是 Math.imul（有符号 32 位
-- 乘法取低位）和 `>>>`（无符号右移）。Lua 5.4 是 64 位整数，所以：
--   * imul(a, b) = 先把 a/b 当有符号 32 位，相乘（|积| < 2^62，不溢出 int64），再取低 32 位
--   * 全程把中间值保持在无符号 32 位（& 0xFFFFFFFF），`>>` 就等价于 JS 的 `>>>`
--   * `n | 0` = JS 的 ToInt32 = 先 trunc 再绕回 32 位
-- 只要这几条对上，rand / noise / Rng 序列和 JS 逐个相同，特效才能逐像素一致。
-- ============================================================================

local M = {}

local floor, abs, sin, cos, pi = math.floor, math.abs, math.sin, math.cos, math.pi

M.TAU = pi * 2

local function u32(v)
    return v & 0xFFFFFFFF
end

--- JS Math.imul：有符号 32 位乘法取低 32 位（返回无符号）
function M.imul(a, b)
    a = u32(a)
    b = u32(b)
    if a >= 0x80000000 then
        a = a - 0x100000000
    end
    if b >= 0x80000000 then
        b = b - 0x100000000
    end
    return u32(a * b)
end

--- JS 的 ToInt32：先向零截断（不是 floor），再绕回 32 位
local function toInt32(v)
    local t = (v < 0) and math.ceil(v) or floor(v)
    return u32(t)
end

function M.clamp(x, a, b)
    a = a or 0
    b = b or 1
    if x < a then
        return a
    end
    if x > b then
        return b
    end
    return x
end

function M.lerp(a, b, t)
    return a + (b - a) * t
end

function M.invLerp(a, b, x)
    if b == a then
        return 0
    end
    return (x - a) / (b - a)
end

function M.remap(x, a0, a1, b0, b1)
    return M.lerp(b0, b1, M.invLerp(a0, a1, x))
end

function M.fract(x)
    return x - floor(x)
end

function M.wrap(x, m)
    return ((x % m) + m) % m
end

function M.seg(t, t0, t1)
    return M.clamp((t - t0) / (t1 - t0))
end

function M.smooth(e0, e1, x)
    local t = M.seg(x, e0, e1)
    return t * t * (3 - 2 * t)
end

function M.bump(t, t0, t1)
    if t <= t0 or t >= t1 then
        return 0
    end
    return sin(pi * M.seg(t, t0, t1))
end

function M.pingpong(x)
    return 1 - abs(M.wrap(x, 2) - 1)
end

function M.dist(x0, y0, x1, y1)
    local dx, dy = x1 - x0, y1 - y0
    return math.sqrt(dx * dx + dy * dy)
end

function M.angleTo(x0, y0, x1, y1)
    return math.atan(y1 - y0, x1 - x0)
end

local ease = {}
ease.linear = function(t)
    return t
end
ease.inQuad = function(t)
    return t * t
end
ease.outQuad = function(t)
    return 1 - (1 - t) * (1 - t)
end
ease.inOutQuad = function(t)
    if t < 0.5 then
        return 2 * t * t
    end
    return 1 - (-2 * t + 2) ^ 2 / 2
end
ease.inCubic = function(t)
    return t * t * t
end
ease.outCubic = function(t)
    return 1 - (1 - t) ^ 3
end
ease.inOutCubic = function(t)
    if t < 0.5 then
        return 4 * t * t * t
    end
    return 1 - (-2 * t + 2) ^ 3 / 2
end
ease.inQuart = function(t)
    return t * t * t * t
end
ease.outQuart = function(t)
    return 1 - (1 - t) ^ 4
end
ease.inExpo = function(t)
    if t <= 0 then
        return 0
    end
    return 2 ^ (10 * t - 10)
end
ease.outExpo = function(t)
    if t >= 1 then
        return 1
    end
    return 1 - 2 ^ (-10 * t)
end
ease.inSine = function(t)
    return 1 - cos(t * pi / 2)
end
ease.outSine = function(t)
    return sin(t * pi / 2)
end
ease.inOutSine = function(t)
    return -(cos(pi * t) - 1) / 2
end
ease.inBack = function(t, s)
    s = s or 1.70158
    if t <= 0 then
        return 0
    elseif t >= 1 then
        return 1
    end
    return (s + 1) * t * t * t - s * t * t
end
ease.outBack = function(t, s)
    s = s or 1.70158
    if t <= 0 then
        return 0
    elseif t >= 1 then
        return 1
    end
    return 1 + (s + 1) * (t - 1) ^ 3 + s * (t - 1) ^ 2
end
ease.outElastic = function(t)
    if t <= 0 then
        return 0
    elseif t >= 1 then
        return 1
    end
    return 2 ^ (-10 * t) * sin((t * 10 - 0.75) * ((2 * pi) / 3)) + 1
end
ease.outBounce = function(t)
    local n, d = 7.5625, 2.75
    if t < 1 / d then
        return n * t * t
    end
    if t < 2 / d then
        t = t - 1.5 / d
        return n * t * t + 0.75
    end
    if t < 2.5 / d then
        t = t - 2.25 / d
        return n * t * t + 0.9375
    end
    t = t - 2.625 / d
    return n * t * t + 0.984375
end
M.ease = ease

--- 32 位整数哈希（任意个整数参数）
function M.hash(...)
    local h = 0x9e3779b9
    for i = 1, select("#", ...) do
        local v = toInt32((select(i, ...)))
        h = M.imul(h ~ v, 0x85ebca6b)
        h = h ~ (h >> 13)
        h = M.imul(h, 0xc2b2ae35)
        h = h ~ (h >> 16)
    end
    return u32(h)
end

--- [0, 1) 的确定性随机：同样的整数参数永远同一个值
function M.rand(...)
    return M.hash(...) / 4294967296
end

--- mulberry32
local Rng = {}
Rng.__index = Rng

function M.newRng(seed)
    local s = u32(floor(seed or 1))
    if s == 0 then
        s = 1
    end
    return setmetatable({ s = s }, Rng)
end

function Rng:next()
    local s = u32(self.s + 0x6d2b79f5)
    self.s = s
    local t = s
    t = M.imul(t ~ (t >> 15), t | 1)
    t = t ~ u32(t + M.imul(t ~ (t >> 7), t | 61))
    return u32(t ~ (t >> 14)) / 4294967296
end

function Rng:range(a, b)
    return a + (b - a) * self:next()
end

function Rng:int(a, b)
    return floor(self:range(a, b + 1))
end

function Rng:chance(p)
    return self:next() < p
end

function Rng:sign()
    if self:next() < 0.5 then
        return -1
    end
    return 1
end

function Rng:pick(list)
    return list[floor(self:next() * #list) + 1]
end

function Rng:gauss()
    return (self:next() + self:next() + self:next() + self:next() - 2) * 1.732
end

M.Rng = Rng

--- rng(seed, i)：同一颗粒子每帧拿到同一串数
function M.rng(...)
    return M.newRng(M.hash(...))
end

--- 一维平滑值噪声 [-1, 1]
function M.noise(x, seed)
    seed = seed or 0
    local i = floor(x)
    local f = x - i
    local u = f * f * (3 - 2 * f)
    return M.lerp(M.rand(i, seed), M.rand(i + 1, seed), u) * 2 - 1
end

--- 二维平滑值噪声
function M.noise2(x, y, seed)
    seed = seed or 0
    local ix, iy = floor(x), floor(y)
    local fx, fy = x - ix, y - iy
    local ux = fx * fx * (3 - 2 * fx)
    local uy = fy * fy * (3 - 2 * fy)
    local a = M.rand(ix, iy, seed)
    local b = M.rand(ix + 1, iy, seed)
    local c = M.rand(ix, iy + 1, seed)
    local d = M.rand(ix + 1, iy + 1, seed)
    return M.lerp(M.lerp(a, b, ux), M.lerp(c, d, ux), uy) * 2 - 1
end

function M.fbm(x, y, seed, octaves)
    seed = seed or 0
    octaves = octaves or 3
    local s, a, n = 0, 0.5, 0
    for o = 0, octaves - 1 do
        s = s + M.noise2(x, y, seed + o * 101) * a
        n = n + a
        x = x * 2.03
        y = y * 2.03
        a = a * 0.5
    end
    return s / n
end

--- 按 px/py 格重复的二维噪声：循环里滚整数格就没有接缝
function M.tileNoise(x, y, px, py, seed)
    px, py, seed = px or 0, py or 0, seed or 0
    local ix, iy = floor(x), floor(y)
    local fx, fy = x - ix, y - iy
    local ux = fx * fx * (3 - 2 * fx)
    local uy = fy * fy * (3 - 2 * fy)
    local x0 = (px ~= 0) and M.wrap(ix, px) or ix
    local x1 = (px ~= 0) and M.wrap(ix + 1, px) or ix + 1
    local y0 = (py ~= 0) and M.wrap(iy, py) or iy
    local y1 = (py ~= 0) and M.wrap(iy + 1, py) or iy + 1
    local a = M.rand(x0, y0, seed)
    local b = M.rand(x1, y0, seed)
    local c = M.rand(x0, y1, seed)
    local d = M.rand(x1, y1, seed)
    return M.lerp(M.lerp(a, b, ux), M.lerp(c, d, ux), uy) * 2 - 1
end

function M.tileFbm(x, y, px, py, seed, octaves)
    px, py, seed = px or 0, py or 0, seed or 0
    octaves = octaves or 3
    local s, a, n, k = 0, 0.5, 0, 1
    for o = 0, octaves - 1 do
        s = s + M.tileNoise(x * k, y * k, px * k, py * k, seed + o * 101) * a
        n = n + a
        a = a * 0.5
        k = k * 2
    end
    return s / n
end

function M.loopNoise(phase, radius, seed)
    radius = radius or 1
    seed = seed or 0
    local a = phase * M.TAU
    return M.noise2(cos(a) * radius + 50, sin(a) * radius + 50, seed)
end

-- ---------------------------------------------------------------------------
-- src/core/particles.js —— 闭式（不用模拟）的粒子轨迹与循环发射
-- ---------------------------------------------------------------------------

--- 抛体位置：初速 (vx, vy)，重力 g，线性阻尼 drag
function M.fly(x, y, vx, vy, t, g, drag)
    g = g or 0
    drag = drag or 0
    if drag <= 0 then
        return x + vx * t, y + vy * t + 0.5 * g * t * t
    end
    local f = (1 - math.exp(-drag * t)) / drag
    local vt = g / drag
    return x + vx * f, y + vt * t + (vy - vt) * f
end

function M.flyV(vx, vy, t, g, drag)
    g = g or 0
    drag = drag or 0
    if drag <= 0 then
        return vx, vy + g * t
    end
    local e = math.exp(-drag * t)
    local vt = g / drag
    return vx * e, vt + (vy - vt) * e
end

--- n 个一次性粒子：fn(r, i)，r 是每颗粒子可复现的 rng
function M.burst(n, seed, fn)
    for i = 0, n - 1 do
        fn(M.rng(seed, i), i)
    end
end

--- 每 period 秒重复一批的粒子（无缝循环用）。life 是数字或 function(r)
function M.cycle(t, period, count, seed, life, fn)
    for i = 0, count - 1 do
        local g = M.rng(seed, i, 911)
        local born = g:next() * period
        local L = (type(life) == "function") and life(g) or life
        local age = M.wrap(t - born, period)
        while age < L do
            fn(age, L, M.rng(seed, i), i)
            age = age + period
        end
    end
end

--- 在 [t0, t1] 里匀速发射（发射器会停）：rate 是每秒颗粒数
function M.stream(t, t0, t1, rate, seed, life, fn)
    local n = floor((math.min(t, t1) - t0) * rate)
    for i = 0, n do
        local born = t0 + i / rate
        local g = M.rng(seed, i, 911)
        local L = (type(life) == "function") and life(g) or life
        local age = t - born
        if age >= 0 and age < L then
            fn(age, L, M.rng(seed, i), i)
        end
    end
end

return M
