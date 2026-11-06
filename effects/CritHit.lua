-- ============================================================================
-- fx/effects/CritHit.lua — impacts/crit-hit 的 Lua 版
--
-- 原版：pixelfx src/fx/impacts/crit-hit.js（尖刺星 / 断环 / 火花的部分来自 impacts/_lib.js）
-- 长什么样：一记暴击砸下来。先是一颗锯齿星芒「砸进画面」——一帧全白、随后过冲、回落、
-- 再碎掉；同一瞬间一圈光环从星芒上胀开并断成一节节往外飞的弧，火花成串地往外拉线，
-- 亮片翻滚落地弹跳，一束镜头光斑在星芒塌缩时绽开，最后是一团大 flare 收尾。整体约 0.9 秒。
-- 游戏里什么时候放：暴击 / 处决 / 重击命中的那一帧，放在攻击点（怪物身上），
-- 配合屏幕轻震和音效。
-- ============================================================================

local Core = require "tap-pixelfx.core.Core"
local MathX = require "tap-pixelfx.core.Math"
local Sim = require "tap-pixelfx.core.Sim"
local Lib = require "tap-pixelfx.effects.CritHitLib"

local CritHit = {}

local ceil, sin, cos, min, max, pi = math.ceil, math.sin, math.cos, math.min, math.max, math.pi
local TAU = pi * 2

CritHit.meta = {
    name = "Critical hit",
    desc = "A critical hit: a jagged starburst slams in white and overshoots, a ring breaks into flying arcs, sparks streak off, shards tumble to the floor under a big flare.",
    tags = { "impact", "hit", "crit", "critical", "combat", "directional", "one-shot" },
    size = { 216, 136 },
    origin = { 84, 106 },
    duration = 0.9,
    loop = false,
    fps = 30,
    bg = "ground",
    options = {
        palette = { "#2a0510", "#5c0a1c", "#a3142a", "#e0302c", "#ff7a2a", "#ffc23d", "#fff09a", "#ffffff" },
        height = 26,
        aim = 0.12,
        seed = 3,
    },
}

-- 星芒的关键帧：[起始 t, 缩放, 粗细, alpha, 四层颜色（外沿/本体/内层/芯）在色带上的台阶]
local KEYS = {
    { 0, 1, 1, 1, { 6, 7, 7, 7 } },
    { 0.025, 1.3, 1, 1, { 2, 5, 6, 7 } },
    { 0.058, 1.05, 0.72, 1, { 2, 4, 5, 6 } },
    { 0.092, 1.22, 0.3, 1, { 1, 2, 3, 4 } },
    { 0.125 },
}

--- 一道镜头光斑：一条横向长光（中间粗白）、一条短竖光、两道斜的，外加两道光晕
local function flare(p, x, y, L, k, C)
    local arms = { { 1, 0, L }, { 0, 1, L * 0.45 }, { 0.7, 0.7, L * 0.16 }, { 0.7, -0.7, L * 0.16 } }
    for _, arm in ipairs(arms) do
        local dx, dy, len = arm[1], arm[2], arm[3]
        for s = 0, 1 do
            local sign = (s == 0) and -1 or 1
            -- d 是整数步长（原版 for d = 1; d <= len; d++），u 用 d/len
            local d = 1
            while d <= len do
                local u = d / len
                local a = (u < 0.7) and 1 or k * (1.6 - u)
                local col
                if u < 0.35 then
                    col = Core.WHITE
                elseif u < 0.7 then
                    col = C[7]
                else
                    col = C[6]
                end
                p:dot(x + sign * dx * d, y + sign * dy * d, col, a)
                -- 只有横光加粗：上下各一像素
                if dy == 0 and u < 0.42 then
                    local c2 = (u < 0.2) and C[7] or C[6]
                    local a2 = (u < 0.3) and 1 or k
                    p:dot(x + sign * d, y - 1, c2, a2)
                    p:dot(x + sign * d, y + 1, c2, a2)
                end
                d = d + 1
            end
        end
    end
    p:glowLine(x - L, y, x + L, y, 6, C[7], 0.5 * k)
    p:glowLine(x, y - L * 0.45, x, y + L * 0.45, 4, C[7], 0.3 * k)
