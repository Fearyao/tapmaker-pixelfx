-- ============================================================================
-- fx/effects/Heal.lua — holy/heal 的 Lua 版
--
-- 原版：pixelfx src/fx/holy/heal.js（辅助件在 holy/_lib.js，这里落在 HealLib.lua）
-- 脚下一朵光莲一瓣一瓣开、一道光圈顺着身体往上走、走过的地方把角色的颜色补回来、
-- 顺带撒下星点，最后星点一颗颗爆成小爱心飘走。游戏里是吃回血药/复活/治疗术的落点。
--
-- 这个特效把「角色形状」也搬进来了：原版用 o.actor（meta.actor = 2 → 24×38 的假人）
-- 的 mask 取边缘行、用它的 pixels 逐像素重着色，所以 HealLib 里抄了整份 HERO2/DUMMY_PAL。
-- ============================================================================

local Core = require "tap-pixelfx.core.Core"
local MathX = require "tap-pixelfx.core.Math"
local Sim = require "tap-pixelfx.core.Sim"
local HealLib = require "tap-pixelfx.effects.HealLib"

local Heal = {}

local floor, ceil, sqrt, sin, cos, abs, min, max, pi = math.floor, math.ceil, math.sqrt, math.sin, math.cos,
    math.abs, math.min, math.max, math.pi
local exp = math.exp

local seg, smooth = MathX.seg, MathX.smooth
local ease = MathX.ease
local TAU = pi * 2

Heal.meta = {
    name = "Heal",
    desc = "Petals of light bloom under the feet, a hoop of light rises up the body restoring its colour and leaving sparkles, and motes spiral up and pop into tiny hearts.",
    tags = { "holy", "heal", "restore", "buff", "petals", "hearts", "character", "one-shot" },
    size = { 80, 104 },
    origin = { 40, 92 },
    duration = 1.9,
    loop = false,
    fps = 30,
    bg = "ground",
    actor = 2,
    options = {
        palette = { "#3d2027", "#7d3f35", "#c97a4a", "#f2b46a", "#ffd994", "#fff0cf", "#fffaf2", "#ffffff" },
        seed = 2,
    },
}

-- 花瓣个数、地面那一圈的半径、光圈起止时间、光圈顶上的高度
local SY, NP, PR, LIFT0, LIFT1, TOPY = 0.3, 8, 16, 0.16, 0.74, -43

-- 4×4 的小爱心（原版 HEART）
local HEART = { ".#.#.", "#####", ".###.", "..#.." }

--- HEART[j][i] == "#"（i、j 都是 0 基，越界即空）
local function heartAt(i, j)
    if j < 0 or j >= 4 or i < 0 or i >= 5 then
        return false
    end
    return HEART[j + 1]:sub(i + 1, i + 1) == "#"
end

--- 一颗小爱心：奶油色的身、一点白高光、一圈暖边
local function heart(p, x, y, C, a)
    -- Math.round：负数也要按「四舍五入往 +∞」来，floor(x + 0.5) 才等价
    local X, Y = floor(x + 0.5) - 2, floor(y + 0.5) - 2
    for j = -1, 4 do
        for i = -1, 5 do
            if heartAt(i, j) then
                local c
                if i == 1 and j == 1 then
                    c = Core.WHITE
                elseif j >= 2 then
                    c = C[6]
                else
                    c = C[7]
                end
                p:dot(X + i, Y + j, c, a)
            elseif heartAt(i - 1, j) or heartAt(i + 1, j) or heartAt(i, j - 1) or heartAt(i, j + 1) then
                p:dot(X + i, Y + j, C[4], a * 0.9)
            end
        end
    end
    p:glow(x, y, 6, C[6], 0.4 * a)
end

--- 光圈在 t 时刻的高度 / 半径
local function hoopY(tt)
    return MathX.lerp(0, TOPY, ease.inOutSine(seg(tt, LIFT0, LIFT1)))
end

local function hoopR(tt)
    return MathX.lerp(PR, 12, seg(tt, LIFT0, LIFT1))
end

--- 第 k 瓣（0 基）在 t 时刻的开合度：脚下先鼓出来（outBack），末尾再收回去（inBack）
local function bloom(self, k, tt)
    local pe = self.petals[k + 1]
    return ease.outBack(seg(tt, pe.t0, pe.t0 + 0.3), 1.8) *
        (1 - ease.inBack(seg(tt, 1.25 + k * 0.02, 1.6 + k * 0.02), 1.4))
