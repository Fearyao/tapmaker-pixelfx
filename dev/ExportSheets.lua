-- ============================================================================
-- fx/dev/ExportSheets.lua — 构建期：把特效烤成图集 PNG + JSON 随包发
--
-- 跑一次就把 Registry.SHEETS 里列的所有特效写成：
--   scripts/tap-pixelfx/atlas/<category>/<name>.png    图集（每格四周留 Bake.PAD 透明边）
--   scripts/tap-pixelfx/atlas/<category>/<name>.json   描述符（帧数/格大小/原点/fps/loop）
-- 之后运行期播放器直接 nvgCreateImage 贴图，零烘焙成本。
--
-- 跑法（在项目根目录）：
--   ./.cli/UrhoXRuntime scripts/tap-pixelfx/dev/ExportSheets.lua -tapcode_dir="$PWD" -tool_mode \
--       -graphicsheadless -validate -validate-frames=2 -validate-timeout=300 -log info
--
-- 什么时候要重跑：改了任何一个 fx/effects/*.lua 的绘制逻辑，或者改了
-- Registry.DEFAULT_SCALE 之外的烘焙参数（色板默认值 / 帧数裁剪）。
-- 纯显示缩放（scale）不用重跑，那是播放时的事。
-- ============================================================================

local Bake = require "tap-pixelfx.runtime.Bake"
local Registry = require "tap-pixelfx.runtime.Registry"

function Start()
    local ok, err = pcall(function()
        Registry.register()
        Bake.verbose = true
        Bake.retainImages = true

        local count = 0
        for id, sheet in pairs(Registry.SHEETS) do
            local job = Bake.request(id, sheet.opts)
            assert(job ~= nil, "没注册的特效: " .. id)
            local pending = Bake.flush(600000)
            assert(job.ready, id .. " 没烤好")
            assert(pending == 0, id .. " 之后队列还有剩余")
            assert(job.image ~= nil, id .. " 需要 Bake.retainImages")
            -- sheet.json 是资源相对路径（相对 scripts/ 或 assets/），落盘要加 scripts/ 前缀
            local jsonPath = "scripts/" .. sheet.json
            local saved = Bake.exportSheet(job, jsonPath)
            assert(saved, id .. " 导出失败: " .. jsonPath)
            count = count + 1
            print(string.format(
                "[fx-export] %-26s %3d 帧 %3dx%-3d → %s（烤 %.1f ms）",
                id, job.frames, job.w, job.h, jsonPath, job.ms
            ))
        end
        print(string.format("[fx-export] 共导出 %d 份图集 RESULT=PASS", count))
    end)
    if not ok then
        print("[fx-export] RESULT=FAIL " .. tostring(err))
        log:Write(LOG_ERROR, "[fx-export] " .. tostring(err))
    end
end
