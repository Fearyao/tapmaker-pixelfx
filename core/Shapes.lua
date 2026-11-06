-- ============================================================================
-- fx/Shapes.lua — pixelfx `src/core/shapes.js` 的移植
--
-- 特效反复要用的点列：闪电折线、分叉、星形、正多边形、运动物件的拖尾。
-- 全是纯几何，不碰画布；拿到点列后自己 p:line / p:poly。
-- ============================================================================

local MathX = require "tap-pixelfx.core.Math"

local Shapes = {}

local floor, cos, sin, sqrt, pi = math.floor, math.cos, math.sin, math.sqrt, math.pi
local TAU = MathX.TAU

--- 中点位移生成的闪电折线：从 (x0, y0) 到 (x1, y1)
--- jag = 中点可横向偏移的比例，depth = 细分次数
---@param r table Rng
---@return table { {x, y}, ... }
function Shapes.bolt(r, x0, y0, x1, y1, opts)
    opts = opts or {}
    local jag = opts.jag or 0.22
    local depth = opts.depth or 5
    local pts = { { x0, y0 }, { x1, y1 } }
    for _ = 1, depth do
        local nextPts = { pts[1] }
        for i = 2, #pts do
            local ax, ay = pts[i - 1][1], pts[i - 1][2]
            local bx, by = pts[i][1], pts[i][2]
            local dx, dy = bx - ax, by - ay
            local L = sqrt(dx * dx + dy * dy)
            local off = (r:next() * 2 - 1) * jag * L
            local L2 = (L == 0) and 1 or L
            nextPts[#nextPts + 1] = { (ax + bx) / 2 + (-dy / L2) * off, (ay + by) / 2 + (dx / L2) * off }
            nextPts[#nextPts + 1] = pts[i]
        end
        pts = nextPts
    end
    return pts
end

--- 从一条折线上分叉出去：count 条，每条最长 len px
---@return table { 路径, ... }
function Shapes.forks(r, path, opts)
    opts = opts or {}
    local count = opts.count or 3
    local len = opts.len or 20
    local jag = opts.jag or 0.3
    local spread = opts.spread or 0.9
    local out = {}
    for _ = 1, count do
        local i = 1 + floor(r:next() * (#path - 2))
        local x, y = path[i][1], path[i][2]
        local px, py = path[i - 1][1], path[i - 1][2]
        local a = math.atan(y - py, x - px) + (r:next() < 0.5 and -1 or 1) * spread * (0.4 + 0.6 * r:next())
        local l = len * (0.4 + 0.6 * r:next())
        out[#out + 1] = Shapes.bolt(r, x, y, x + cos(a) * l, y + sin(a) * l, { jag = jag, depth = 3 })
    end
    return out
end

--- 星形：n 个尖，尖端半径 r1、内角半径 r0
---@return table
function Shapes.star(cx, cy, r0, r1, n, rot)
    n = n or 5
    rot = rot or -pi / 2
    local pts = {}
    for i = 0, n * 2 - 1 do
        local a = rot + (i * pi) / n
        local r = (i % 2 == 1) and r0 or r1
        pts[#pts + 1] = { cx + cos(a) * r, cy + sin(a) * r }
    end
    return pts
end

--- 正多边形（n 边）
---@return table
function Shapes.ngon(cx, cy, r, n, rot)
    n = n or 6
    rot = rot or 0
    local pts = {}
    for i = 0, n - 1 do
        local a = rot + (i * TAU) / n
        pts[#pts + 1] = { cx + cos(a) * r, cy + sin(a) * r }
    end
    return pts
end

--- 运动物件的拖尾：pos(t - i*dt)，i = 0..n-1（最新的在前）
---@param pos fun(t: number): number, number
---@return table
function Shapes.trail(pos, t, n, dt)
    local out = {}
    for i = 0, n - 1 do
        local x, y = pos(math.max(0, t - i * dt))
        out[#out + 1] = { x, y }
    end
    return out
end

return Shapes
