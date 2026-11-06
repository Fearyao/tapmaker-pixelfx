-- ============================================================================
-- fx/effects/Arrow.lua — projectiles/arrow 的 Lua 版（纯函数特效的验收样本）
--
-- 原版：pixelfx src/fx/projectiles/arrow.js
-- 一支飞行中的箭：钢制宽箭簇反着光、木箭杆、随风抖动的尾羽，箭簇上不断剥落气流、
-- 尾羽后面卷出小涡。循环特效（loop=true），适合挂在飞行中的投射物身上。
--
-- 这是本仓库第一个「纯函数」特效：原版没有 create，只有 draw(p, t, o)，
-- 所以这里也只导出 Arrow.draw(p, t, opts)，不写 new/update。
-- t 的取模/封顶由调用方（FrameDump / Bake）按 meta.loop 处理，这里不自己再取模。
-- ============================================================================

local Core = require "tap-pixelfx.core.Core"
local MathX = require "tap-pixelfx.core.Math"
local Sim = require "tap-pixelfx.core.Sim"
local ArrowLib = require "tap-pixelfx.effects.ArrowLib"

local Arrow = {}

local floor, sin, cos, pi = math.floor, math.sin, math.cos, math.pi
local TAU = MathX.TAU

Arrow.meta = {
    name = "Arrow",
    desc = "An arrow in flight: a steel broadhead catching the light, a wooden shaft, fletching fluttering "
        .. "in the wind, streaks of air peeling off its head and swirling off its feathers.",
    tags = { "projectile", "arrow", "bow", "medieval", "directional", "loop" },
    size = { 112, 32 },
    origin = { 92, 16 },
    duration = 0.6,
    loop = true,
    fps = 30,
    bg = "sky",
    options = {
        palette = { "#7a1f2c", "#b8323c", "#e8e2d6", "#ffffff" },
        wood = { "#3a2414", "#6e4422", "#a8723c", "#d8a868" },
        steel = { "#2e3648", "#5a6680", "#9aa6ba", "#dfe7f2" },
        wind = "#b8c8e8",
        seed = 3,
    },
}

--- 箭簇：箭尖朝右、尖端在 (0,0)。L=高光面 s/S=中间调 d/D=暗面 b=绑绳 W=白尖
local HEAD = {
    "..LL....",
    "..sLLL..",
    "bbsSSSSW",
    "..dDDD..",
    "..DD....",
}

--- 尾羽：三种姿态轮流抖（A/a 亮面、C/c 暗面、k 羽轴、n 根部）
local FLETCH = {
    {
        "AAa.........",
        ".aAAa.......",
        "..aaAAa.....",
        "nkkkkkkkkkkk",
        "..cCCc......",
        ".cCCc.......",
        "CCc.........",
    },
    {
        ".AAa........",
        "..aAAa......",
        "..aaAAAa....",
        "nkkkkkkkkkkk",
        "..cCCCc.....",
        "..cCCc......",
        ".CCc........",
    },
    {
        "AAAa........",
        "aAAa........",
        ".aaAAa......",
        "nkkkkkkkkkkk",
        "..ccCc......",
        "cCCc........",
        "CCc.........",
    },
}

--- 气流老去后压向的深色（原版是在回调里现 hex 的常量，提前算好不影响随机序列）
local WIND_DEEP = Core.hex("#2a2540")

--- 画一帧。t 已经由调用方按 meta.loop 取过模（原版 createFx 同样在 draw 里做 t % D）
---@param p table Painter
---@param t number 特效时间（秒，0..duration）
---@param opts table 已合并 meta.options 的选项
function Arrow.draw(p, t, opts)
    local PL = Core.fit(opts.palette, 4)
    local W = Core.fit(opts.wood, 4)
    local ST = Core.fit(opts.steel, 4)
    local wind = Core.hex(opts.wind)
    local S = opts.seed
    local D = Arrow.meta.duration
    -- fr 是 30fps 帧号：尾羽姿态靠它抽签，+1e-6 是原版防浮点卡在整数边上的做法
    local fr = floor(t * 30 + 1e-6)
    local ph = t / D
    local left = -Arrow.meta.origin[1] + 2
    local LEN = 36

    -- 箭簇与尾羽剥下来的气流：向后拉长、变细
    ArrowLib.beat(t, D, 9, S, function(r)
        return r:range(0.14, 0.26)
    end, function(age, life, r)
        local k = age / life
        local top = r:chance(0.5) and -1 or 1
        local from = r:chance(0.6) and -3 or (-LEN + 6)
        -- ⚠️ 下面四次取数的先后就是原版实参求值顺序，挪一下整条 Rng 序列就错位
        local x0 = from - age * r:range(160, 240)
        local len = r:range(8, 16) * (0.5 + k)
        local ry1 = r:range(3, 5)
        local ry2 = r:range(1, 2.5)
        local y = 0.5 + top * (ry1 + k * ry2)
        if x0 - len < left then
            return
        end
        local c
        if k < 0.4 then
            c = wind
        else
            c = Core.mix(wind, WIND_DEEP, (k - 0.4) * 1.2)
        end
        local lit = Core.mix(wind, Core.WHITE, 0.5)
        -- 中段最亮、尾端收细成一点：颜色和 alpha 都是 u（0=头 1=尾）的函数
        p:line(x0, y, x0 - len, y, function(u)
            if u < 0.25 and k < 0.4 then
                return lit
            end
            return c
        end, function(u)
            if u < 0.65 then
                return 1
            end
            return (1 - u) / 0.35
        end)
    end)

    -- 尾羽后面卷出来的小涡：四个点绕着小圈转
    ArrowLib.beat(t, D, 6, S + 3, function(r)
        return r:range(0.15, 0.25)
    end, function(age, life, r)
        local k = age / life
        local cx = -LEN - 2 - age * r:range(100, 150)
        local sgn = r:sign()
        local rcy = r:range(2, 4)
        local cy = 0.5 + sgn * rcy
        local a = age * 30 + r:range(0, TAU)
        local rr = 1.2 + k * 1.5
        if cx < left + 4 then
            return
        end
        local fade = 1 - k
        for i = 0, 3 do
            p:dot(cx + cos(a + i * 0.5) * rr, cy + sin(a + i * 0.5) * rr, wind, fade * (1 - i * 0.2))
        end
    end)

    -- 箭杆：一条暗线打底，上面隔 6px 点一颗亮木色当受光面
    -- （原版 W[2] / W[3] 是 0 基下标，Lua 里对应 W[3] / W[4]）
    p:line(-LEN + 11, 0, -7, 0, W[3])
    for x = -LEN + 14, -9, 6 do
        p:px(x, 0, W[4])
    end

    -- 尾羽：三种姿态随机抽一个，抖得比帧率还快
    local pose = FLETCH[floor(MathX.rand(fr, S) * 3) + 1]
    p:sprite(pose, { a = PL[3], A = PL[4], c = PL[1], C = PL[2], k = W[2], n = W[1] }, -LEN, -3)

    -- 绑绳 + 宽箭簇：上斜面受光、下斜面压暗、箭尖纯白
    p:sprite(HEAD, { L = ST[4], s = ST[3], S = ST[3], d = ST[1], D = ST[2], b = W[1], W = Core.WHITE }, -7, -2)

    -- 刀身上偶尔跑过一道反光：ph*2 取模，一个周期里滑两次
    local g = (ph * 2) % 1
    if g < 0.25 then
        local arm = 1 + floor(2 * sin((g / 0.25) * pi) + 0.5)
        Sim.sparkle(p, -5 + g * 16, -1, arm, Core.WHITE, ST[4], 0.25)
    end
end

return Arrow
