-- ============================================================================
-- fx/effects/PoofLib.lua — spawn/poof 私有的小工具（烟团那一套）
--
-- 原版：pixelfx src/fx/spawn/poof.js 里的 CY / balls 生成 / lines 生成 / radius / drawBall
-- 长什么样：一团胖烟球先被「炸」出去，被阻力硬刹住，边减速边胀大、边轻轻呼吸，
-- 然后一颗颗缩小消失（卡通烟团是一颗一颗灭的，不是整体淡出）。
-- 烟球分三层画（shade → body → cap），邻居之间才会融成一整团疙瘩云，
-- 所以层序只能在 Poof:draw 里一次定好，千万别在外部自己打乱。
--
-- ⚠️ newCloud / newLines 吃的是主实例的 Rng，调用顺序必须和 Poof.new 里的注释一致，
--    否则整条随机序列错位，后面所有粒子的 seed 全变。
-- ============================================================================

local Core = require "tap-pixelfx.core.Core"
local MathX = require "tap-pixelfx.core.Math"

local PoofLib = {}

local sin, cos, min = math.sin, math.cos, math.min

local TAU = MathX.TAU

--- 整团云的「心」的 y（脚底是 0，所以这里是负的）
PoofLib.CY = -17

local CY = PoofLib.CY

--- 一颗烟球现在的半径。
--- 三段叠起来：outBack 弹出来 → 14Hz 的呼吸 → 寿命后 38% 用 inBack 缩没。
--- ⚠️ 它读的是 b.life（update 里已经减过 dt 的那个），所以「剩余寿命」必须精确，
---    顺序错了半径就会差几个像素。
---@param b table
---@return number
function PoofLib.radius(b)
    local age = b.max - b.life
    local u = age / b.max
    local grow = b.r0 + (b.r1 - b.r0) * MathX.ease.outBack(MathX.clamp(age / 0.22), 2)
    local breathe = 1 + 0.06 * sin(age * 14 + b.r1)
    local shrink
    if u < 0.62 then
        shrink = 1
    else
        shrink = 1 - MathX.ease.inBack(MathX.clamp((u - 0.62) / 0.38), 1.4)
    end
    return grow * breathe * shrink
end

--- 画一颗烟球的一层。layer = "shade"（底下那档阴影）/ "body"（本体）/ "cap"（受光的小盖）
--- C 是 fit(palette, 6) 之后的 6 阶色带，这里用的下标对应原版的 C[0..4]。
---@param p table Painter
---@param b table 烟球
---@param layer string
---@param C number[]
function PoofLib.drawBall(p, b, layer, C)
    local age = b.max - b.life
    local r = PoofLib.radius(b)
    local a = min(1, age * 20)
    local lit = age < 0.12
    if r < 0.6 then
        return
    end
    -- 整团云是被上方照亮的：靠下的球压暗一档、靠上的提亮一档
    local hy = (b.y - CY + 6) / 14
    local lo, hi = hy > 0.4, hy < -0.3
    if layer == "shade" then
        local c
        if lit then
            c = C[4]
        elseif lo then
            c = C[2]
        else
            c = C[3]
        end
        p:disc(b.x + r * 0.16, b.y + r * 0.2, r, c, 0.8 * a)
    elseif layer == "body" then
        local c
        if lit then
            c = C[5]
        elseif lo then
            c = C[3]
        else
            c = C[4]
        end
        p:disc(b.x - r * 0.06, b.y - r * 0.08, r * 0.86, c, 0.88 * a)
    elseif not lo or lit then
        -- 顶上的受光盖：刚炸出来那几帧整颗是白的
        local c
        if lit or hi then
            c = Core.WHITE
        else
            c = C[5]
        end
        p:disc(b.x - r * 0.28, b.y - r * 0.34, r * 0.42, c, 0.85 * a)
        if age < 0.25 then
            p:disc(b.x - r * 0.3, b.y - r * 0.38, r * 0.2, Core.WHITE, 0.9 * a * (1 - age / 0.25))
        end
    end
end

--- 整团云：一批胖球 + 中层 + 甩得更远的小碎团（让云边缘是毛的）。
--- ⚠️ 三段循环里的取数顺序就是原版对象字面量的求值顺序（角度 → 速度 → 半径 → 寿命 → 延迟），
---    中间任何一项挪位置，整条 Rng 序列都会错位。cos/sin 不带随机，位置无所谓。
---@param R table Rng
---@return table[]
function PoofLib.newCloud(R)
    local balls = {}

    -- 一圈 9 颗胖球：围着核心炸出去，被阻力刹住，边减速边胀大
    local ring = 9
    for i = 0, ring - 1 do
        local a = (i / ring) * TAU + R:range(-0.2, 0.2)
        local sp = R:range(95, 140)
        local r = R:range(5, 7)
        local life = R:range(0.7, 1.05)
        local delay = R:range(0, 0.03)
        local ca, sa = cos(a), sin(a)
        balls[#balls + 1] = {
            x = ca * 3,
            y = CY + sa * 3,
            vx = ca * sp,
            vy = sa * sp * 0.8 - 12,
            r0 = r * 0.5,
            r1 = r,
            life = life,
            delay = delay,
            max = life,
        }
    end

    -- 中层 5 颗：慢、飘、活得更久，把云填满
    for i = 0, 4 do
        local a = R:range(0, TAU)
        local sp = R:range(20, 60)
        local r1 = R:range(6.5, 8.5)
        local life = R:range(0.85, 1.2)
        local delay = R:range(0.02, 0.06)
        local ca, sa = cos(a), sin(a)
        balls[#balls + 1] = {
            x = ca * 2,
            y = CY + sa * 2,
            vx = ca * sp,
            vy = sa * sp - 16,
            r0 = 4,
            r1 = r1,
            life = life,
            delay = delay,
            max = life,
        }
    end

    -- 外围 7 颗小的：甩得远、死得快，云边上就是被它们啃出毛边的
    for i = 0, 6 do
        local a = R:range(0, TAU)
        local sp = R:range(170, 240)
        local r = R:range(2.2, 3.6)
        local life = R:range(0.32, 0.5)
        local delay = R:range(0.01, 0.04)
        local ca, sa = cos(a), sin(a)
        balls[#balls + 1] = {
            x = ca * 4,
            y = CY + sa * 4,
            vx = ca * sp,
            vy = sa * sp * 0.75 - 10,
            r0 = r * 0.6,
            r1 = r,
            life = life,
            delay = delay,
            max = life,
        }
    end

    return balls
end

--- 烟球之间的速度线：12 条，一闪就没。
--- ⚠️ Math.min 的两个实参在 JS 里从左到右求值：先 range(24,34)，再算「朝下的那条到地面为止」
---    （三元里的除法不带随机）。所以先取 r，再截断——反过来就少一次 next()。
---@param R table Rng
---@return table[]
function PoofLib.newLines(R)
    local lines = {}
    for i = 0, 11 do
        local a = (i / 12) * TAU + R:range(-0.12, 0.12) + 0.13
        local sa = sin(a)
        local r1 = R:range(24, 34)
        -- 指向地面的那些速度线到地面（y = -2）就停
        if sa > 0.1 then
            r1 = min(r1, (-2 - CY) / sa)
        else
            r1 = min(r1, 99)
        end
        local d = R:range(0, 0.04)
        lines[#lines + 1] = { a = a, r1 = r1, d = d }
    end
    return lines
end

return PoofLib
