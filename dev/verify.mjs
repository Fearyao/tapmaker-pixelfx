// 一键验收：把「Lua 移植 == pixelfx JS 原版」和「随包图集 == JS 原版」两条都跑一遍。
//
// 用法：
//   node dev/verify.mjs                       # 全量
//   node dev/verify.mjs --only impacts/hit-spark
//   node dev/verify.mjs --skip-sheet          # 只跑逐像素对拍
//
// 需要：
//   - pixelfx 原版仓库（环境变量 PIXELFX_DIR；默认 ~/game/pixelfx）
//   - wasmoon（node_modules/wasmoon 或 WASMOON_PATH）
//   - python3 + Pillow（只在跑图集比对时需要）
//
// 退出码 0 = 全绿；1 = 有差异（CI 直接用它当闸门）。

import { spawnSync } from 'node:child_process'
import { existsSync, readFileSync, rmSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import path from 'node:path'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const HARNESS = path.join(HERE, 'harness')
const PKG_ROOT = path.resolve(HERE, '..')
const TMP = path.join(PKG_ROOT, '.tmp')

function findUp(start, rel, depth = 8) {
    let dir = start
    for (let i = 0; i < depth; i++) {
        const candidate = path.join(dir, rel)
        if (existsSync(candidate)) return candidate
        const parent = path.dirname(dir)
        if (parent === dir) break
        dir = parent
    }
    return null
}

const PIXELFX_DIR =
    process.env.PIXELFX_DIR ||
    (existsSync(path.join(process.env.HOME || '', 'game/pixelfx'))
        ? path.join(process.env.HOME, 'game/pixelfx')
        : null)

const argv = process.argv.slice(2)
const only = argv.includes('--only') ? argv[argv.indexOf('--only') + 1] : null
const skipSheet = argv.includes('--skip-sheet')

const manifest = JSON.parse(readFileSync(path.join(HERE, 'manifest.json'), 'utf8')).filter(
    (e) => !only || e.id === only
)

function run(cmd, args, opts = {}) {
    const res = spawnSync(cmd, args, { stdio: 'pipe', encoding: 'utf8', ...opts })
    return { ok: res.status === 0, out: (res.stdout || '') + (res.stderr || ''), status: res.status }
}

function fail(msg) {
    console.error('\n✗ ' + msg)
    process.exit(1)
}

if (!PIXELFX_DIR || !existsSync(path.join(PIXELFX_DIR, 'src/core/index.js'))) {
    fail(
        '找不到 pixelfx 原版仓库。设置 PIXELFX_DIR 指向它：\n' +
            '  PIXELFX_DIR=/path/to/pixelfx node dev/verify.mjs\n' +
            '  git clone https://github.com/patch-gg/pixelfx.git ~/game/pixelfx'
    )
}

rmSync(TMP, { recursive: true, force: true })

const rows = []
let failed = 0

// ---- 1) 逐像素对拍：JS 原版 vs Lua 移植 ----
for (const { id, module } of manifest) {
    const refDir = path.join(TMP, 'ref', module)
    const luaDir = path.join(TMP, 'lua', module)
    const js = run('node', [path.join(HARNESS, 'dump-js.mjs'), id, refDir], {
        env: { ...process.env, PIXELFX_DIR },
    })
    if (!js.ok) fail(`JS 参考帧导出失败: ${id}\n${js.out}`)
    const lua = run('node', [path.join(HARNESS, 'dump-lua.mjs'), module, luaDir])
    if (!lua.ok) fail(`Lua 帧导出失败: ${module}\n${lua.out}`)
    const cmp = run('node', [path.join(HARNESS, 'compare.mjs'), refDir, luaDir])
    const last = cmp.out.trim().split('\n').pop()
    rows.push({ check: 'parity', id, ok: cmp.ok, detail: last })
    if (!cmp.ok) failed++
    console.log(`${cmp.ok ? '✓' : '✗'} parity ${id} — ${last}`)
}

// ---- 2) 随包图集 vs JS 参考帧 ----
if (!skipSheet) {
    const sheetArgs = [path.join(HARNESS, 'compare-sheet.py'), '--all', path.join(TMP, 'ref')]
    if (only) sheetArgs.push('--only', only)
    const sheet = run('python3', sheetArgs, { cwd: PKG_ROOT })
    if (!sheet.ok && /No module named 'PIL'|No module named "PIL"/.test(sheet.out)) {
        console.log('⚠ 跳过图集比对：没装 Pillow（pip3 install pillow）')
    } else {
        // compare-sheet 的输出形如： "<id>\tMATCH  全部 16 帧一致"
        const lines = sheet.out.trim().split('\n')
        for (const line of lines) {
            const m = line.match(/^\s*(\S+)\s+(MATCH|DIFF)\s*(.*)$/)
            if (!m) continue
            const [, id, verdict, detail] = m
            const ok = verdict === 'MATCH'
            rows.push({ check: 'atlas', id, ok, detail: detail.trim() })
            if (!ok) failed++
            console.log(`${ok ? '✓' : '✗'} atlas  ${id} — ${detail.trim()}`)
        }
        if (!sheet.ok && !lines.some((l) => l.startsWith('DIFF'))) fail('图集比对异常：\n' + sheet.out)
    }
}

// ---- 汇总 ----
const parity = rows.filter((r) => r.check === 'parity')
const atlas = rows.filter((r) => r.check === 'atlas')
console.log(
    `\n逐像素对拍 ${parity.filter((r) => r.ok).length}/${parity.length}` +
        (atlas.length ? `，图集一致 ${atlas.filter((r) => r.ok).length}/${atlas.length}` : '') +
        ` → RESULT=${failed === 0 ? 'PASS' : 'FAIL'}`
)

// 失败时保留产物，方便肉眼看差异
if (failed === 0) rmSync(TMP, { recursive: true, force: true })
process.exit(failed === 0 ? 0 : 1)