end

--- 脚下一圈光莲的一瓣：根部扎在地面那圈上，开的时候往外倾，转开去的时候透视压扁；
--- 一道亮边、一条白脉、半透明的暖色瓣身、白色的尖
local function petal(self, p, k, back)
    local C, t = self.C, self.t
    local pe = self.petals[k + 1]
    local g = pe.a + t * 0.4
    local near = sin(g) >= 0
    local b = bloom(self, k, t)
    if near == back or b <= 0.02 then
        return
    end
    local ca, sa = cos(g), sin(g)
    local rb = 6
    local rt = rb + 9 * min(1.2, b)
    local h = (k % 2 == 1 and 7 or 9) * b
    local bx, by = ca * rb, sa * rb * SY
    local tx, ty = ca * rt, sa * rt * SY - h
    local L = sqrt((tx - bx) * (tx - bx) + (ty - by) * (ty - by))
    if L < 1.5 then
        return
    end
    local ux, uy = (tx - bx) / L, (ty - by) / L
    local W = pe.w * min(1, b) * (0.35 + 0.65 * abs(sa))
    local pad = W + 1
    p:each(min(bx, tx) - pad, min(by, ty) - pad, max(bx, tx) + pad, max(by, ty) + pad, function(x, y, sx, sy)
        local dx, dy = x - bx, y - by
        local u = (dx * ux + dy * uy) / L
        if u < 0 or u > 1 then
            return
        end
        -- 瓣宽：两端收成尖（u^0.6 再 sin），中间最胖
        local hw = W * (sin(pi * u ^ 0.6)) ^ 0.7 + 0.2
        local v = abs(-dx * uy + dy * ux) / hw
        if v > 1 then
            return
        end
        if u > 0.9 then
            return p:put(sx, sy, Core.WHITE, 1)
        end
        if v > 0.7 then
            return p:put(sx, sy, u < 0.3 and C[4] or (u < 0.7 and C[6] or C[7]), 1)
        end
        if v < 0.2 and u > 0.15 and u < 0.85 then
            return p:put(sx, sy, u < 0.55 and C[6] or C[7], back and 0.75 or 0.85)
        end
        p:blendPx(sx, sy, u < 0.45 and C[4] or C[5], back and 0.6 or 0.45)
    end)
    p:glow(tx, ty, 5, C[6], 0.35 * min(1, b))
end

--- 顺着身体往上走的光圈：远侧的半圈在身后，近侧的半圈在身前，外侧一圈柔光
local function hoop(self, p, back)
    local C, t = self.C, self.t
    if t < LIFT0 or t > LIFT1 + 0.12 then
        return
    end
    local y = hoopY(t)
    local r = hoopR(t)
    if t > LIFT1 then
        r = r * (1 - (t - LIFT1) / 0.12)
    end
    local keep
    if back then
        keep = function(g)
            return sin(g) < 0
        end
    else
        keep = function(g)
            return sin(g) >= 0
        end
    end
    HealLib.oval(p, 0, y, r, r * SY, function(g)
        return sin(g) > 0.5 and Core.WHITE or C[7]
    end, back and 0.8 or 1, keep)
    if not back then
        HealLib.oval(p, 0, y + 1, r - 0.5, r * SY, C[5], 1, keep)
        for i = -2, 2 do
            p:glow(i * r * 0.45, y, 8, C[6], 0.32)
        end
    end
end

