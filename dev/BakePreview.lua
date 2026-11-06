-- ============================================================================
-- fx/dev/BakePreview.lua — 引擎侧烘焙验收台
--
-- 干三件事：
--   1. 把所有已移植特效一次性烤完（不开游戏、不进战斗）
--   2. 把每份图集存成 PNG（Bake.captureDir），于是「引擎里到底画出了什么」可以肉眼看
--   3. 打印每个特效的帧数、图集尺寸、烘焙耗时，顺手断言图集不是全空
--
-- 跑法：
--   ./.cli/UrhoXRuntime scripts/tap-pixelfx/dev/BakePreview.lua -tapcode_dir="$PWD" -tool_mode \
--       -graphicsheadless -validate -validate-frames=2 -validate-timeout=120 -log info
--
-- 输出：screenshots/fx/<id>_<帧数>f.png
-- ============================================================================

local Bake = require "tap-pixelfx.runtime.Bake"
local Registry = require "tap-pixelfx.runtime.Registry"

local CAPTURE_DIR = "screenshots/fx"

--- 图集里是否至少有一个非空像素（防「烤了个全黑」这种静默失败）
local function atlasHasContent(job)
    local img = job.image
    if img == nil then
        return job.ready
    end
    local aw, ah = job.aw, job.ah
    for y = 0, ah - 1 do
        for x = 0, aw - 1 do
            local c = img:GetPixelInt(x, y)
            if c ~= nil and (c & 0xFF000000) ~= 0 then
                return true
            end
        end
    end
    return false
end

function Start()
    local ok, err = pcall(function()
        Registry.register()
        Bake.verbose = true
        Bake.captureDir = CAPTURE_DIR
        Bake.profile = true

        local ids = Registry.ids()
        print(string.format("[fx-preview] 已移植特效 %d 个", #ids))
        for _, id in ipairs(ids) do
            Bake.request(id)
        end

        local t0 = os.clock()
        local pending = Bake.flush(120000)
        local totalMs = (os.clock() - t0) * 1000
        print(string.format("[fx-preview] 全量烘焙 %.1f ms，剩余 %d 帧", totalMs, pending))
        assert(pending == 0, "烘焙队列没烤完")

        local frames, worst = 0, 0
        for _, id in ipairs(ids) do
            local job = Bake.request(id)
            assert(job ~= nil and job.ready, id .. " 没烤好")
            frames = frames + job.frames
            if job.ms > worst then
                worst = job.ms
            end
            print(string.format(
                "[fx-preview] %-26s %3d 帧 %3dx%-3d → 图集 %4dx%-4d  烘焙 %7.1f ms",
                id, job.frames, job.w, job.h, job.aw, job.ah, job.ms
            ))
            assert(atlasHasContent(job), id .. " 的图集是空的")
            local tm = job.timing
            if tm ~= nil then
                print(string.format(
                    "[fx-preview]   每帧均摊：模拟 %.2f ms / 合成 %.2f ms / 上传 %.2f ms（矩形 %.0f px，实写 %.0f px）",
                    tm.sim / job.frames, tm.comp / job.frames, tm.up / job.frames,
                    tm.box / job.frames, tm.px / job.frames
                ))
            end
        end
        print(string.format("[fx-preview] 合计 %d 帧，最慢一份 %.1f ms", frames, worst))

        Bake.captureDir = nil
        print("[fx-preview] RESULT=PASS")
    end)
    if not ok then
        print("[fx-preview] RESULT=FAIL " .. tostring(err))
        log:Write(LOG_ERROR, "[fx-preview] " .. tostring(err))
    end
end
