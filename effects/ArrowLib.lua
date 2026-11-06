-- ============================================================================
-- fx/effects/ArrowLib.lua — Arrow 的私有小工具
--
-- 原版：pixelfx src/fx/projectiles/_lib.js 的 `beat`（该文件其它函数这次用不到，没搬）。
-- 只放 Arrow 自己要用、且不属于 Core/Math/Sim 的东西；共享文件一律不动。
-- ============================================================================

local MathX = require "tap-pixelfx.core.Math"

local ArrowLib = {}

--- 周期性「拍点」发生器：n 个相位错开的循环，每个循环里从 age=0 长到 life 就发一次 fn。
--- 原版签名：beat(t, period, n, seed, life, fn)
---   * life 可以是数字，也可以是 (rng) -> 数字（每拍自己摇一次寿命）
---   * 身体回调拿到的 rng 是 (seed, i)，寿命 rng 是 (seed, i, 911)
--- ⚠️ 三条必须逐字对齐原版的细节：
---   1) `wrap(t - (i*period)/n + 1e-7, period)`：那 1e-7 是原版用来避开 t=0 时的负零，
---      少了它第 0 拍可能落到 period 那一侧，整帧少一条气流。
---   2) 寿命 rng 和身体 rng 是两串独立的 mulberry32，用同一串会让画面完全不同。
---   3) 身体 rng 在**每次内层迭代**都新建（原版是 `rng(seed, i)` 写在调用实参里），
---      所以同一拍的第二次迭代不是接着上一次的序列走。
---@param t number 特效时间（秒）
---@param period number 一个完整循环的周期（原版传 meta.duration）
---@param n integer 相位数
---@param seed number 种子
---@param life number|fun(r:table):number 寿命或寿命生成函数
---@param fn fun(age:number, life:number, r:table, i:integer)
function ArrowLib.beat(t, period, n, seed, life, fn)
    local fnLife = type(life) == "function"
    for i = 0, n - 1 do
        local L
        if fnLife then
            L = life(MathX.rng(seed, i, 911))
        else
            L = life
        end
        local age = MathX.wrap(t - (i * period) / n + 1e-7, period)
        while age < L do
            fn(age, L, MathX.rng(seed, i), i)
            age = age + period
        end
    end
end

return ArrowLib