end

--- 建一个实例（对齐 createFx：dt 先细分到 120Hz 以上，再把每个分步喂给粒子/碎片/灯光）
function CritHit.new(opts)
    opts = opts or CritHit.meta.options
    local C = Core.fit(opts.palette, 8)
    local R = MathX.newRng(opts.seed)
    local X, Y, A = 0, -(opts.height), opts.aim
    local ground = function()
        return 0
    end
    local ps = Sim.newParticles({ rng = R, ground = ground, sparks = { C[8], C[7], C[6], C[4] } })
    local bits = Sim.newBits({ ground = ground })
    local lights = Sim.newLights()

    -- 尖刺：14 根，朝打击方向最长；最长的两根再拉长 1.3 倍（做那对「主角」利爪）
    local sp = Lib.spikes(R, 14, A, { len = { 11, 15 }, w = { 1.8, 2.5 }, fwd = 1.4, back = 0.6, jag = 0.5 })
    -- ⚠️ 原版是 [...sp].sort((a,b) => b.len - a.len)：V8 的 sort 稳定，长度相同的两根相对顺序不变。
    -- Lua 的 table.sort 不稳定，所以排序键里补上原下标，保证「哪两根被拉长」永远一样。
    local order = {}
    for i = 1, #sp do
        order[i] = i
    end
    table.sort(order, function(i, j)
        if sp[i].len ~= sp[j].len then
            return sp[i].len > sp[j].len
        end
        return i < j
    end)
    for n = 1, min(2, #order) do
        local s = sp[order[n]]
        s.len = s.len * 1.3
    end

    -- 断环的 7 段：缺口大小、往外飞的速度、粗细都各自随机（亮的那侧飞得更远更粗）
    local segs = {}
    for i = 0, 6 do
        local a = A + (i / 7) * TAU
        local face = max(0, cos(a - A))
        -- ⚠️ RNG 顺序：先 gap 再 dr，和原版对象字面量一致
        segs[i + 1] = {
            a = a,
            gap = R:range(0.55, 0.85),
            dr = R:range(0.08, 0.4) + 0.15 * face,
            w = 0.7 + 0.5 * face,
        }
    end

    lights:add(X, Y, 84, C[6], 0.6, 0.5)
    lights:add(X, Y, 30, Core.WHITE, 0.7, 0.1)
    lights:add(X, -4, 44, C[5], 0.3, 0.45)

    -- 火花：大半顺着打击方向喷出去，少数往后蹬
    for i = 0, 35 do
        local back = R:chance(0.22)
        local a = (back and (A + pi) or A) + R:range(-1, 1) * (back and 0.6 or 0.8)
        local v = R:range(170, 430) * (back and 0.6 or 1)
        -- ⚠️ life / delay 的取值顺序必须照抄实参顺序（原版的生命值先算，delay 里的 chance 后算），
        -- 换一下顺序 Rng 就整体错位
        local life = R:range(0.15, 0.5)
        local delay = 0
        if R:chance(0.3) then
            delay = R:range(0, 0.04)
        end
        ps:spawn(Sim.P.SPARK, X, Y, cos(a) * v, sin(a) * v - 50, life, Core.WHITE, 1, delay)
    end

    -- 亮片：翻滚、弹地、最后停住；每片自己的自转和角速度
    local shardCols = { C[8], C[7], C[7], C[6] }
    for i = 0, 9 do
        local a = A + R:range(-1, 1) * 1.1 - 0.35
        local v = R:range(110, 280)
        -- ⚠️ 表构造顺序 = 原版对象字面量顺序：life → a → va → s → color
        bits:add({
            kind = Sim.B.SHARD,
            x = X,
            y = Y,
            vx = cos(a) * v,
            vy = sin(a) * v - 40,
            g = 0.8,
            drag = 0.7,
            bounce = 0.35,
            life = R:range(0.55, 0.85),
            a = R:range(0, TAU),
            va = R:range(-25, 25),
            s = R:range(2, 4.5),
            c = R:pick(shardCols),
        })
    end

    -- 往斜上飘走的光尘
    local moteCols = { C[7], C[6], C[6] }
    for i = 0, 11 do
        local a = A - pi / 2 + R:range(-1.4, 1.4)
        local v = R:range(35, 110)
        ps:spawn(Sim.P.MOTE, X + cos(a) * 4, Y + sin(a) * 4, cos(a) * v, sin(a) * v - 15,
            R:range(0.35, 0.7), R:pick(moteCols), 0.6, R:range(0, 0.05))
    end

    -- 环断之后在周围闪几颗十字星（走私有的 Glints，原因见 CritHitLib 顶部那段说明）
    local glints = Lib.newGlints()
    for i = 0, 4 do
        local a = R:range(0, TAU)
        local d = R:range(14, 34)
        -- ⚠️ life / col / size / delay 的求值顺序照抄原版实参顺序，seed 由 add 内部那次 next() 消耗
        glints:add(X + cos(a) * d, Y + sin(a) * d * 0.8, 0, -4,
            R:range(0.22, 0.38), R:chance(0.5) and C[7] or Core.WHITE, R:range(1.6, 3), R:range(0.08, 0.32), R)
    end

    local self = {
        t = 0,
        ps = ps,
        glints = glints,
        bits = bits,
        lights = lights,
        sp = sp,
        segs = segs,
        C = C,
        X = X,
        Y = Y,
    }
    return setmetatable(self, { __index = CritHit })
end

function CritHit:update(dt)
    -- 原版 create(o).update 收到的 dt 已经由 createFx 细分过（每步 <= 1/120），
    -- 这里照抄同样的细分：t 也按分步累加，保证和 JS 的浮点累加顺序一致
    local n = max(1, ceil(dt * 120 - 1e-9))
    local sub = dt / n
    for _ = 1, n do
        self.t = self.t + sub
        self.ps:update(sub)
        self.glints:update(sub)
        self.bits:update(sub)
        self.lights:update(sub)
    end
end

function CritHit:draw(p)
    local C, X, Y, t = self.C, self.X, self.Y, self.t

    -- 光环：从星芒上胀开，随后断成一节节往外飞的弧（越飞越暗、越冷）
    local u = Core.clamp((t - 0.03) / 0.37)
    if t >= 0.03 and u < 1 then
        local r = 10 + 30 * MathX.ease.outCubic(u)
        local brk = MathX.smooth(0.12, 0.6, u)
        local th = max(1, 3.6 * (1 - u) ^ 1.2)
        local i
        if u < 0.12 then
            i = 8
        elseif u < 0.3 then
            i = 7
        elseif u < 0.5 then
            i = 6
        elseif u < 0.75 then
            i = 5
        else
            i = 4
        end
        -- 外沿用当前台阶，内沿退两级（最暗退到第 3 阶）
        Lib.brokenRing(p, X, Y, r, th, self.segs, brk, C[i], C[max(3, i - 2)],
            (u < 0.6) and 1 or (1 - u) / 0.4, 1, 0)
        if u < 0.6 then
            p:glowRing(X, Y, r, 6, C[6], 0.35 * (1 - u / 0.6) ^ 2)
        end
    end

    self.bits:draw(p)
    self.ps:draw(p)
    self.glints:draw(p)

    -- 镜头光斑：星芒塌缩的瞬间绽开
    local f = (t - 0.04) / 0.28
    if f > 0 and f < 1 then
        flare(p, X, Y, 64 * (1 - f) ^ 1.3, 1 - f, C)
        p:glow(X, Y, 56, C[6], 0.4 * (1 - f))
    end

    -- 星芒：全白一帧 → 过冲 → 回落 → 一点点碎掉
    for i = 1, #KEYS - 1 do
        if t >= KEYS[i][1] and t < KEYS[i + 1][1] then
            local k = KEYS[i]
            local cols = {}
            for j = 1, 4 do
                cols[j] = C[k[5][j] + 1]
            end
            Lib.star(p, X, Y, self.sp, k[2], k[3], cols, k[4], 2.6)
        end
    end

    -- 命中瞬间的白热团，指数衰减
    local pop = math.exp(-t / 0.05)
    if pop > 0.02 then
        p:glow(X, Y, 44, C[6], 0.4 * pop)
        p:glow(X, Y, 12, Core.WHITE, 0.6 * pop)
    end
    self.lights:draw(p)
end

return CritHit