--- 沿着螺旋往上绕的小光点：花瓣张开时从瓣尖出发、光圈炸开时从光圈上出发；
--- 走到头就爆成一颗小爱心（或一朵星芒）飘上去淡掉
local function riders(self, p, back)
    local C, t = self.C, self.t
    local fade = back and 0.6 or 1
    for _, m in ipairs(self.motes) do
        local a = t - m.t0
        if a >= 0 then
            if a < m.life then
                local th = m.th0 + m.w * a
                local r = m.r0 * (1 - 0.45 * (a / m.life))
                local x, y, z = cos(th) * r, m.y0 - m.v * a, sin(th)
                -- z < 0 是远侧：远侧的画进 back 层
                if (z < 0) == back then
                    for j = 0, 6 do
                        local aj = a - j * 0.03
                        if aj < 0 then
                            break
                        end
                        local thj = m.th0 + m.w * aj
                        local rj = m.r0 * (1 - 0.45 * (aj / m.life))
                        local tx, ty, tz = cos(thj) * rj, m.y0 - m.v * aj, sin(thj)
                        if (tz < 0) == back then
                            p:dot(tx, ty, j == 0 and Core.WHITE or (j < 3 and C[7] or C[6]), (1 - j / 7) * fade)
                        end
                    end
                    p:glow(x, y, 4, C[6], back and 0.2 or 0.4)
                end
            else
                local u = (a - m.life) / 0.36
                if u < 1 and not back then
                    local th = m.th0 + m.w * m.life
                    local x, y = cos(th) * (m.r0 * (1 - 0.45)), m.y0 - m.v * m.life
                    local kk = 1 - smooth(0.5, 1, u)
                    if u < 0.12 then
                        Sim.sparkle(p, x, y, 3, Core.WHITE, C[7], 0.5)
                    elseif m.kind ~= 0 then
                        heart(p, x, y - u * 6, C, kk)
                    else
                        Sim.sparkle(p, x, y - u * 5, 1 + 2 * kk * (0.7 + 0.3 * sin(a * 30)), Core.WHITE, C[6], 0.45 * kk)
                    end
                end
            end
        end
    end
end

