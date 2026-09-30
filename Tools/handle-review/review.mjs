// Class-handle review sheet.
//
// Reads the two word lists out of Sources/Core/AvatarHandle.swift (it holds no
// copy of them, for the same reason avatar-preview reads the sprite) and checks
// every word and every adjective-noun pair against the lists in data/.  Writes
// an HTML sheet: counts, capacity, every flag, then all pairs in random order
// for a person to skim.
//
//   node Tools/handle-review/review.mjs > /tmp/handles.html
//
// Red flags make the exit status 1, so CI can run it.  Amber flags are for a
// person to judge and do not change the exit status.  A one-line summary goes
// to stderr.

import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'

const here = dirname(fileURLToPath(import.meta.url))
const root = resolve(here, '../..')
const swift = readFileSync(`${root}/Sources/Core/AvatarHandle.swift`, 'utf8')

const swiftList = (name) => {
  const match = swift.match(new RegExp(`static let ${name}: \\[String\\] = \\[([\\s\\S]*?)\\]`))
  if (!match) throw new Error(`AvatarHandle.swift: no list named ${name}`)
  return [...match[1].matchAll(/"([^"]*)"/g)].map((m) => m[1])
}
const adjectives = swiftList('adjectives')
const nouns = swiftList('nouns')
const maxEnrollment = Number(swift.match(/maxExpectedEnrollment = ([\d_]+)/)?.[1].replaceAll('_', ''))

// One entry per line; `#` starts a comment line.
const dataFile = (file) => readFileSync(`${here}/data/${file}`, 'utf8').split('\n')
  .map((line) => line.trim()).filter((line) => line && !line.startsWith('#'))
const fold = (s) => s.toLowerCase()
const foldedSet = (file) => new Set(dataFile(file).map(fold))

const firstNames = foldedSet('first-names.txt')
const surnames = foldedSet('surnames.txt')
const wordLists = [
  ['first name', firstNames],
  ['surname', surnames],
  ['skin-tone word', foldedSet('skin-tone.txt')],
  ['trait', foldedSet('traits.txt')],
  ['slang', foldedSet('slang.txt')],
  ['testing word', foldedSet('testing.txt')],
]
const phrases = dataFile('phrases.txt').map((line) => line.split(/\s+/).map(fold))
const phraseSet = new Set(phrases.map((p) => p.join(' ')))

// Levenshtein distance, stopping early once it passes `limit`.
const distance = (a, b, limit = 1) => {
  if (Math.abs(a.length - b.length) > limit) return limit + 1
  let prev = Array.from({ length: b.length + 1 }, (_, j) => j)
  for (let i = 1; i <= a.length; i++) {
    const row = [i]
    for (let j = 1; j <= b.length; j++) {
      row[j] = Math.min(prev[j] + 1, row[j - 1] + 1, prev[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1))
    }
    if (Math.min(...row) > limit) return limit + 1
    prev = row
  }
  return prev[b.length]
}

const red = []
const amber = []

// Word checks.
for (const [list, words] of [['adjective', adjectives], ['noun', nouns]]) {
  for (const word of words) {
    for (const [reason, set] of wordLists) {
      if (set.has(fold(word))) red.push({ item: word, reason: `${list} is a ${reason}` })
    }
  }
}

// Pair checks.
for (const adjective of adjectives) {
  for (const noun of nouns) {
    const a = fold(adjective)
    const n = fold(noun)
    const pair = `${adjective} ${noun}`
    if (firstNames.has(a) && surnames.has(n)) red.push({ item: pair, reason: 'reads as a person' })
    if (phraseSet.has(`${a} ${n}`)) {
      red.push({ item: pair, reason: 'is a brand, title, place or idiom' })
      continue
    }
    for (const [pa, pn] of phrases) {
      if ((pa === a && distance(pn, n) === 1) || (pn === n && distance(pa, a) === 1)) {
        amber.push({ item: pair, reason: `one edit from "${pa} ${pn}"` })
      }
    }
    // "Leafy Leaf": not harmful, but it reads as a stammer.
    if (a.slice(0, 4) === n.slice(0, 4)) amber.push({ item: pair, reason: 'both words share a stem' })
  }
}

const pairs = adjectives.flatMap((a) => nouns.map((n) => `${a} ${n}`))
for (let i = pairs.length - 1; i > 0; i--) {
  const j = Math.floor(Math.random() * (i + 1))
  ;[pairs[i], pairs[j]] = [pairs[j], pairs[i]]
}

const escape = (s) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c])
const capacity = adjectives.length * nouns.length
const ratio = capacity / maxEnrollment
const flagRows = (flags, level) => flags.map((f) =>
  `<tr class="${level}"><td>${level}</td><td>${escape(f.item)}</td><td>${escape(f.reason)}</td></tr>`).join('\n')

process.stdout.write(`<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Handle review</title>
<style>
  body { font: 14px/1.4 system-ui, sans-serif; margin: 2rem; color: #1d2330; background: #fff; }
  table { border-collapse: collapse; margin-bottom: 2rem; }
  td, th { padding: 0.2rem 0.6rem; border-bottom: 1px solid #dde; text-align: left; }
  tr.red td:first-child { color: #fff; background: #b3261e; }
  tr.amber td:first-child { background: #f2c14e; }
  .grid { columns: 12rem; column-gap: 1.5rem; }
  .grid div { break-inside: avoid; }
</style></head><body>
<h1>Class handle review</h1>
<p>${adjectives.length} adjectives × ${nouns.length} nouns = <strong>${capacity.toLocaleString('en')}</strong> handles.
Largest expected course: ${maxEnrollment.toLocaleString('en')} students, so the pool is
<strong>${ratio.toFixed(1)}×</strong> (at least 4× is required${ratio >= 4 ? '' : ' — <strong>not met</strong>'}).</p>
<h2>Flags: ${red.length} red, ${amber.length} amber</h2>
${red.length + amber.length === 0 ? '<p>None.</p>' : `<table>
<tr><th>Level</th><th>Word or pair</th><th>Reason</th></tr>
${flagRows(red, 'red')}
${flagRows(amber, 'amber')}
</table>`}
<h2>All pairs, random order</h2>
<div class="grid">${pairs.map((p) => `<div>${escape(p)}</div>`).join('')}</div>
</body></html>
`)

const capacityFailed = !(ratio >= 4)
console.error(`handle review: ${capacity} handles, ${ratio.toFixed(1)}x capacity, ${red.length} red, ${amber.length} amber`)
for (const f of red) console.error(`  red: ${f.item} ${f.reason}`)
for (const f of amber) console.error(`  amber: ${f.item} ${f.reason}`)
process.exit(red.length > 0 || capacityFailed ? 1 : 0)
