// Avatar contact sheet.
//
// Renders every drawn part in Resources/Views/_avatar-sprite.leaf across the
// palette in Public/styles.css, so the art can be looked at without booting
// the server or wiring a route.  It reads both files rather than holding its
// own copy of either: a preview that carries its own paths would keep looking
// right after the sprite stopped being.
//
//   node Tools/avatar-preview/preview.mjs > /tmp/avatars.html
//
// Nothing imports this and nothing in CI runs it; it is a looking-glass.

import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..')
const sprite = readFileSync(`${root}/Resources/Views/_avatar-sprite.leaf`, 'utf8')
const css = readFileSync(`${root}/Public/styles.css`, 'utf8')

// A Set because the dark-mode block redeclares every backdrop: without it the
// backdrops are counted twice and the sheet claims twice the birds it has.
const tokens = (prefix, suffix = '') =>
  [...new Set([...css.matchAll(new RegExp(`--avatar-${prefix}([a-z]+)${suffix}:`, 'g'))]
    .map(m => m[1]))]

const caps = tokens('', '-cap')
const cheeks = tokens('cheek-')
const flanks = tokens('flank-')
const backs = tokens('back-')
const wings = [...sprite.matchAll(/id="av-wing-([a-z]+)"/g)].map(m => m[1])

const style = (cap, cheek, flank, back) =>
  `--av-cap:var(--avatar-${cap}-cap);--av-wing:var(--avatar-${cap}-wing);` +
  `--av-beak:var(--avatar-${cap}-beak);--av-cheek:var(--avatar-cheek-${cheek});` +
  `--av-wing-mark:var(--avatar-cheek-${cheek});--av-flank:var(--avatar-flank-${flank});` +
  `--av-backdrop:var(--avatar-back-${back})`

const bird = (size, wing, cap, cheek, flank, back, cls = '') =>
  `<svg class="avatar ${cls}" style="${style(cap, cheek, flank, back)};width:${size}px;height:${size}px"
        viewBox="0 0 64 64" role="img" aria-label="chickadee avatar">
     <use href="#av-backdrop"/><use href="#av-plumage"/><use href="#av-wing-${wing}"/>
     <use href="#av-beak"/><use href="#av-eyes"/></svg>`

const label = (t, inner) => `<figure><div>${inner}</div><figcaption>${t}</figcaption></figure>`
const at = (list, i) => list[i % list.length]

const sections = [
  ['Cap families (wing pattern varies)', caps.map((c, i) =>
    label(c, bird(96, at(wings, i), c, at(cheeks, i), at(flanks, i), at(backs, i))))],
  ['Wing patterns (one cap family)', wings.map(w =>
    label(w, bird(96, w, 'slate', 'snow', 'sand', 'sky')))],
  ['Cheeks', cheeks.map(k => label(k, bird(72, 'plain', 'ink', k, 'stone', 'pebble')))],
  ['Flanks', flanks.map(k => label(k, bird(72, 'plain', 'umber', 'cream', k, 'straw')))],
  ['Backdrops', backs.map(k => label(k, bird(72, 'edged', 'teal', 'snow', 'mist', k)))],
  ['At size', [96, 64, 48, 40, 32, 24, 20, 16].map((s, i) =>
    label(`${s}px`, bird(s, at(wings, i), at(caps, i), 'snow', 'sand', 'sky')))],
]

process.stdout.write(`<!doctype html><meta charset="utf-8">
<title>Chickadee avatar contact sheet</title>
<link rel="stylesheet" href="${root}/Public/styles.css">
<style>
 body{font:13px system-ui;margin:20px;background:var(--bg);color:var(--fg)}
 h2{font-size:14px;margin:18px 0 8px;font-weight:600}
 .sheet{display:flex;flex-wrap:wrap;align-items:flex-end;gap:14px}
 figure{text-align:center}
 figcaption{margin-top:4px;color:var(--muted);font-size:11px}
</style>
${sprite}
<h1 style="font-size:16px">Chickadee avatars — ${caps.length} caps &times; ${cheeks.length} cheeks
&times; ${flanks.length} flanks &times; ${backs.length} backdrops &times; ${wings.length} wings
= ${caps.length * cheeks.length * flanks.length * backs.length * wings.length} birds</h1>
${sections.map(([t, cells]) => `<h2>${t}</h2><div class="sheet">${cells.join('')}</div>`).join('')}
`)
