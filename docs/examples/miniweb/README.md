# HLTH 230 sketch: how the web works, and a search engine of your own

A design sketch and its dataset for a two-part HLTH 230 unit. Part 1 is a
lecture on how the web works and how web search came about, with stops at
Waterloo. Part 2 is a lab in which students build a small search engine,
including PageRank, over a fictional web that ships as a dataset.

Status: **the dataset, the reference solution and a check of the lesson
exist.** The lecture, the starter notebook, the tests and the placement in the
course are not written yet. Nothing here needs a Swift change.

| File | What it is |
|---|---|
| `generate_miniweb.py` | Writes both webs. Stdlib only, deterministic. |
| `miniweb.json` | The web students crawl: 116 pages, 992 links, a JSON object mapping URL to HTML. |
| `miniweb_small.json` | An 11-page web that the graded tests run against, so answers hard-coded from the main web fail. |
| `miniweb.py` | The helper students import: `fetch(url)` returns `(200, html)` or `(404, "")`. |
| `reference_solution.py` | One function per lab stage. Stdlib only. |
| `check_story.py` | Runs the reference solution on both webs, prints the lecture's tables, and fails if a claim stops holding. |

Regenerate and check:

```sh
cd docs/examples/miniweb
python3 generate_miniweb.py
python3 check_story.py
```

## Why a fictional web

The browser kernel cannot reach the internet (`connect-src 'self'`,
`docs/datasets.md`), so a real crawl is not possible. A fictional web is also
better teaching material. Every trap is placed on purpose, the answers are
known, and the link farm lesson is guaranteed to show up.

Every host ends in `.example`, a top-level domain reserved for documentation
(RFC 2606), so no URL names a real site. The hospital, health unit, clinics,
pharmacy, journal and blogs are invented. The history pages describe real
events (see "Sources" below).

## What is in the main web

| Site | Pages | Its job in the lesson |
|---|---|---|
| `directory.example` | 1 | The seed: a 1990s-style hand-built directory, which sets up the "directories do not scale" point |
| `publichealth.example` | 19 | The reputable hub, with topic pages that link to each other |
| `maplevalleyhospital.example` | 17 | Directories (`/departments/...`) so `..` links mean something; `find-a-doctor?dept=...` pages, where the query string names a different page |
| `jhi.example` (a journal) | 21 | Twenty articles that cite earlier articles: a citation network inside the web |
| Four clinics, a pharmacy, three blogs, a library | 21 | Ordinary pages that link to the hubs |
| `searchhistory.example` | 11 | The lecture's history as pages that students can search |
| The link farm (three domains) | 26 | Every page links to every other farm page, and no link leaves the farm. One blog commenter links into it. |

### The traps (stage 1 and stage 3)

Every link to a page in the web is written in one of several equivalent ways,
and the generator asserts that each one normalizes to its target. In the main
web, 992 links break down as follows:

| Spelling | Count | Example |
|---|---|---|
| Absolute | 230 | `https://publichealth.example/topics/flu` |
| With a fragment | 192 | `...topics/flu#details` |
| Mixed-case scheme or host | 175 | `HTTPS://PuBlIcHeAlTh.example/topics/flu` |
| Trailing slash | 149 | `.../topics/flu/` |
| Root-relative | 141 | `/topics/flu` |
| Relative | 102 | `..`, `../find-a-doctor?dept=cardiology` |
| Not http | 3 | `mailto:`, `tel:`, `javascript:` |

There are also five links that return 404 (two broken internal links, a missing
PDF, and two real external sites), cycles everywhere, and one page with no links
out (the printable flu fact sheet), so PageRank's dangling-page rule matters.

The canonical form, which students' `normalize()` must produce, is stated in the
generator's docstring: resolve with `urljoin`, drop the fragment, lower-case the
scheme and host, remove a trailing `/` unless the path is `/`, keep the query.

## What the lecture can show (from `check_story.py`)

**1. Counting links is easy to game.** The ten pages with the most inbound
links are all farm pages (in-degree 25 to 26). A search for `flu` ranked by
in-degree returns five farm pages.

**2. PageRank mostly resists it.** No farm page is in PageRank's top five. The
top page is the hospital's home page, then the journal, the history site and
public health. A search for `flu` ranked by PageRank returns no farm page in its
top five.

**3. But not completely, and damping is why.** The farm is a *rank sink*: rank
flows in through one blog comment and never leaves. Its 26 pages are 22% of the
web but hold 29% of all PageRank at damping 0.85, 24% at 0.5, and 41% at 0.95.
The random jump is what drains the trap. The small test web shows the extreme
case: three farm pages reached by one sponsored link take the top three places.

**4. Rank is not relevance.** For `flu`, PageRank puts the hospital's
visiting-hours page ("visitors with flu symptoms should stay home") above the
public health flu page, because the visiting page is better linked. That
motivates combining a text score with PageRank, which is the optional capstone.

## The unit

### Part 1: under the hood (one lecture, an ungraded content item)

A timeline, with the mechanics introduced at the moment in history they
appeared:

