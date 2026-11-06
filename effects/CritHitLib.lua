-- ============================================================================
-- fx/effects/CritHitLib.lua — impacts/_lib.js 里 crit-hit 用得到的那三个画法
--
-- 原版：pixelfx src/fx/impacts/_lib.js 的 spikes / star / brokenRing
-- 这三个是「打击系」特效共用的刀法，但各自带一点点状态约定（spikes 返回尖刺表、
-- brokenRing 吃 segs 表），所以放在特效私有的 lib 里，不去动共享的 Shapes/Sim。
--
-- 和 Core 的 Painter 一样，全部用 dot 画（有序抖动淡出），所以同一个 t 重放出来逐像素相同。
-- ============================================================================

local Core = require "tap-pixelfx.core.Core"
local MathX = require "tap-pixelfx.core.Math"
local Sim = require "tap-pixelfx.core.Sim"

local CritHitLib = {}

local floor, ceil, sqrt, sin, cos, abs, min, max, pi = math.floor, math.ceil, math.sqrt, math.sin, math.cos,
    math.abs, math.min, math.max, math.pi
local TAU = pi * 2

-- ---------------------------------------------------------------------------
-- Glints：环断之后在四周闪的十字星
--
-- 这几个本来是 Particles 的 P.STAR 粒子，但共享的 Sim.lua 在「default 分支」把
-- JS 的 `p.vy -= p.vy * drag * dt + 5 * dt` 写成了 `p.vy = p.vy - p.vy * drag * dt + 5 * dt`
-- （符号反了，等于往上飘 10*dt），STAR 恰好落在这个分支里，逐帧累积就飘错了位置。
-- 按移植约定不去改共享文件，所以这里把 STAR 的物理 + 画法原样私有一份，
-- RNG 的消耗点也照抄（spawn 内部那次 next() 用来做 seed），其余粒子仍走 Particles。
-- 等 Sim.lua 修好后，这段可以删掉换回 ps:spawn(Sim.P.STAR, ...)。
-- ---------------------------------------------------------------------------
local Glints = {}
Glints.__index = Glints
CritHitLib.Glints = Glints

function CritHitLib.newGlints()
    return setmetatable({ list = {}, t = 0 }, Glints)
end

--- 对齐 Particles:spawn：实参先算完，最后才消耗一次 Rng 当 seed
function Glints:add(x, y, vx, vy, life, col, size, delay, R)
    self.list[#self.list + 1] = {
        x = x,
        y = y,
        vx = vx,
        vy = vy,
        life = life,
        max = life,
        col = Core.hex(col),
        size = size,
        delay = delay,
        seed = R:next() * 100,
    }
end

function Glints:update(dt)
    self.t = self.t + dt
    local list = self.list
    for i = #list, 1, -1 do
        local q = list[i]
        if q.delay > 0 then
            q.delay = q.delay - dt
        else
            q.life = q.life - dt
            if q.life <= 0 then
                table.remove(list, i)
            else
                -- sim.js 的 default 分支：drag 1.6，外加一个恒定的 -5 上飘
                q.vx = q.vx - q.vx * 1.6 * dt
                q.vy = q.vy - (q.vy * 1.6 * dt + 5 * dt)
                q.x = q.x + q.vx * dt
                q.y = q.y + q.vy * dt
            end
        end
    end
end

function Glints:draw(p)
    for _, q in ipairs(self.list) do
        if q.delay <= 0 then
            local k = q.life / q.max
            -- 闪烁系数：频率和相位都由粒子自己的 seed 决定
            local tw = 0.6 + 0.4 * sin(self.t * (8 + (q.seed % 5)) + q.seed)
            if q.size < 1 then
                if tw * k > 0.25 then
                    p:px(q.x, q.y, (tw > 0.8) and Core.WHITE or q.col)
                end
                p:glow(q.x, q.y, 3, q.col, 0.4 * k * tw)
            else
                Sim.sparkle(p, q.x, q.y, q.size * tw * min(1, k * 3), q.col, Core.scale(q.col, 0.75), 0.5 * k * tw)
            end
        end
    end
end

