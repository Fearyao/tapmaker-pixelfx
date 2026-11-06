-- ============================================================================
-- view/px/SmallExplosionLib.lua — explosions/small-explosion 自带的三个画法
--
-- 原版：pixelfx src/fx/explosions/small-explosion.js 顶部的 stone / scorch / rock
-- 注意这三个是**该文件内的私有函数**，和 explosions/_lib.js 里同名的 stone / scorch /
-- rock 不是一份代码（_lib 的版本带熔岩、裂缝、热石心，这里没有）。照原文件搬这一份。
--
-- 跟 Core 的 Painter 一样，颜色 / alpha 全部走 dot / shade，所以同一个 t 重放逐像素相同。
-- ============================================================================

local Core = require "tap-pixelfx.core.Core"
local MathX = require "tap-pixelfx.core.Math"

local SmallExplosionLib = {}

local floor, ceil, sqrt, cos, sin, min, max = math.floor, math.ceil, math.sqrt, math.cos, math.sin, math.min, math.max

local SOOT = Core.hex("#0d0a12") -- 烧穿了的芯
local SOOT2 = Core.hex("#17121d") -- 烧痕的外圈
local OUTLINE = Core.hex("#1a1422") -- 石头的描边
local WARM = Core.rgb(255, 176, 96) -- 爆心的暖光

SmallExplosionLib.SOOT = SOOT
SmallExplosionLib.SOOT2 = SOOT2
SmallExplosionLib.OUTLINE = OUTLINE
SmallExplosionLib.WARM = WARM

--- 一种石头的四个台阶：亮面、本体、暗面、落地扬起的土
---@param c any 石头本体色（hex 串或颜色数）
---@return table { light, body, shade, dust }
function SmallExplosionLib.stone(c)
    c = Core.hex(c)
    return {
        light = Core.mix(Core.scale(c, 1.35), Core.WHITE, 0.08),
        body = c,
        shade = Core.scale(c, 0.64),
        dust = Core.mix(Core.scale(c, 1.2), Core.rgb(150, 140, 150), 0.3),
    }
end

--- 地面上的烧痕：0.08 秒内张开到 rx0 宽，白热开始，沿火色带降温到炭黑
---@param p table Painter
---@param F number[] 火色带（暗到亮，8 阶）
---@param t number 特效时间（秒）
---@param rx0 number 最终半宽
---@param cool number 冷却到黑的秒数
---@param fade number 0..1 整体淡出
function SmallExplosionLib.scorch(p, F, t, rx0, cool, fade)
    if fade <= 0 then
        return
    end
    local rx = rx0 * min(1, t / 0.08)
    local ry = 4
    local n = #F
    -- 原版是 [...F].reverse()：heat[1] 白热，heat[n] 最暗
    local heat = {}
    for i = 1, n do
        heat[i] = F[n - i + 1]
    end
    for y = 0, 2 do
        for x = floor(-rx), ceil(rx) do
            local dx = (x + 0.5) / rx
            local dy = (y + 0.5) / ry
            local d = sqrt(dx * dx + dy * dy)
            if d <= 1 then
                -- 每格一个确定的抖动值，让烧痕边缘参差
                local k = MathX.rand(x * 31 + y, 3)
                local T = MathX.clamp(1 - t / cool) ^ 1.4 * (1.25 - d) - k * 0.35
                if T > 0.06 then
                    local c = heat[min(n, floor((1 - min(1, T)) * (n - 1)) + 1)]
                    p:dot(x, y, c, fade)
                    if (x & 3) == 0 then
                        p:glow(x + 0.5, y, 6, c, 0.18 * T * fade)
                    end
                else
                    local a = (d < 0.95 - k * 0.3) and 1 or (1 - d)
                    p:dot(x, y, (d < 0.5) and SOOT or SOOT2, a * fade)
                end
            end
        end
    end
end

--- 一块飞石：亮面朝自转方向、暗面在另一侧、外面一圈描边，快落地时整体淡出
---@param p table Painter
---@param b table Bits 的碎片（要有 x / y / a / s / life）
---@param st table Lib.stone 的结果
function SmallExplosionLib.rock(p, b, st)
    local r = 0.6 + b.s * 0.75
    local fade = min(1, b.life / 0.5)
    local lx = cos(b.a) * r * 0.4
    local ly = sin(b.a) * r * 0.4
    p:shade(b.x - r - 1, b.y - r - 1, b.x + r + 1, b.y + r + 1, function(x, y, o)
        local dx, dy = x - b.x, y - b.y
        -- 原版是 Math.hypot(dx * 1.15, dy)：横向拉一点，石头看起来更扁
        local d = sqrt((dx * 1.15) * (dx * 1.15) + dy * dy)
        if d > r + 0.9 then
            return
        end
        local lit = dx * lx + dy * ly
        if d > r then
            o.c = OUTLINE
        elseif lit < -0.4 then
            o.c = st.light
        elseif lit > 0.6 then
            o.c = st.shade
        else
            o.c = st.body
        end
        o.a = fade
    end)
end

return SmallExplosionLib
