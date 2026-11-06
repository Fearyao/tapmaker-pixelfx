// Lua 侧参考帧导出：用 wasmoon（Lua 5.4 WASM）跑本库的移植版，
// 走和引擎里完全相同的帧步进（dev/FrameDump.lua），逐帧落成裸 RGBA。
//
// 两种目录布局都支持：
//   独立库（仓库根就是这个包）        node dev/harness/dump-lua.mjs ...
//   被工程内嵌（scripts/tap-pixelfx） node scripts/tap-pixelfx/dev/harness/dump-lua.mjs ...
//
// 用法：node <harness>/dump-lua.mjs <module> <out-dir> [frames] [optsJSON]
//   module 是 effects/ 下的模块名，例如 HitSpark
//   帧数据从 Lua 交回 JS 时走 hex，避免 UTF-8 解码把裸字节吃掉

import { readFile, writeFile, mkdir, rm } from 'node:fs/promises'
import { readdirSync, statSync, existsSync } from 'node:fs'
import { fileURLToPath, pathToFileURL } from 'node:url'
import path from 'node:path'

const HERE = path.dirname(fileURLToPath(import.meta.url))

// 往上找到包根（含 init.lua 与 core/Core.lua 的那一级）
function findPackageRoot(start) {
    let dir = start
    for (let i = 0; i < 8; i++) {
        if (existsSync(path.join(dir, 'init.lua')) && existsSync(path.join(dir, 'core/Core.lua'))) {
            return dir
        }
        const parent = path.dirname(dir)
        if (parent === dir) break
        dir = parent
    }
    throw new Error('找不到 tap-pixelfx 包根（需要 init.lua 与 core/Core.lua）')
}

// wasmoon 的入口：环境变量优先，其次往上找 node_modules（独立库或宿主工程都适用）
function findWasmoon(start) {
    const fromEnv = process.env.WASMOON_PATH
    if (fromEnv && existsSync(fromEnv)) return fromEnv
    let dir = start
    for (let i = 0; i < 8; i++) {
        for (const rel of [
            'node_modules/wasmoon/dist/index.js',
            'tools/lua-selftest/node_modules/wasmoon/dist/index.js',
        ]) {
            const candidate = path.join(dir, rel)
            if (existsSync(candidate)) return candidate
        }
        const parent = path.dirname(dir)
        if (parent === dir) break
        dir = parent
    }
    throw new Error(
        '找不到 wasmoon：设置 WASMOON_PATH，或在包根执行 `npm install wasmoon`，\n' +
            '或在宿主工程里运行（tools/lua-selftest/node_modules/wasmoon）'
    )
}

const PKG_ROOT = findPackageRoot(HERE)
const WASMOON_ENTRY = findWasmoon(HERE)

const name = process.argv[2]
const outDir = process.argv[3]
const frameArg = process.argv[4] ? Number(process.argv[4]) : null
const optsArg = process.argv[5] ? JSON.parse(process.argv[5]) : null
if (!name || !outDir) {
    console.error('usage: node dump-lua.mjs <module> <out-dir> [frames] [optsJSON]')
    process.exit(2)
}

function collectSources(dir, prefix, acc = {}) {
    for (const entry of readdirSync(dir)) {
        const full = path.join(dir, entry)
        if (statSync(full).isDirectory()) collectSources(full, prefix + entry + '.', acc)
        else if (entry.endsWith('.lua')) acc[prefix + entry.replace(/\.lua$/, '')] = full
    }
    return acc
}

const files = collectSources(PKG_ROOT, 'tap-pixelfx.')
const rows = []
for (const [key, file] of Object.entries(files)) {
    rows.push(`    [${JSON.stringify(key)}] = ${JSON.stringify(await readFile(file, 'utf8'))},`)
}

function luaLiteral(v) {
    if (v === null || v === undefined) return 'nil'
    if (typeof v === 'number' || typeof v === 'boolean') return String(v)
    if (typeof v === 'string') return JSON.stringify(v)
    if (Array.isArray(v)) return `{ ${v.map(luaLiteral).join(', ')} }`
    const kv = Object.entries(v).map(([k, val]) => `[${JSON.stringify(k)}] = ${luaLiteral(val)}`)
    return `{ ${kv.join(', ')} }`
}

const driver = `
package.loaded = package.loaded or {}
local __sources = {
${rows.join('\n')}
}
local __loaded = package.loaded
local __loader = load
function require(name)
    local cached = __loaded[name]
    if cached ~= nil then return cached end
    local src = __sources[name]
    if not src then error("module not found: " .. tostring(name)) end
    local chunk, err = __loader(src, "@" .. tostring(name) .. ".lua")
    if not chunk then error(err) end
    local result = chunk()
    if result == nil then result = true end
    __loaded[name] = result
    return result
end

local FrameDump = require "tap-pixelfx.dev.FrameDump"
local opts = ${luaLiteral(optsArg)}
local frames = ${frameArg === null ? 'nil' : String(frameArg)}
if frames ~= nil then
    opts = opts or {}
    opts.frames = frames
end

local mod = require("tap-pixelfx.effects.${name}")
FrameDump.capture(mod, opts or {}, function(i, rgba, w, h)
    local hex = FrameDump.pack(rgba, w * h * 4):gsub(".", function(c)
        return string.format("%02x", string.byte(c))
    end)
    __capture__(i, hex, w, h)
end)
`

const mod = await import(pathToFileURL(WASMOON_ENTRY).href)
const factory = new mod.LuaFactory()
const lua = await factory.createEngine()

const frames = []
let W = 0
let H = 0
lua.global.set('__capture__', (i, hex, w, h) => {
    W = w
    H = h
    frames[i] = Buffer.from(hex, 'hex')
})

await lua.doString(driver)
lua.global.close()

await rm(outDir, { recursive: true, force: true })
await mkdir(outDir, { recursive: true })
let written = 0
for (let i = 0; i < frames.length; i++) {
    if (!frames[i]) continue
    await writeFile(path.join(outDir, `f${String(i).padStart(3, '0')}.rgba`), frames[i])
    written++
}
await writeFile(
    path.join(outDir, 'meta.json'),
    JSON.stringify({ module: name, w: W, h: H, frames: written, opts: optsArg }, null, 2)
)
console.log(`${name}: ${written} frames ${W}x${H} -> ${outDir}`)
