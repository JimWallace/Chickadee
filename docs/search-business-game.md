# The search business game: a crawlable web as a course dataset

A design for a three-year HLTH 230 game in which each student runs a search
company from 1996 to 2000. The web students crawl is a **course dataset**: a
JSON file that maps each URL to its HTML. There is a new version of the
dataset for each game year. Chickadee serves nothing new. The rules (the crawl
budget, politeness, search quality) are enforced by the grading scripts.

Status: **design draft, 2026-11-13. Nothing here is built.** It builds on the
search-engine lab and the in-class activity in
[examples/miniweb/](examples/miniweb/README.md), and on the course dataset
library ([datasets-course-library.md](datasets-course-library.md)). §8 records
the maintainer's decisions and the questions still open.

## 1. The game

The game **wraps the search-engine lab** (decided 2026-11-13): it does not
replace the lab or add a second track of work. The lab's six stages are split
across three game years, and each year is one assignment. A student's company
gains each capability by finishing the lab stages that build it, in the order
the history lecture tells them.

| Year | The web (dataset version) | Lab stages that build the capability | What the year grades | Leaderboard metric |
|---|---|---|---|---|
| 1996: the crawler | about 80 pages; `robots.txt` appears | 1 to 3: normalize, extract links, crawl | the stages' tests, and a polite crawl within the budget | hosts reached |
| 1998: PageRank | about 140 pages; the link farm appears | 4 to 6: graph, PageRank, search, then the `score` contest | the stages' tests | search quality (nDCG@5) times coverage |
| 2000: the crash | whole sites return 404 | none new: the 1998 engine, run again | whether the engine stays above a quality bar | search quality on the shrunken web |

Each company carries a **generated name**, a parody of a 1990s search company,
fixed for the whole game (D9).

Two things carry the game's history:

- **The web changes between versions.** New sites appear, and some pages
  break. The link farm arrives in 1998, the year PageRank makes links
  valuable, so the class sees the adversarial response happen. In 2000 whole
  sites vanish, and an engine that leaned on them loses quality.
- **Event cards are content items** posted each year: "Yahoo declines to buy
  your ranking algorithm", "a Waterloo alumnus offers seed funding". They are
  narrative. Nothing reads them for a grade.

## 2. The constraint