--- 建一个实例（对齐 createFx：dt 一律细分到 120Hz 以上再步进，t 在细分步里攒）
function Heal.new(opts)
    opts = opts or Heal.meta.options
    local C = Core.fit(opts.palette, 8)
    local R = MathX.newRng(opts.seed)
    local A = HealLib.stockActor(2)
    local S = HealLib.shapeOf(A)
    local ps = Sim.newParticles({ rng = R, ground = function() return 0 end, sparks = { Core.WHITE, C[7], C[6], C[5] } })
    local lights = Sim.newLights()

    -- 剪影边缘按行分组：光圈走过某一行时从这一行的边缘点上撒星
    local rows = {}
    for _, e in ipairs(S.edge) do
        local x, y = e[1], e[2]
        local list = rows[y]
        if not list then
            list = {}
            rows[y] = list
        end
        list[#list + 1] = x
    end

    -- 花瓣：每瓣自己有一个起拍点，绕着圈错开开
    local petals = {}
    for k = 0, NP - 1 do
        petals[k + 1] = {
            a = (k / NP) * TAU + 0.2,
            t0 = 0.02 + ((k * 3) % NP) * 0.035,
            w = R:range(4.2, 5.2),
        }
    end
    -- 螺旋上升的小光点：一轮从张开的花瓣尖出发，一轮从炸开的光圈上出发
    local motes = {}
    for k = 0, NP - 1 do
        local pe = petals[k + 1]
        -- ⚠️ v、life 的取值顺序必须和 JS 对象的字面量顺序一致，否则 Rng 序列错位
        local v = R:range(46, 58)
        local life = R:range(0.75, 0.95)
        motes[#motes + 1] = {
            t0 = 0.2 + k * 0.05,
            th0 = pe.a,
            r0 = PR * 0.9,
            y0 = -1,
            w = 4.2 * (k % 2 == 1 and 1 or -1),
            v = v,
            life = life,
            kind = k % 2,
        }
    end
    for k = 0, 7 do
        -- 同上：t0 → r0 → y0 → v → life 的顺序不能动
        local t0 = LIFT1 + R:range(0, 0.06)
        local r0 = R:range(12, 18)
        local y0 = TOPY + R:range(-2, 4)
        local v = R:range(14, 34)
        local life = R:range(0.35, 0.6)
        motes[#motes + 1] = {
            t0 = t0,
            th0 = (k / 8) * TAU,
            r0 = r0,
            y0 = y0,
            w = 3.6 * (k % 2 == 1 and 1 or -1),
            v = v,
            life = life,
            kind = (k + 1) % 2,
        }
    end

    local self = {
        t = 0,
        burst = false,
        lastRow = 1,
        C = C,
        R = R,
        A = A,
        ps = ps,
        lights = lights,
        rows = rows,
        petals = petals,
        motes = motes,
    }
    return setmetatable(self, { __index = Heal })
end

--- 一个细分步（原版 impl.update 的原文，dt 已被 update 切到 120Hz 以上）
function Heal:step(dt)
    local t = self.t + dt
    self.t = t
    local R, C = self.R, self.C
    -- 光圈每走过一行，就在这一行的角色边缘上撒几颗星
    if t > LIFT0 and t < LIFT1 then
        local Y = floor(hoopY(t) + 0.5)
        local y = self.lastRow
        while y > Y do
            local xs = self.rows[y]
            -- ⚠️ 短路顺序要和原版一样：没有边缘行就不消耗 chance 的随机数
            if xs and R:chance(0.45) then
                local x0 = R:pick(xs) + R:range(-1, 1) * 2
                local vx = R:range(-4, 4)
                local vy = -R:range(4, 12)
                local life = R:range(0.3, 0.55)
                local col = R:chance(0.5) and Core.WHITE or C[7]
                local size = R:range(0.6, 1.6)
                self.ps:spawn(Sim.P.STAR, x0, y, vx, vy, life, col, size)
            end
            y = y - 1
        end
        if Y < self.lastRow then
            self.lastRow = Y
        end
    end
    if not self.burst and t >= LIFT1 then
        self.burst = true
        self.lights:add(0, TOPY, 26, C[6], 0.55, 0.3)
        self.lights:add(0, TOPY, 10, Core.WHITE, 0.45, 0.08)
    end
    self.ps:update(dt)
    self.lights:update(dt)
end

function Heal:update(dt)
    local n = max(1, ceil(dt * 120 - 1e-9))
    for _ = 1, n do
        self:step(dt / n)
    end
end

--- 原版 drawBack：角色身后的那层（暖光池、背面的花瓣与光圈、远侧的星点、背面粒子）
--- ⚠️ 有状态特效在对拍台/烘焙里只会被调一次 draw（见 fx/dev/FrameDump.lua），所以这一层
--- 不能单独挂在 Heal:drawBack 上，必须由 Heal:draw 先画一遍——等价于 createFx 的
--- draw(frame, "back") → draw(frame, "front") 两次画进同一张帧。
local function drawBackLayer(self, p)
    local C, t = self.C, self.t
    -- 花底下的一汪暖光
    local pool = smooth(0, 0.2, t) * (1 - smooth(1.3, 1.75, t))
    if pool > 0 then
        p:glow(0, -2, 30, C[5], 0.3 * pool)
    end
    for k = 0, NP - 1 do
        petal(self, p, k, true)
    end
    hoop(self, p, true)
    self.ps:draw(p, "back")
    riders(self, p, true)
end

function Heal:draw(p)
    local C, t = self.C, self.t
    drawBackLayer(self, p)
    -- 光圈以上褪成灰，以下被暖光补回颜色，交界处一道白光
    local drain = smooth(0, 0.08, t)
    if t < LIFT1 + 0.35 then
        local Y = t < LIFT0 and 1 or hoopY(t)
        local done = t >= LIFT1
        HealLib.recolor(p, self.A, function(c, x, y)
            local d = y - Y
            if not done and d < -0.5 then
                local l = Core.luma(c) * 0.88
                return Core.mix(c, Core.rgb(l * 236, l * 226, l * 222), 0.68 * drain)
            end
            if not done and d < 1 then
                return Core.WHITE
            end
            if not done and d < 2.5 then
                return C[7]
            end
            local kk
            if done then
                kk = 0.45 * (1 - seg(t, LIFT1, LIFT1 + 0.35))
            else
                kk = 0.5 * exp(-(d - 2.5) / 5)
            end
            return kk > 0.05 and Core.mix(c, C[6], kk) or 0
        end)
        if t > LIFT0 and not done then
            p:glow(0, Y, 18, C[6], 0.35)
        end
    end
    for k = 0, NP - 1 do
        petal(self, p, k, false)
    end
    hoop(self, p, false)
    if t >= LIFT1 and t < LIFT1 + 0.25 then
        Sim.sparkle(p, 0, TOPY, 8 * (1 - (t - LIFT1) / 0.25), Core.WHITE, C[6], 0.6)
    end
    riders(self, p, false)
    self.ps:draw(p, "front")
    self.lights:draw(p)
end

return Heal
