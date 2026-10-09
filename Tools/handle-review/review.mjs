// Class-handle review sheet.
//
// Reads the word lists and the scientist table out of Sources/Core (it holds
// no copy of them, for the same reason avatar-preview reads the sprite) and
// checks the three schemes against the lists in data/:
//
// - disposition + scientist ("Curious Noether")
// - science noun + agent ("Photon Navigator")
// - compound word ("Ionspark")
//
// Writes an HTML sheet: counts, capacity, balance, every flag, the scientist
// table, then every science pair and every compound in random order for a
// person to skim.
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
const source = (file) => readFileSync(`${root}/Sources/Core/${file}`, 'utf8')
const handleSwift = source('AvatarHandle.swift')
const wordsSwift = source('AvatarHandleWords.swift')
const scientistsSwift = source('AvatarHandleScientists.swift')

const swiftList = (name) => {
  const match = wordsSwift.match(new RegExp(`static let ${name}: \\[String\\] = \\[([\\s\\S]*?)\\]`))
  if (!match) throw new Error(`AvatarHandleWords.swift: no list named ${name}`)
  return [...match[1].matchAll(/"([^"]*)"/g)].map((m) => m[1])
}
const dispositions = swiftList('dispositions')
const scienceNouns = swiftList('scienceNouns')
const agents = swiftList('agents')
const prefixes = swiftList('compoundPrefixes')
const suffixes = swiftList('compoundSuffixes')
const maxEnrollment = Number(handleSwift.match(/maxExpectedEnrollment = ([\d_]+)/)?.[1].replaceAll('_', ''))

