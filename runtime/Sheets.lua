-- ============================================================================
-- fx/Sheets.lua — 构建期烤好的图集（assets/image/fx/**）的描述符
--
-- 为什么要有这条路：运行期烘焙（fx.Bake）每次都要跑一遍 Lua 版特效，成本按画布
-- 面积走 —— 216×136 的暴击火花 28 帧要 ~450 ms，300×240 的小爆炸更是要秒级。
-- 这类「贵且形态固定」的特效应该**构建期**烤成 PNG 图集随包发，运行期直接
-- nvgCreateImage 贴上去，零烘焙成本。
--
-- 便宜的、需要运行期换色板的（命中火花、箭矢）继续走运行期烘焙。
-- 两条路在播放器（fx.Px）里是同一个实例结构，只是图集来源不同。
--
-- 构建期怎么烤：scripts/tap-pixelfx/dev/ExportSheets.lua（引擎 headless 跑一遍）。
-- ============================================================================

local ImageCache = require("urhox-libs/UI/Core/ImageCache")

local Sheets = {}

local cache_ = {}

--- 读一个描述符（带缓存；读失败返回 nil，调用方退回运行期烘焙）
---@param jsonPath string 相对 assets/ 的路径
---@return table|nil
function Sheets.descriptor(jsonPath)
    local cached = cache_[jsonPath]
    if cached ~= nil then
        return cached or nil
    end
    local file = cache:GetFile(jsonPath)
    if file == nil then
        cache_[jsonPath] = false
        return nil
    end
    local ok, data = pcall(cjson.decode, file:ReadString())
    if not ok or type(data) ~= "table" then
        cache_[jsonPath] = false
        return nil
    end
    local dir = jsonPath:match("^(.*)/[^/]+$") or ""
    local desc = {
        kind = "sheet",
        id = data.id,
        ready = true,
        imagePath = (dir ~= "" and (dir .. "/") or "") .. tostring(data.image),
        aw = data.aw,
        ah = data.ah,
        w = data.w,
        h = data.h,
        pad = data.pad or 0,
        cw = data.cw or data.w,
        ch = data.ch or data.h,
        cols = data.cols,
        rows = data.rows,
        frames = data.frames,
        fps = data.fps,
        loop = data.loop == true,
        ox = data.origin and data.origin[1] or 0,
        oy = data.origin and data.origin[2] or 0,
    }
    cache_[jsonPath] = desc
    return desc
end

--- 描述符的 NanoVG 图像句柄（走项目现成的 ImageCache，按路径缓存）
---@param nvg any
---@param desc table
---@return integer|nil
function Sheets.imageOf(nvg, desc)
    ImageCache.SetContext(nvg)
    local handle = ImageCache.Get(desc.imagePath)
    if handle == nil or handle <= 0 then
        return nil
    end
    return handle
end

--- 清掉描述符缓存（热重载 / 自检用）
function Sheets.clear()
    cache_ = {}
end

return Sheets
