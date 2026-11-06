-- ============================================================================
-- fx/effects/Poof.lua — spawn/poof 的 Lua 版
--
-- 原版：pixelfx src/fx/spawn/poof.js
-- 长什么样：一个卡通「啵」。先是白光一炸（白球 + 八道 flare），一层环从中心荡开，
-- 同时一圈胖烟球被炸出去、被阻力刹住、边减速边胀大，中间夹着速度线，还有小星星转着甩出去；
-- 最后云团一颗一颗缩没，地面留下一道渐隐的光和一团尘。
-- 游戏里什么时候放：角色死亡 / 召唤物消失 / 怪被收进场的那一帧，放在脚底（原点就在脚底）。
--
-- 原版是 create(o) 这种有状态的写法，所以这里导出 new / update / draw。
-- ⚠️ 原版没有 drawBack 之外的第二个画法层，但 createFx 会先画 back 再画 front；
--    Lua 侧的 FrameDump 只调一次 draw，所以 draw 里必须「先 back 后 front」按序画完。
-- ============================================================================

local Core = require "tap-pixelfx.core.Core"
local MathX = require "tap-pixelfx.core.Math"
local Sim = require "tap-pixelfx.core.Sim"
local PoofLib = require "tap-pixelfx.effects.PoofLib"

local Poof = {}

local ceil, sin, cos, min, max, pi = math.ceil, math.sin, math.cos, math.min, math.max, math.pi

local TAU = MathX.TAU
local CY = PoofLib.CY
local P = Sim.P

Poof.meta = {
    name = "Poof",
    desc = "A cartoon death poof: a white pop, a ring of soft round smoke balls bursting out between speed "
        .. "lines, little stars spinning off, and the cloud lifting and thinning away.",
    tags = { "spawn", "death", "despawn", "smoke", "poof", "cartoon", "one-shot" },
    size = { 112, 92 },
    origin = { 56, 80 },
    duration = 1.6,
    loop = false,
    fps = 30,
    bg = "ground",
    options = {
        palette = { "#2a2440", "#5e5878", "#9a94b4", "#cdc8e0", "#f2f0fa", "#ffffff" },
        stars = { "#ffd84a", "#fff3a6", "#ffffff" },
        seed = 21,
    },
}

--- 云团的三层：必须 shade 全画完再 body、再 cap，邻居烟球才会融成一团疙瘩
local LAYERS = { "shade", "body", "cap" }

--- 建一个实例（对齐 createFx：主循环一次 dt 要细分到 120Hz 以上再步进）
---@param opts table|nil
function Poof.new(opts)
    opts = opts or Poof.meta.options
    local C = Core.fit(opts.palette, 6)
    local S = Core.fit(opts.stars, 3)
    local R = MathX.newRng(opts.seed)
    -- 地面就是脚底（原版那个 `floor = () => 0`）
    local ps = Sim.newParticles({
        rng = R,
        ground = function()
            return 0
        end,
        sparks = { Core.WHITE, S[2], S[1], C[3] },
    })
    local lights = Sim.newLights()

    -- ⚠️ 从这里到 lights:add 之前，所有 R:xxx 的先后就是原版的求值顺序，一个字都不能挪：
    -- 先整团烟球（9 + 5 + 7），再速度线（12），再星星（7 + 10），最后尘（6）。
    -- 粒子的 seed 也是从这条 Rng 上取的，错一位后面全歪。
    local balls = PoofLib.newCloud(R)
    local lines = PoofLib.newLines(R)

    -- 炸出去的小星星：先一圈往上偏的、大而慢
    local starPick1 = { S[3], S[2], S[2], S[1] }
    for i = 0, 6 do
        local a = R:range(-pi, 0.3)
        local sp = R:range(70, 125)
        local ca, sa = cos(a), sin(a)
        local life = R:range(0.55, 0.95)
        local col = R:pick(starPick1)
        local size = R:range(1.3, 2.4)
        local delay = R:range(0.02, 0.1)
        ps:spawn(P.STAR, ca * 6, CY + sa * 6, ca * sp, sa * sp - 30, life, col, size, delay)
    end

    -- 再一圈小的、四面八方乱飞的
    local starPick2 = { Core.WHITE, S[2] }
    for i = 0, 9 do
        local a = R:range(0, TAU)
        local sp = R:range(40, 110)
        local ca, sa = cos(a), sin(a)
        local life = R:range(0.3, 0.6)
        local col = R:pick(starPick2)
        local delay = R:range(0, 0.08)
        ps:spawn(P.STAR, ca * 5, CY + sa * 5, ca * sp, sa * sp - 20, life, col, 0.6, delay)
    end

    -- 脚也没了：地面上一道往两边蹭出去的尘
    for i = 0, 5 do
        local s = R:sign()
        local x = s * R:range(1, 6)
        local vx = s * R:range(25, 70)
        local vy = -R:range(2, 10)
        local life = R:range(0.4, 0.7)
        local size = R:range(1.6, 3)
        local delay = R:range(0.02, 0.08)
        ps:spawn(P.DUST, x, -1, vx, vy, life, C[3], size, delay)
    end

    lights:add(0, CY, 46, C[5], 0.8, 0.4)
    lights:add(0, CY, 22, Core.WHITE, 0.8, 0.1)

    local self = { t = 0, ps = ps, lights = lights, balls = balls, lines = lines, C = C }
    return setmetatable(self, { __index = Poof })
