// Class-handle review sheet.
//
// Reads the handle lists out of Sources/Core/AvatarHandle+Words.swift and
// Sources/Core/AvatarHandle+Scientists.swift (it holds no copy of them, for
// the same reason avatar-preview reads the sprite) and checks every word,
// scientist, pair and compound against the lists in data/.  Writes an HTML
// sheet: counts, capacity, balance, every flag, then a sample of handles from
// each scheme for a person to skim.
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
const wordsSwift = source('AvatarHandle+Words.swift')
const scientistsSwift = source('AvatarHandle+Scientists.swift')
const handleSwift = source('AvatarHandle.swift')

// A Swift string literal's body, with its escapes undone.
const STRING = '"((?:[^"\\\\]|\\\\.)*)"'
const unescape = (s) => s.replace(/\\(.)/g, '$1')

const swiftList = (swift, name) => {
  const match = swift.match(new RegExp(`static let ${name}: \\[String\\] = \\[([\\s\\S]*?)\\]`))
  if (!match) throw new Error(`no list named ${name}`)
  return [...match[1].matchAll(new RegExp(STRING, 'g'))].map((m) => unescape(m[1]))
}

const dispositions = swiftList(wordsSwift, 'dispositions')
const scienceWords = swiftList(wordsSwift, 'scienceWords')
const agents = swiftList(wordsSwift, 'agents')
const prefixes = swiftList(wordsSwift, 'compoundPrefixes')
const suffixes = swiftList(wordsSwift, 'compoundSuffixes')
const removedForBalance = swiftList(scientistsSwift, 'removedForBalance')

const entry = new RegExp(
  `\\.init\\(\\s*${STRING},\\s*fullName:\\s*${STRING},\\s*field:\\s*${STRING},\\s*years:\\s*${STRING},` +
    `(\\s*isLiving:\\s*true,)?\\s*region:\\s*\\.(\\w+),\\s*gender:\\s*\\.(\\w+),\\s*note:\\s*${STRING}\\s*\\)`,
  'g',
)
const scientists = [...scientistsSwift.matchAll(entry)].map((m) => ({
  name: unescape(m[1]),
  fullName: unescape(m[2]),
  field: unescape(m[3]),
  years: unescape(m[4]),
  isLiving: Boolean(m[5]),
  region: m[6],
  gender: m[7],
  note: unescape(m[8]),
}))
const declared = (scientistsSwift.match(/^\s*\.init\(/gm) ?? []).length
if (scientists.length !== declared) {
  throw new Error(`read ${scientists.length} of ${declared} scientists: an entry has an unexpected form`)
}
const maxEnrollment = Number(handleSwift.match(/maxExpectedEnrollment = ([\d_]+)/)?.[1].replaceAll('_', ''))

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
const flag = (list, item, reason) => list.push({ item, reason })

// Whole words: the words a handle shows as words.
const wordLists = [
  ['first name', firstNames],
  ['surname', surnames],
  ['skin-tone word', skinTone],
  ['slang', slang],
  ['testing word', testing],
]
const compounds = prefixes.flatMap((p) => suffixes.map((s) => p + s))
for (const [list, words] of [
  ['disposition', dispositions],
  ['science word', scienceWords],
  ['agent', agents],
  ['compound', compounds],
]) {
  for (const word of words) {
    for (const [reason, set] of wordLists) {
      if (set.has(fold(word))) flag(red, word, `${list} is a ${reason}`)
    }
    // A positive disposition may be a trait; it stands only before a name.
    const allowed = list === 'disposition' && positiveTraits.has(fold(word))
    if (traits.has(fold(word)) && !allowed) flag(red, word, `${list} is a trait`)
  }
}
for (const trait of positiveTraits) {
  if (!traits.has(trait)) flag(red, trait, 'positive-traits.txt holds a word that is not in traits.txt')
}

// Compounds: a word can hide across the join.
for (const compound of compounds) {
  for (const sequence of substrings) {
    if (fold(compound).includes(sequence)) flag(red, compound, `contains "${sequence}"`)
  }
}

// Scientists: a two-word name is read as one name ("Tan Yunxian").
const removed = new Set(removedForBalance)
for (const person of scientists) {
  const name = person.name
  const words = name.split(' ')
  for (const [reason, set] of [['skin-tone word', skinTone], ['slang', slang], ['testing word', testing]]) {
    if (set.has(fold(name))) flag(red, name, `scientist is a ${reason}`)
  }
  if (removed.has(name)) flag(red, name, 'was removed for balance; add it back only with a balance review')
  if (words.length === 2 && firstNames.has(fold(words[0]))) {
    flag(amber, name, 'a first name and a surname: can match a classmate')
  } else if (surnames.has(fold(words.at(-1)))) {
    flag(amber, name, 'a common US surname (kept by decision)')
  } else if (words.length === 1 && firstNames.has(fold(name))) {
    flag(amber, name, 'also a first name')
  }
  if (person.isLiving) flag(amber, name, 'alive: check again before each term')
}

// Pairs.
const scientistPairs = dispositions.flatMap((d) => scientists.map((p) => [d, p.name]))
const agentPairs = scienceWords.flatMap((w) => agents.map((a) => [w, a]))
for (const [first, second] of [...scientistPairs, ...agentPairs]) {
  const a = fold(first)
  const n = fold(second)
  const pair = `${first} ${second}`
  if (phraseSet.has(`${a} ${n}`)) {
    flag(red, pair, 'is a brand, title, place or idiom')
    continue
  }
  for (const [pa, pn] of phrases) {
    if ((pa === a && distance(pn, n) === 1) || (pn === n && distance(pa, a) === 1)) {
      flag(amber, pair, `one edit from "${pa} ${pn}"`)
    }
  }
  // "Curious Curie": not harmful, but it reads as a stammer.
  if (a.slice(0, 4) === n.slice(0, 4)) flag(amber, pair, 'both words share a stem')
}

// Balance of the scientist list (docs/student-avatars.md §3).
const share = (test) => scientists.reduce((sum, p) => sum + test(p), 0) / scientists.length
const women = share((p) => (p.gender === 'woman' ? 1 : p.gender === 'both' ? 0.5 : 0))
const europe = share((p) => (p.region === 'europe' ? 1 : 0))
if (women < 0.4) flag(amber, 'Scientist list', `women are ${(women * 100).toFixed(0)}% (target: at least 40%)`)
if (europe > 0.35) flag(amber, 'Scientist list', `Europe is ${(europe * 100).toFixed(0)}% (target: at most 35%)`)

// Capacity.
const schemes = [
  ['Disposition + scientist', scientistPairs.map(([d, n]) => `${d} ${n}`)],
  ['Science word + agent', agentPairs.map(([w, a]) => `${w} ${a}`)],
  ['Compound', compounds],
]
const capacity = schemes.reduce((sum, [, handles]) => sum + handles.length, 0)
const ratio = capacity / maxEnrollment

// A sample of each scheme, in random order.
const sample = (handles, n) => {
  const copy = [...handles]
  for (let i = copy.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1))
    ;[copy[i], copy[j]] = [copy[j], copy[i]]
  }
  return copy.slice(0, n)
}