--- 打击星芒的尖刺表：n 根绕一圈，朝 aim 方向更长（fwd），背向也略长（back）
--- o: { len={min,max}, w={min,max} 根部半宽, fwd, back, jag（隔一根缩短，做锯齿）, jit（角度抖动） }
---@return table[] { a, len, w }
function CritHitLib.spikes(R, n, aim, o)
    o = o or {}
    local len, w = o.len or { 7, 10 }, o.w or { 1.5, 2.1 }
    local fwd, back = o.fwd or 1.8, o.back or 0.6
    local jag, jit = o.jag or 1, o.jit or 0.18
    local out = {}
    for i = 0, n - 1 do
        -- ⚠️ RNG 顺序 = 原版 Array.from 回调里「角度抖动 → 长度 → 半宽」的求值顺序，
        -- 三项都是 R.range，挪一下位置整条曲线就变味了
        local a = aim + (i / n) * TAU + R:range(-jit, jit)
        local cb = cos(a - aim)
        local odd = (i % 2) ~= 0
        local L = R:range(len[1], len[2])
            * (1 + fwd * max(0, cb) ^ 3 + back * max(0, -cb) ^ 3)
            * (odd and jag or 1)
        out[i + 1] = {
            a = a,
            len = L,
            w = R:range(w[1], w[2]) * (odd and sqrt(jag) or 1),
        }
    end
    return out
end

--- 一颗打击星：尖刺画三遍（外沿色 → 本体色（根部更淡）→ 炽白芯），中间一颗热核
--- cols = { rim, body, inner, core }；sc 拉长尖刺，th 收细，a 是抖动淡出的 alpha，heart 是核心半径基数
function CritHitLib.star(p, x, y, list, sc, th, cols, a, heart)
    a = a or 1
    heart = heart or 2.4
    local rim, body, inner, core = cols[1], cols[2], cols[3], cols[4]
    for pass = 0, 2 do
        for _, s in ipairs(list) do
            local c, sn = cos(s.a), sin(s.a)
            local L = s.len * sc
            local d = 0
            while d <= L do
                if pass == 2 and d > L * 0.55 then
                    break
                end
                -- 根部收细的铁律：越靠近尖端越窄，根部再乘一个 0.5 的起头
                local hw0 = s.w * th * (1 - d / L) * min(1, 0.5 + d / 3)
                local hw, col
                if pass == 0 then
                    hw, col = hw0 + 0.8, rim
                elseif pass == 1 then
                    hw = hw0
                    col = (d < L * 0.35) and inner or body
                else
                    hw, col = hw0 * 0.45, core
                end
                local o = -hw
                while o <= hw do
                    p:dot(x + c * d - sn * o, y + sn * d + c * o, col, a)
                    o = o + 0.5
                end
                d = d + 0.5
            end
        end
    end
    local r = heart * sc * sqrt(th)
    p:circle(x, y, r + 0.8, inner, a)
    p:circle(x, y, r, core, a)
end

--- 会断成弧段飞散的环：segs = { a（段中心角）, gap（0..1 缺口）, dr（自己往外飞的速度）, w（粗细倍率） }
--- brk 0 画成一个整环，brk 越大每段越短、两端收成月牙、各段按 dr 往外飘；c 外沿色，c2 内沿色；
--- sy 把环压扁到地面；maxY 以下不画（地板）
function CritHitLib.brokenRing(p, x, y, r, th, segs, brk, c, c2, k, sy, maxY)
    if c2 == nil then
        c2 = c
    end
    k = k or 1
    sy = sy or 1
    if maxY == nil then
        maxY = math.huge
    end
    if r <= 0 or k <= 0 then
        return
    end
    local full = TAU / #segs
    for _, s in ipairs(segs) do
        local span = full * (1 - s.gap * brk) + 0.02
        local rr = r * (1 + s.dr * brk)
        local m = max(4, ceil(rr * span * 1.8))
        for j = 0, m do
            local u = j / m
            local ang = s.a + (u - 0.5) * span
            -- 段越断越薄：中间厚、两端收尖
            local w = max(0.5, th * (s.w or 1) * (1 - brk * abs(2 * u - 1) ^ 1.6))
            local ca, sa = cos(ang), sin(ang)
            local o = -w / 2
            while o <= w / 2 + 0.01 do
                if y + sa * (rr + o) * sy < maxY then
                    p:dot(x + ca * (rr + o), y + sa * (rr + o) * sy, o > -0.26 and c or c2, k)
                end
                o = o + 0.5
            end
        end
    end
end

return CritHitLib