1. **Indexing text.** The New Oxford English Dictionary project at Waterloo
   (1980s). Gonnet and Tompa, full-text search, Open Text.
2. **The early internet.** Archie (McGill, 1990). What a URL is: scheme, host,
   path, query, fragment. Students take URLs apart with `urllib.parse`.
3. **The web.** HTTP requests, status codes, HTML, `<a href>`, relative and
   absolute links. Students browse the mini web by hand with `miniweb.fetch`.
4. **Directories and the first engines.** Yahoo as a directory. The Open Text
   Index (April 1995, Tim Bray's crawler) briefly powering Yahoo's search.
5. **Link analysis.** Garfield's Science Citation Index (1964) and the impact
   factor, then BackRub and PageRank at Stanford. The random surfer.
6. **Money and Waterloo.** The portals declined PageRank. Bechtolsheim's
   cheque (August 1998), Cheriton among the first investors, and the 2005 gift
   that named the David R. Cheriton School of Computer Science.
7. **After PageRank.** Link farms, spam fighting, PageRank as one signal
   among many. The patent (US 6,285,999) expired on January 9, 2018.

### Part 2: the lab (Python, browser-graded)

Six stages, one public test each, so a student stuck on one stage still passes
the others. The starter notebook supplies the scaffolding; students write the
marked core of each function.

| Stage | Function | Students learn | Test (on `miniweb_small.json`) |
|---|---|---|---|
| 1 | `normalize(url)` | URL anatomy, `urljoin` | a table of hrefs and bases against canonical answers |
| 2 | `extract_links(base, html)` | HTML structure, `html.parser` | the links of three pages, in order; non-http schemes dropped |
| 3 | `crawl(seed)` | breadth-first search, a visited set, 404s | all 11 pages reached, nothing outside the web |
| 4 | `build_graph(pages)` | a graph as a dict of sets | the exact edge set |
| 5 | `pagerank(graph)` | power iteration, damping, dangling pages | ranks within `1e-6`, summing to 1 |
| 6 | `search(query, ...)` | an inverted index, sorting by score | the top results for two queries |

The reference solution is stdlib only (`html.parser`, `urllib.parse`,
`collections.deque`), so it runs in the browser kernel, which has no
BeautifulSoup or `networkx` (`Tools/jupyterlite/environment-python.yml`).
PageRank in plain dictionaries keeps the arithmetic visible. A numpy matrix
version is a natural extension.

Questions for the written part: why the in-degree and PageRank tables differ;
what the damping factor does to the farm, and why; and why the visiting-hours
page ranks above the flu page.

### Optional capstone: a `bestMetric` activity

A leaderboard for the best search engine (`docs/class-activities.md`). Students
combine a text score with PageRank however they like; the metric is a ranking
quality score (nDCG) on queries judged in advance. If it is browser-graded,
students can read the judgments (`docs/grading-integrity.md`). Grade it on the
worker if that matters.

## When in the course

HLTH 230-W27 has Labs 0 to 9, Assignments 0 to 4 and five class activities
(`docs/assignment-types.md`). The lab needs functions, loops, strings,
dictionaries and sets. It needs no pandas.

| Option | Lecture | Lab | For | Against |
|---|---|---|---|---|
| A. Capstone | Last weeks of term | Directly after | Uses everything students know; the history makes a good closing lecture | Competes with exam review and the final assignment |
| B. Mid-term | Right after the lab that introduces dictionaries and sets | The next lab slot | Practises dictionaries on something other than a table; a break from data frames | Students have less programming behind them |
| C. Split | Early, with "where data comes from" | Later, as in A or B | The "how the web works" material helps from the start | Two months between the history and the algorithm |

The course schedule is not in this repository, so the choice is the
maintainer's.

## Sources for the history pages

Checked on 2026-11-11:

- PageRank and the patent dates: [Wikipedia, "PageRank"](https://en.wikipedia.org/wiki/PageRank).
- Open Text, the OED project and the Open Text Index:
  [Wikipedia, "OpenText"](https://en.wikipedia.org/wiki/OpenText),
  [Tim Bray, "On Search"](https://www.tbray.org/ongoing/When/200x/2003/06/15/OnSearch).
- Cheriton's degrees and the 2005 gift:
  [Waterloo alumni profile](https://uwaterloo.ca/alumni/node/32),
  [Daily Bulletin, 2005-11-21](https://bulletin.uwaterloo.ca/2005/nov/21mo.html).
- BackRub, the portals that declined, and Bechtolsheim's cheque:
  [deepsystemstuff.com, 2026-11-11](https://deepsystemstuff.com/patent-for-pagerank-algorithm-who-made-google-search-what-it-is-today-has-expired-what-does-it-means-for-open-source-developers/).

**Not yet checked against a primary source. Check these before the lecture:**
Archie (McGill, 1990); the Science Citation Index (1964); Cheriton's own
investment and the meeting at his house. The history pages state only that
Cheriton was "one of Google's earliest investors" and leave out the meeting
story.