end

--- 一步物理（dt 已经被 update 细分过；原版自己的 update 里没有再细分）
function Poof:step(dt)
    self.t = self.t + dt
    local balls, ps = self.balls, self.ps
    for i = #balls, 1, -1 do
        local b = balls[i]
        if b.delay > 0 then
            b.delay = b.delay - dt
        else
            b.life = b.life - dt
            if b.life <= 0 then
                -- 每颗大球散掉时都留一颗白光星
                if b.r1 > 4 then
                    ps:spawn(P.STAR, b.x, b.y, 0, -8, 0.22, Core.WHITE, 0.6)
                end
                table.remove(balls, i)
            else
                -- 猛地一炸、硬阻力刹住，然后慢慢往上飘
                -- ⚠️ 原版是 b.vy -= b.vy * 7 * dt + 30 * dt，即减掉 (阻力项 + 30dt) 这个整体，
                --    拆成两个减法浮点上不等价，必须留着括号
                b.vx = b.vx - b.vx * 7 * dt
                b.vy = b.vy - (b.vy * 7 * dt + 30 * dt)
                b.x = b.x + b.vx * dt
                -- 地面在 0：球底不许穿地，所以 y 的上限是 -半径*0.7（y 向上为负）
                b.y = min(b.y + b.vy * dt, -PoofLib.radius(b) * 0.7)
            end
        end
    end
    ps:update(dt)
    self.lights:update(dt)
end

function Poof:update(dt)
    local n = max(1, ceil(dt * 120 - 1e-9))
    for _ = 1, n do
        self:step(dt / n)
    end
end

function Poof:draw(p)
    local C, t = self.C, self.t

    -- ---- back 层：脚底那一小片光和「落在后面」的软粒子（尘） ----
    local s = 1 - MathX.smooth(0.1, 0.9, t)
    if s > 0 then
        p:glow(0, -1, 26, C[5], 0.25 * s)
    end
    self.ps:draw(p, "back")

    -- ---- front 层：云团 ----
    for _, layer in ipairs(LAYERS) do
        for _, b in ipairs(self.balls) do
            if b.delay <= 0 then
                PoofLib.drawBall(p, b, layer, C)
            end
        end
    end

    -- 那一「啵」：白球 + 八道 flare，只亮最初的三帧（t < 0.07）
    if t < 0.07 then
        local k = t / 0.07
        p:circle(0, CY, 9 + 3 * k, C[5])
        p:circle(0, CY, 7 + 3 * k, Core.WHITE)
        Sim.flare(p, 0, CY, 20 * (1 - k * 0.5), 1 - k, C)
    end

    -- 荡开的冲击环
    local rk = (t - 0.03) / 0.2
    if rk > 0 and rk < 1 then
        local rc
        if rk < 0.3 then
            rc = Core.WHITE
        else
            rc = C[5]
        end
        p:ring(0, CY, 8 + 18 * MathX.ease.outCubic(rk), max(1, 2.5 * (1 - rk)), rc, 1.1 - rk)
    end

    -- 速度线：头快尾慢地拉出去，带一点点辉
    for _, l in ipairs(self.lines) do
        local u = (t - l.d) / 0.2
        if u > 0 and u < 1 then
            local head = 8 + (l.r1 - 8) * MathX.ease.outExpo(MathX.clamp(u / 0.6))
            local tail = 8 + (l.r1 - 8) * MathX.ease.inCubic(u)
            local ca, sa = cos(l.a), sin(l.a)
            p:line(ca * tail, CY + sa * tail, ca * head, CY + sa * head, function(v)
                if v > 0.6 then
                    return Core.WHITE
                end
                return C[5]
            end)
            p:glowLine(ca * tail, CY + sa * tail, ca * head, CY + sa * head, 3, C[5], 0.25)
        end
    end

    self.ps:draw(p, "front")
    self.lights:draw(p)
end

return Poof
