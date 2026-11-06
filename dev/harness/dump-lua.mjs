// Lua 侧参考帧导出：用 wasmoon（Lua 5.4 WASM）跑 scripts/tap-pixelfx 下的移植版，
// 走和引擎里完全相同的帧步进（scripts/tap-pixelfx/dev/FrameDump.lua），逐帧落成裸 RGBA。
//
// 用法：node scripts/tap-pixelfx/dev/harness/dump-lua.mjs <module> <out-dir> [frames] [optsJSON]
//   module 是 scripts/tap-pixelfx/effects 下的模块名，例如 HitSpark
//   帧数据从 Lua 交回 JS 时走 hex，避免 UTF-8 解码把裸字节吃掉

import { readFile, writeFile, mkdir, rm } from 'node:fs/promises'
import { readdirSync, statSync, existsSync } from 'node:fs'
import { fileURLToPath, pathToFileURL } from 'node:url'
import path from 'node:path'

const HERE = path.dirname(fileURLToPath(import.meta.url))

// 往上找到项目根（含 scripts/ 与 tools/ 的那一级）
function findRoot(start) {
    let dir = start
    for (let i = 0; i < 8; i++) {
        if (
            existsSync(path.join(dir, 'scripts/tap-pixelfx')) &&
            existsSync(path.join(dir, 'tools/lua-selftest/node_modules/wasmoon'))
        ) {
            return dir
        }
        const parent = path.dirname(dir)
        if (parent === dir) break
        dir = parent
    }
    throw new Error('找不到项目根（需要 scripts/tap-pixelfx 和 tools/lua-selftest/node_modules/wasmoon）')
}

const ROOT = findRoot(HERE)
const WASMOON_ENTRY = path.resolve(ROOT, 'tools/lua-selftest/node_modules/wasmoon/dist/index.js')

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

const files = collectSources(path.join(ROOT, 'scripts/tap-pixelfx'), 'tap-pixelfx.')
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