// One data line per scientist; `#` starts a comment line.  The same fields
// as AvatarHandle.Scientist.
const table = scientistsSwift.match(/scientistRecords = #"""\n([\s\S]*?)\n\s*"""#/)
if (!table) throw new Error('AvatarHandleScientists.swift: no scientistRecords table')
const fieldNames = ['handle', 'full name', 'field', 'born', 'died', 'region', 'gender', 'note']
const regions = new Set([
  'Africa', 'East Asia', 'Europe', 'Latin America', 'North America', 'Oceania', 'South Asia',
  'West & Central Asia',
])
const genders = new Set(['F', 'M', 'M+F'])
const year = /^~?-?\d+$/
const parsePsv = (text) => text.split('\n').map((line) => line.trim())
  .filter((line) => line && !line.startsWith('#')).map((line) => line.split('|').map((f) => f.trim()))
const scientistRows = parsePsv(table[1])

// One entry per line; `#` starts a comment line.
const dataFile = (file) => readFileSync(`${here}/data/${file}`, 'utf8').split('\n')
  .map((line) => line.trim()).filter((line) => line && !line.startsWith('#'))
const fold = (s) => s.toLowerCase()
const foldedSet = (file) => new Set(dataFile(file).map(fold))

const firstNames = foldedSet('first-names.txt')
const surnames = foldedSet('surnames.txt')
const skinTone = foldedSet('skin-tone.txt')
const traits = foldedSet('traits.txt')
const positiveTraits = foldedSet('positive-traits.txt')
const slang = foldedSet('slang.txt')
const testing = foldedSet('testing.txt')
const substrings = dataFile('substrings.txt').map(fold)
const removedForBalance = new Set(parsePsv(readFileSync(`${here}/data/removed-for-balance.psv`, 'utf8'))
  .map((fields) => fields[0]))
const wordLists = [
  ['first name', firstNames],
  ['surname', surnames],
  ['skin-tone word', skinTone],
  ['trait', traits],
  ['slang', slang],
  ['testing word', testing],
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

// The same rule as AvatarHandle.hasHandleShape: one to three words, each an
// upper-case letter and then letters, with single inner hyphens.
const handleWord = /^\p{Lu}\p{L}*(?:-\p{L}+)*$/u
const hasHandleShape = (handle) => {
  const words = handle.split(' ')
  return words.length >= 1 && words.length <= 3 && words.every((w) => handleWord.test(w))
}

const red = []
const amber = []

// Scientist table.
const scientists = []
for (const fields of scientistRows) {
  const line = fields.join('|')
  if (fields.length !== 8) {
    red.push({ item: line, reason: `has ${fields.length} fields, not 8` })
    continue
  }
  const [handle, fullName, field, born, died, region, gender, note] = fields
  const missing = fieldNames.filter((_, i) => i !== 4 && !fields[i])
  if (missing.length) red.push({ item: line, reason: `has no ${missing.join(', ')}` })
  if (!regions.has(region)) red.push({ item: handle, reason: `has an unknown region "${region}"` })
  if (!genders.has(gender)) red.push({ item: handle, reason: `has an unknown gender "${gender}"` })
  if (!year.test(born) || (died && !year.test(died))) red.push({ item: handle, reason: 'has a malformed year' })
  if (handle.split(' ').length > 2) red.push({ item: handle, reason: 'has more than two words' })
  if (died === '') amber.push({ item: handle, reason: 'is alive: check the honour and the news before each term' })
  if (removedForBalance.has(handle)) amber.push({ item: handle, reason: 'was removed for balance' })
  for (const word of handle.split(/[ -]/).map(fold)) {
    if (slang.has(word)) red.push({ item: handle, reason: `holds the slang word "${word}"` })
    if (testing.has(word)) red.push({ item: handle, reason: `holds the testing word "${word}"` })
    if (skinTone.has(word)) amber.push({ item: handle, reason: `holds the skin-tone word "${word}"` })
  }
  scientists.push({ handle, fullName, field, born, died, region, gender, note })
}

// Balance: an entry that names two people counts as half a woman.
const women = scientists.reduce((n, s) => n + (s.gender === 'F' ? 1 : s.gender === 'M+F' ? 0.5 : 0), 0)
const womenShare = women / scientists.length
const europeShare = scientists.filter((s) => s.region === 'Europe').length / scientists.length
const percent = (x) => `${(100 * x).toFixed(1)}%`
if (!(womenShare >= 0.4)) amber.push({ item: 'scientists', reason: `${percent(womenShare)} women, under the 40% target` })
if (!(europeShare <= 0.35)) amber.push({ item: 'scientists', reason: `${percent(europeShare)} from Europe, over the 35% target` })

// Word checks.  A disposition may be a positive trait; nothing else may.
const lists = [
  ['disposition', dispositions],
  ['science noun', scienceNouns],
  ['agent', agents],
]
for (const [list, words] of lists) {
  const seen = new Set()
  for (const word of words) {
    if (seen.has(word)) red.push({ item: word, reason: `${list} is listed twice` })
    seen.add(word)
    for (const [reason, set] of wordLists) {
      if (set.has(fold(word))) red.push({ item: word, reason: `${list} is a ${reason}` })
    }
    if (list !== 'disposition' && positiveTraits.has(fold(word))) {
      red.push({ item: word, reason: `${list} is a positive trait, allowed only as a disposition` })
    }
  }
}
const dispositionSet = new Set(dispositions.map(fold))
for (const [list, words] of [...lists.slice(1), ['compound prefix', prefixes], ['compound suffix', suffixes]]) {
  for (const word of words) {
    if (dispositionSet.has(fold(word))) red.push({ item: word, reason: `${list} is also a disposition` })
  }
}

// Scheme 1: disposition + scientist.
for (const disposition of dispositions) {
  for (const s of scientists) {
    const pair = `${fold(disposition)} ${fold(s.handle)}`
    if (phraseSet.has(pair)) red.push({ item: `${disposition} ${s.handle}`, reason: 'is a brand, title, place or idiom' })
  }
}

// Scheme 2: science noun + agent.
for (const noun of scienceNouns) {
  for (const agent of agents) {
    const a = fold(noun)
    const n = fold(agent)
    const pair = `${noun} ${agent}`
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

// Scheme 3: compound words.  The join can form a word that neither part
// holds, so the whole word is checked, and every unwanted substring in it.
const compounds = prefixes.flatMap((p) => suffixes.map((s) => p + s))
for (const word of compounds) {
  for (const [reason, set] of wordLists) {
    if (set.has(fold(word))) red.push({ item: word, reason: `compound is a ${reason}` })
  }
  if (positiveTraits.has(fold(word))) red.push({ item: word, reason: 'compound is a positive trait' })
  for (const bad of substrings) {
    if (fold(word).includes(bad)) red.push({ item: word, reason: `compound holds "${bad}"` })
  }
}

// Every handle: unique across the schemes, the right shape, and NFC.
const schemes = [
  ['scientist', dispositions.flatMap((d) => scientists.map((s) => `${d} ${s.handle}`))],
  ['science', scienceNouns.flatMap((n) => agents.map((a) => `${n} ${a}`))],
  ['compound', compounds],
]
const owner = new Map()
for (const [scheme, handles] of schemes) {
  for (const handle of handles) {
    if (owner.has(handle)) red.push({ item: handle, reason: `is in the ${owner.get(handle)} and ${scheme} schemes` })
    owner.set(handle, scheme)
    if (!hasHandleShape(handle)) red.push({ item: handle, reason: 'does not have the handle shape' })
    if (handle.normalize('NFC') !== handle) red.push({ item: handle, reason: 'is not in Unicode NFC form' })
  }
}

const shuffled = (items) => {
  const copy = [...items]
  for (let i = copy.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1))
    ;[copy[i], copy[j]] = [copy[j], copy[i]]
  }
  return copy
}

const escape = (s) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c])
const capacity = schemes.reduce((n, [, handles]) => n + handles.length, 0)
const ratio = capacity / maxEnrollment
const flagRows = (flags, level) => flags.map((f) =>
  `<tr class="${level}"><td>${level}</td><td>${escape(f.item)}</td><td>${escape(f.reason)}</td></tr>`).join('\n')