**Chickadee does not serve the web** (the maintainer's decision, 2026-11-13).
There is no fetch route, no crawl endpoint and no live crawl traffic during a
class. Everything a student reads is a file delivered through the paths that
exist today. Anything the game enforces, it enforces when the submission is
graded.

## 3. Decisions

Each decision gives the choice, the reason, and the alternative that lost.

**D1. The web is a course dataset.** The mini web is uploaded to the course
library and attached to each year's assignment, as `nhanes_bp.csv` is to
Lab 9. The library already gives it what the game needs:

- versions, one per game year (D3)
- provenance and a licence (synthetic, written by the course)
- a data dictionary and the student Data page
- course clone for the next term
- the shared delivery that does not copy the file per student
  (`docs/dataset-shared-delivery.md`)

The alternative was a Chickadee route that serves pages, meters each student
and logs every fetch. It would have made a live crawl map possible, but it
lost: it serves content from Chickadee, it adds a runtime surface that a whole
class hits at once, and it needs a new table and new routes. D4 enforces the
budget without it.

**D2. A new file shape: a keyed collection.** A dataset today is a CSV. The
profile reads a header, the dictionary describes columns, and the
materializer samples rows. The web is a JSON object that maps a string key to
a string value. This adds a **format** next to the existing **kind**:

- **The format says what the file is:** `csv` (today, the decoded default) or
  `keyed` (a JSON object of string to string).
- **The kind says how a student's slice is chosen:** `rowSample`,
  `stratifiedSample` or `partition`.

The two are orthogonal. Why a new format and not a plain support file:
`miniweb.json` already works as an ordinary support file that every student
gets whole, the way Lab 6 ships `foodlog.csv`. What a plain file lacks is
everything the library adds: versions (the game years), provenance and a
licence, a dictionary, the Data page and course clone. Library `create` takes
a CSV only, so the format is what lets the web into the library.

A keyed file in this design is always delivered
whole (the `shared` mode in `datasets-course-library.md` §4.11). A sampled
web would break links, so the save-time checks refuse a sample size or a
transform on a keyed file. A partition by host would be a later decision
(§8, open question 4).

The profile of a keyed file reports:

- how many entries it has
- its total size
- the hosts its keys name
- how many values are HTML (a value with a `<title>`)

The dictionary describes the key and the value in two entries, in place of
columns. The Data page shows the same.

**This stays inside the #1434 boundary.** #1434 declined a query layer and a
database (`datasets.md`, "Phase 2"). A keyed file is still a file under a
known name, and students read it with `json.load`. Nothing queries it on
their behalf.

**D3. Each game year is a dataset version.** The generator
(`examples/miniweb/generate_miniweb.py`, extended) writes all three years from
one seed. A page keeps its URL and its text from year to year unless the
story changes it. Each year's assignment pins its version through
`DatasetSource`. The Datasets tab already tells an instructor what kind of
change a new version is. That logic counts rows, so it needs a keyed
counterpart: pages added, pages removed, and pages changed.

**D4. The crawl budget is enforced by a metered fetch at grading.** The
grading script imports the student's `crawl(seed, fetch)` and runs it with a
fetch the script owns.

- The metered fetch counts each call. It returns 404 once the year's budget
  is spent.
- Only pages that were returned through the metered fetch count as crawled.
  A page the crawler claims without fetching it scores nothing.
- A fetch of a path that the host's `robots.txt` forbids counts against
  politeness. `robots.txt` is an ordinary key in the dataset, such as
  `https://jhi.example/robots.txt`, and fetching it costs budget, as it did
  for real crawlers.

So a "fixed crawl rate" is a fixed budget per game year. No clock is needed.

**What this does not stop:** a student can read the dataset file directly and
plan the best order of fetches with the whole graph in view. That is planning
with perfect information. It never gives more pages than the budget pays for.
Choosing what to fetch first is the lesson that crawl prioritization teaches
anyway.

Two alternatives lost:

- **A throttle inside the student's `fetch` helper.** The student can edit or
  bypass it.
- **A crawl log replayed by the grader.** It works, but the metered fetch is
  simpler and cannot be forged.

**D5. Each ranked year is a Class activity, graded on the worker.** A year
with a leaderboard is declared `classActivity`, which needs an `activity`
block and runs on the worker (`docs/assignment-types.md`). Worker grading is
this design's choice, not a platform rule: a `bestMetric` assignment may be
browser-graded (`docs/class-activities.md`). Two reasons decide it:

- The hidden query judgments must be grader-only, and the browser refuses
  grader-only files.
- A browser-graded result is posted by the student's own browser, which is
  acceptable for a lab and weak for a ranking (`docs/grading-integrity.md`).

The six-stage lab itself stays a browser-graded Lab.

**D6. A coverage item is a host, not a page, and the coverage rows need a
new gate.** The main web has 17 hosts. Each host becomes one suite entry,
which passes when the student's metered crawl fetched at least one page on
that host. Each entry runs the crawl again; a crawl of the main web takes well
under a second, so 17 crawls per submission is acceptable, and no result is
shared between test processes (each test has its own working directory,
`docs/grading-integrity.md`, phase 2).

**What does not work today.** `class_item_coverage` records the first student
to cover each item, but `recordClassItemCoverage` writes rows only for a
*contribution assignment*: one whose starter declares slot cells
(`declaredSlotCount > 0`, `docs/bug-hunt-code-map.md`). A crawl year is not a
contribution assignment, and making it one (a slot cell per student's
crawler) would be a bend, not a fit. So the first new piece is the gate:
coverage rows for an assignment that opts in, without slot cells.

What follows once rows are written:

- The instructor's item table shows each host's first finder and when. It is
  a staff table; students see no names (`docs/bug-hunt-code-map.md`).
- A class goal on `itemsCovered` ("the class has reached every site") is a
  shape `isSweepEvaluableClassGoal` admits today. A class goal grades on the
  smaller of coverage and breadth (`classFraction`,
  `docs/collaborative-class-assignments.md`), so one student who reaches
  everything does not complete it alone.

Per-page items (116 or more) would mean one suite entry per page, which is too
many test processes per submission. Per-page coverage needs a new item source,
a covered-keys list in the collection. That is a later slice (§7).

**D7. The class map is a new board, because a year has one activity kind.**
An assignment carries one `activity.kind`. The leaderboard a year needs is
`bestMetric`. The projector coverage board belongs to `bugHunt` (aggregation
`coverage`). No kind gives both. The choices:

- **A new kind** whose aggregation is a leaderboard *and* whose board shows
  coverage. A kind is added only together with the code that grades it
  (`docs/class-activities.md`), so this is a real slice.
- **Two assignments per year:** a `bestMetric` year for the ranking and a
  coverage assignment for the map. This doubles the students' submissions, so
  it is the weaker choice.

Either way, the map itself is new:

- **Counts, not only first finders.** The board needs how many students
  reached each host. `class_item_coverage` keeps one row per item.
- **A web layout.** One node per host, one edge per host-to-host link, filled
  by count; unreached hosts stay dark, as code does on the Bug Hunt board. The
  layout is computed once by the generator and stored with the activity, not
  in the student's dataset. The board renders it as server-side SVG, because
  no graph library is vendored.

**D8. The economy lives in the grading scripts, not in Chickadee.** Each year
reports one `metric` for the leaderboard. That year's script computes it as
"users", for example search quality multiplied by the share of the web
covered. Chickadee has no cross-assignment state, so cash carried from year
to year is not modelled. A company's "valuation" is the sum of its three
yearly metrics, shown on a course page or computed by the instructor (§8,
open question 1). The
economy stays three numbers: budget, users and valuation. The learning stays
in the lab code.

**D9. A company's name is generated from the student's handle.** Every
student already has a per-course handle and a bird that the leaderboards show
(`docs/student-avatars.md`). The company name is a pure function of the
handle: a stable hash of it picks one parody name from a fixed list. So:

- the name is the same in every year without being stored;
- it adds no identity: anyone who can compute the name already sees the handle
  beside it, and staff see the real name as they do today;
- nobody types a name, so nothing needs moderation.

The names parody the 1990s search and portal companies, with a 1990s suffix:

| Parody of | Names |
|---|---|
| AltaVista | AltaVisor, BaltaVista |
| Yahoo | Yodelhoo, Yahoot |
| Lycos | Lycrawl |
| Excite | Excitable, Overexcite |
| Infoseek | InfoSneak, InfoPeek |
| HotBot | LukewarmBot |
| Ask Jeeves | Ask Jeremy |
| WebCrawler | WebCrawdad |
| Northern Light | Northern Lite |
| Open Text | Open Texting |
| Google | Gaggle, Googolplex |
| suffixes | .com, Online, Interactive, Networks, Direct, 2000 |

That is 16 bases and 6 suffixes, 96 names, for example "Lycrawl
Interactive" or "Gaggle.com". Two students in a large class can draw the same
name. That is harmless, because the handle tells them apart, and it can be
played as a trademark dispute. Every name is a pun on a company that is long
gone or long renamed, and none is the real name.

Two alternatives lost:

- **A personal one-row dataset of company names**, scoped to the course. It
  would reuse the cohort seed, but a ranked year refuses a personal dataset
  (`datasets-course-library.md` §4.11), and the name has to show on exactly
  those years.
- **Names that students choose.** These would need moderation, and they would
  be a second identity next to the bird.

**Where it shows:** beside the handle on the year leaderboards and on the
class map. This is a small new piece of presentation: a Core function from
handle to name, and one line in the leaderboard view.

## 4. Achievements

| Achievement | Earned when | Signal | State |
|---|---|---|---|
| Archie | a first crawl fetches any page | `testPass` on the 1996 crawl entry | exists |
| Spam Fighter | no farm page in the top five for any flu query | `testPass` on a 1998 entry | exists |
| Survived the Crash | above the quality bar in 2000 | `testPass` on the 2000 entry | exists |
| Bechtolsheim's Cheque | highest metric in 1998 | `record` on `highestMetric` | exists |
| Polite Crawler (one year) | no forbidden fetch in that year | `testPass` on the year's politeness entry | exists |
| The Whole Web (class goal) | the class together reached every host | `itemsCovered` class goal | exists, once D6's gate lets rows be written |
| Full Index | one student reached every host in a year | none: `itemsCovered` is a class-level signal | **new** |
| Polite Crawler (all term) | no forbidden fetch in any year | none: cross-assignment signals read grades, not one entry | **new** |
| First Finder | first in the class to reach a host | none: first finders are a staff table column | **new**, and needs a decision about naming students (§8, open question 5) |

## 5. Grades stay out of the game

Credit comes from the lab stages and a short reflection each year. A year's
suite pays a point for a crawl that runs and is polite. The leaderboard metric
is ranking only, and nothing reads it for a grade (`docs/class-activities.md`,
"The `metric` footer field"). A student who builds a correct crawler and
search engine earns full marks whether their company wins or not.

## 6. What exists and what is new

| Piece | State |
|---|---|
| Course dataset library: versions, provenance, Data page, clone | exists |
| Shared delivery of a whole file | exists |
| The keyed format (D2): spec field, profile, dictionary, save-time refusals, Data page rendering, version diff | **new** |
| Generator for three yearly webs, with `robots.txt` and the 2000 crash | **new**, extends `generate_miniweb.py` |
| Metered fetch and politeness check (D4) | **new**, in the grading scripts; no Swift |
| Leaderboard per year, `bestMetric`, windows | exists |
| Coverage rows for an assignment without slot cells (D6) | **new**: a gate change |
| Class goal on `itemsCovered`, staff first-finder table | exists, once rows are written |
| A kind with a leaderboard and a coverage board (D7) | **new** |
| The web map with counts and a layout (D7) | **new** |
| Three achievements in §4 | **new** |
| Valuation across years (D8) | **new** or by hand (§8, open question 1) |
| Company names from the handle (D9) | **new**: a Core function and one line in the leaderboard view |
| Event cards | exists (content items) |

## 7. Build order

1. **The keyed format in Core.** The `format` field on `DatasetSpec`, written
   only when it is not `csv`, so stored manifests keep their bytes, as with
   `source` and `scope`. Also the keyed profile, the refusals for samples and
   transforms, and tests.
2. **Library and surfaces.** Upload, versions, the keyed version diff, and the
   Data page and dictionary for two entries. MCP `create_dataset` and
   `add_dataset_version` accept a keyed file.
3. **The three yearly webs.** Extend the generator. `check_story.py` gains one
   check per year, such as "the farm appears in 1998", "a crawler that
   ignores `robots.txt` loses politeness" and "the 1998 reference engine falls
   below the bar in 2000 unless it handles the vanished sites".
4. **The year scripts.** Metered fetch, politeness, coverage entries per host,
   and the yearly metric. Validate each year against a reference company.
5. **Coverage without slot cells.** The D6 gate, so a year's host entries
   write `class_item_coverage` rows and the `itemsCovered` class goal works.
6. **The map.** The D7 kind (or the two-assignment form), coverage counts
   and the SVG layout. This is the only slice with UI.
7. **Later:** per-page coverage items, the three new achievements in §4,
   a partition by host (§8, open question 4), valuation across years, and company names
   (D9) if the leaderboard line is not in an earlier slice.

Slices 1 to 4 make the game playable on a yearly leaderboard, with no map.
Slices 5 and 6 add the class's shared map.

## 8. Decisions and open questions

Decided by the maintainer on 2026-11-13:

1. **Three game years**: 1996 (the crawler), 1998 (PageRank) and 2000 (the
   crash). Not six.
2. **The game wraps the lab.** The lab's stages build each year's capability
   (§1). The in-class `score` contest becomes the end of 1998.
3. **Company names are generated**, parodies of real 1990s companies, as a
   small joke (D9).

Still open:

1. **Valuation across years:** a course page, or the instructor adds up the
   three leaderboards by hand?
2. **Budget size:** a budget below the web's size makes the crawl order
   matter. The proposal is about half the web each year, tuned by the
   generator's checks.
3. **D7's two forms:** a new kind with a leaderboard and a coverage board, or
   two assignments per year.
4. **A partition by host ("webmasters"):** each student is dealt a few sites
   to maintain, and gains points when other companies reach them. A ranked
   year cannot carry it: an activity that compares students accepts only a
   `shared` dataset (`datasets-course-library.md` §4.11). Deferred.
5. **First finders:** may a student see which company reached a site first?
   Company names make this lighter than showing a handle, but it is still a
   name next to an achievement.

## 9. Non-goals

- Serving pages from Chickadee, or any live crawl traffic (§2).
- A query layer over the dataset (#1434).
- Real web content. Every host is fictional, under `.example`.
- Grades that depend on winning (§5).