const counts = (key) => {
  const tally = new Map()
  for (const p of scientists) tally.set(key(p), (tally.get(key(p)) ?? 0) + 1)
  return [...tally].sort((x, y) => y[1] - x[1])
}

const escape = (s) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c])
const flagRows = (flags, level) => flags.map((f) =>
  `<tr class="${level}"><td>${level}</td><td>${escape(f.item)}</td><td>${escape(f.reason)}</td></tr>`).join('\n')
const tallyTable = (title, rows) => `<h3>${escape(title)}</h3><table>${rows
  .map(([k, n]) => `<tr><td>${escape(k)}</td><td>${n}</td></tr>`).join('')}</table>`
const percent = (x) => `${(x * 100).toFixed(0)}%`

process.stdout.write(`<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Handle review</title>
<style>
  body { font: 14px/1.4 system-ui, sans-serif; margin: 2rem; color: #1d2330; background: #fff; }
  table { border-collapse: collapse; margin-bottom: 2rem; }
  td, th { padding: 0.2rem 0.6rem; border-bottom: 1px solid #dde; text-align: left; vertical-align: top; }
  tr.red td:first-child { color: #fff; background: #b3261e; }
  tr.amber td:first-child { background: #f2c14e; }
  .grid { columns: 14rem; column-gap: 1.5rem; }
  .grid div { break-inside: avoid; }
</style></head><body>
<h1>Class handle review</h1>
<p>${schemes.map(([name, handles]) => `${escape(name)}: ${handles.length.toLocaleString('en')}`).join(' · ')}.
Total <strong>${capacity.toLocaleString('en')}</strong> handles.
Largest expected course: ${maxEnrollment.toLocaleString('en')} students, so the pool is
<strong>${ratio.toFixed(1)}×</strong> (at least 4× is required${ratio >= 4 ? '' : ' — <strong>not met</strong>'}).</p>
<p>${scientists.length} scientists: ${percent(women)} women (target: at least 40%),
${percent(europe)} from Europe (target: at most 35%), ${scientists.filter((p) => p.isLiving).length} alive.</p>
<h2>Flags: ${red.length} red, ${amber.length} amber</h2>
${red.length + amber.length === 0 ? '<p>None.</p>' : `<table>
<tr><th>Level</th><th>Word, name or handle</th><th>Reason</th></tr>
${flagRows(red, 'red')}
${flagRows(amber, 'amber')}
</table>`}
<h2>Balance of the scientist list</h2>
${tallyTable('Region', counts((p) => p.region))}
${tallyTable('Gender', counts((p) => p.gender))}
${tallyTable('Field', counts((p) => p.field))}
${schemes.map(([name, handles]) => `<h2>${escape(name)}: a sample in random order</h2>
<div class="grid">${sample(handles, 120).map((h) => `<div>${escape(h)}</div>`).join('')}</div>`).join('\n')}
<h2>Scientists</h2>
<table><tr><th>Name</th><th>Full name</th><th>Field</th><th>Years</th><th>Note</th></tr>
${scientists.map((p) => `<tr><td>${escape(p.name)}</td><td>${escape(p.fullName)}</td><td>${escape(p.field)}</td>` +
  `<td>${escape(p.years)}</td><td>${escape(p.note)}</td></tr>`).join('\n')}
</table>
</body></html>
`)

const capacityFailed = !(ratio >= 4)
console.error(
  `handle review: ${capacity} handles, ${ratio.toFixed(1)}x capacity, ${scientists.length} scientists ` +
    `(${percent(women)} women, ${percent(europe)} Europe), ${red.length} red, ${amber.length} amber`,
)
for (const f of red) console.error(`  red: ${f.item} ${f.reason}`)
process.exit(red.length > 0 || capacityFailed ? 1 : 0)