const schemeRows = [
  ['Disposition + scientist', dispositions.length, scientists.length],
  ['Science noun + agent', scienceNouns.length, agents.length],
  ['Compound word', prefixes.length, suffixes.length],
].map(([name, a, b]) => `<tr><td>${name}</td><td>${a} × ${b}</td><td>${(a * b).toLocaleString('en')}</td></tr>`)
  .join('\n')
const scientistRowsHtml = scientists.map((s) => `<tr><td>${escape(s.handle)}</td><td>${escape(s.fullName)}</td>` +
  `<td>${escape(s.field)}</td><td>${escape(s.born)}–${escape(s.died || 'alive')}</td><td>${escape(s.region)}</td>` +
  `<td>${escape(s.gender)}</td><td>${escape(s.note)}</td></tr>`).join('\n')
const grid = (items) => `<div class="grid">${shuffled(items).map((p) => `<div>${escape(p)}</div>`).join('')}</div>`

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
<table>
<tr><th>Scheme</th><th>Lists</th><th>Handles</th></tr>
${schemeRows}
</table>
<p><strong>${capacity.toLocaleString('en')}</strong> handles.
Largest expected course: ${maxEnrollment.toLocaleString('en')} students, so the pool is
<strong>${ratio.toFixed(1)}×</strong> (at least 4× is required${ratio >= 4 ? '' : ' — <strong>not met</strong>'}).</p>
<p>Scientists: ${scientists.length}, ${percent(womenShare)} women (target: at least 40%),
${percent(europeShare)} from Europe (target: at most 35%),
${scientists.filter((s) => !s.died).length} alive.</p>
<h2>Flags: ${red.length} red, ${amber.length} amber</h2>
${red.length + amber.length === 0 ? '<p>None.</p>' : `<table>
<tr><th>Level</th><th>Handle, word or entry</th><th>Reason</th></tr>
${flagRows(red, 'red')}
${flagRows(amber, 'amber')}
</table>`}
<h2>Dispositions</h2>
<p>${dispositions.map(escape).join(', ')}</p>
<h2>Scientists</h2>
<table>
<tr><th>Handle</th><th>Full name</th><th>Field</th><th>Years</th><th>Region</th><th>Gender</th><th>Note</th></tr>
${scientistRowsHtml}
</table>
<h2>All science pairs, random order</h2>
${grid(schemes[1][1])}
<h2>All compound words, random order</h2>
${grid(compounds)}
</body></html>
`)

const capacityFailed = !(ratio >= 4)
console.error(`handle review: ${capacity} handles, ${ratio.toFixed(1)}x capacity, ` +
  `${percent(womenShare)} women, ${percent(europeShare)} Europe, ${red.length} red, ${amber.length} amber`)
for (const f of red) console.error(`  red: ${f.item} ${f.reason}`)
for (const f of amber) console.error(`  amber: ${f.item} ${f.reason}`)
process.exit(red.length > 0 || capacityFailed ? 1 : 0)
