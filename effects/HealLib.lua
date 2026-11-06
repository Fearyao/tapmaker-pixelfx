-- ============================================================================
-- fx/effects/HealLib.lua — holy/heal 用的私有小工具
--
-- 原版：pixelfx src/fx/holy/_lib.js（shapeOf / recolor / oval）
--       + src/core/actor.js（stockActor，meta.actor = 2 时 createFx 自己塞进去的那个假人）
-- 只搬 Heal 真正用到的那几件：角色剪影的 edge、按像素重着色、倾斜平面上的 1px 椭圆环，
-- 以及 24×38 假人的 mask / pixels 数据（都是照原文件数值抄的，不要改）。
-- ============================================================================

local Core = require "tap-pixelfx.core.Core"

local HealLib = {}

local floor, ceil, sin, cos, max, pi = math.floor, math.ceil, math.sin, math.cos, math.max, math.pi
local TAU = pi * 2

-- ---------------------------------------------------------------------------
-- 假人（actor 2）：src/core/actor.js 的 HERO2 / DUMMY_PAL
-- ---------------------------------------------------------------------------

-- 24×38，站立姿势，脚在原点
local HERO2 = {
    "...........kkk..........",
    "..........kAABk.........",
    ".........kAAABJk........",
    ".........kABBJJk........",
    ".........kBBBJCDk.......",
    ".........kBCJDDDk.......",
    ".........kkJJJDk........",
    ".......kkkkABBJCkk......",
    "......kAABCJBCCCkDk.....",
    "......kABBCJCCCmDkDk....",
    "......kBBCDDJCDDDkDk....",
    "......kABCDJDDDDDkk.....",
    ".....kAABDkDDDDJkk......",
    ".....kABCDkDDJJGkk......",
    ".....kABCkJJJGGGkk......",
    "....kJJCDkFFFGGGk.......",
    "....kAJJDkJJJGGGk.......",
    "....kJCJJkABBJGGk.......",
    ".....kJCCkBBCDJJJk......",
    ".....kCCCJBBCDJJDk......",
    ".....kCCCDJCCDkJDDk.....",
    "......kCDDJBCDkDDDk.....",
    ".......kDJJJCDkDDDkk....",
    ".......kJBCJCDkDDDkk....",
    ".......kBDJBCDkCDDkk....",
    "........kJJBCDkCDDk.....",
    "........kBBBCDkCCDDk....",
    "........kBBBCDkCCDDk....",
    ".........kBBCDkJDDDk....",
    "........kBJJJJkCJJJk....",
    "........kBBCCDkCCDDk....",
    "........kBBCDDkCDDk.....",
    "........kBBCDkCCDDk.....",
    "........kBCCDkCCDDk.....",
    "........kBCDDkCDDDk.....",
    ".......kJBCJkkkDJkkkk...",
    ".......kAJJAAAAkCCCCCk..",
    "........kkkkkkkkkkkkk...",
}

local DUMMY_PAL = {
    k = "#0e0c14", A = "#e4e6ec", B = "#b6b9c3", C = "#868995", D = "#5c5e6a",
    E = "#6e707c", F = "#4b4d58", G = "#34353f", J = "#2a2b33", m = "#f53cd1",
}

--- 逐行把字符映射成颜色数（0 = 空像素），下标是 0 基的 y*w+x
local function pixelsOf(rows, pal)
    local w = #rows[1]
    local out = {}
    for y = 1, #rows do
        local line = rows[y]
        for x = 1, w do
            local ch = line:sub(x, x)
            out[(y - 1) * w + (x - 1)] = (ch == ".") and 0 or Core.hex(pal[ch])
        end
    end
    return out
end

local PIXELS2
local function pixels2()
    if not PIXELS2 then
        PIXELS2 = pixelsOf(HERO2, DUMMY_PAL)
    end
    return PIXELS2
end

--- Heal 只用到 k = 2（meta.actor = 2），1 号小人用不上就没搬
---@param k number|nil
---@return table A { rows, x, y, w, h, pixels }（rows 即 mask：字符 != "." 就是实心）
function HealLib.stockActor(k)
    local w, h = #HERO2[1], #HERO2
    return {
        rows = HERO2,
        x = -floor(w / 2),
        y = -h,
        w = w,
        h = h,
        k = (k == 2) and 2 or 1,
        pixels = pixels2(),
    }
end

-- ---------------------------------------------------------------------------
-- 剪影
-- ---------------------------------------------------------------------------

--- 角色剪影（局部像素坐标）。原版还顺手算了 out / top / bottom / at，Heal 只用 edge，
--- 所以只留 edge：实心像素里「四邻不全」的那些，按 y 行、x 列扫描顺序排列。
---@param A table stockActor 的返回值
---@return table { edge = {{x, y}, ...}, x, y, w, h }
function HealLib.shapeOf(A)
    local rows, w, h = A.rows, A.w, A.h
    local function inside(i, j)
        if i < 0 or j < 0 or i >= w or j >= h then
            return false
        end
        return rows[j + 1]:sub(i + 1, i + 1) ~= "."
    end
    local edge = {}
    for j = -1, h do
        for i = -1, w do
            if inside(i, j) then
                local nb = 0
                if inside(i - 1, j) then nb = nb + 1 end
                if inside(i + 1, j) then nb = nb + 1 end
                if inside(i, j - 1) then nb = nb + 1 end
                if inside(i, j + 1) then nb = nb + 1 end
                if nb < 4 then
                    edge[#edge + 1] = { A.x + i, A.y + j }
                end
            end
        end
    end
    return { edge = edge, x = A.x, y = A.y, w = w, h = h }
end

-- ---------------------------------------------------------------------------
-- 重着色 / 椭圆环
-- ---------------------------------------------------------------------------

--- 把角色自己的像素按 fn(c, x, y) 重画：返回 0 表示这一格不动（露出角色本来的颜色）。
--- a 可以是数，也可以是 (x, y) -> alpha。
---@param p table Painter
---@param A table stockActor 的返回值
---@param fn fun(c: number, x: number, y: number): number
---@param a number|function|nil
function HealLib.recolor(p, A, fn, a)
    a = a or 1
    local P = A.pixels
    if not P then
        return
    end
    local fa = type(a) == "function"
    for j = 0, A.h - 1 do
        for i = 0, A.w - 1 do
            local c = P[j * A.w + i]
            -- ⚠️ Lua 里 0 是真值：原版的 if (!c) 必须写成 c == 0
            if c ~= nil and c ~= 0 then
                local x, y = A.x + i, A.y + j
                local n = fn(c, x, y)
                if n ~= nil and n ~= 0 then
                    p:dot(x, y, n, fa and a(x, y) or a)
                end
            end
        end
    end
end

--- 倾斜平面上的 1px 椭圆环：圆心 (cx, cy)，半径 rx / ry。
--- c、a 可以是关于角度 g 的函数（sin(g) > 0 是近侧）；keep(g) 决定这一段画不画。
---@param p table Painter
---@param cx number
---@param cy number
---@param rx number
---@param ry number
---@param c number|function
---@param a number|function|nil
---@param keep function|nil
function HealLib.oval(p, cx, cy, rx, ry, c, a, keep)
    a = a or 1
    if rx < 0.5 then
        return
    end
    local n = ceil(max(rx, ry) * TAU * 1.5) + 6
    local fc, fa = type(c) == "function", type(a) == "function"
    for j = 0, n - 1 do
        local g = (j / n) * TAU
        if not (keep and not keep(g)) then
            p:dot(cx + cos(g) * rx, cy + sin(g) * ry, fc and c(g) or c, fa and a(g) or a)
        end
    end
end

return HealLib
