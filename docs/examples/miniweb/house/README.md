# House companies: the professor's historical engines

The two house companies of the search business game
([docs/search-business-game.md](../../../search-business-game.md), D10), and
a prototype of the three game years to check them against.

| File | What it is |
|---|---|
| `lycrawl.ipynb` | Lycrawl (LYCR), the 1996 approach. Submitted as the house company in 1996, 1998 and 2000. |
| `googolplex.ipynb` | Googolplex (GOOG), the 1998 approach. Submitted from 1998. |
| `build_house.py` | Writes both notebooks from one source, with the debrief prose. |
| `years.py` | The 1996, 1998 and 2000 webs, derived from `../miniweb.json`. A stand-in for the generator slice (design doc §7, slice 3). |
| `market.py` | Plays both house companies and a typical class company through the three years with a metered fetch, prints the Market, and checks the story. |

```sh
cd docs/examples/miniweb/house
python3 build_house.py
python3 market.py
```

## The contract

Every company in the game, the class's and the house's, defines two functions:

- `crawl(seed, fetch)`: `fetch(url)` returns `(status, text)`, and `429` once
  the year's budget is spent. Only pages that come back through `fetch` count,
  so a crawler cannot claim pages it did not pay for.
- `build_engine(pages)`: takes the crawled pages (URL to HTML) and returns
  `search(query, k=5)`.

Fetching a `robots.txt` costs no budget, so obeying it is never a disadvantage.
A fetch that a host's `robots.txt` forbids costs 5 points.

## The two engines

| | Lycrawl (LYCR) | Googolplex (GOOG) |
|---|---|---|
| Crawl order | Breadth-first, in the order links are found | Highest estimated PageRank first, re-estimated every five fetches (Cho, Garcia-Molina and Page, 1998) |
| Politeness | Obeys `robots.txt` | Obeys `robots.txt`; stops visiting a site whose first page returns 404 |
| Ranking | Word count: the page with the most occurrences of the query's words | Title words, all words present, capped word share, and PageRank over everything it knows |
| Spam defence | None | A keyword-stuffing penalty (over a fifth query words) and a link-farm penalty (many links in, little rank per link) |

## What happens (from `market.py`)

| | 1996 | 1998 | 2000 | The Market |
|---|---|---|---|---|
| Lycrawl (LYCR) | **47.9** | 58.0 | 59.1, bust | $25.9K |
| Googolplex (GOOG) | not founded | **69.2** | **64.8** | **$2.1M** |
| A typical class company | 42.9 | 33.2 | 36.6, bust | $1.5K |

1996 scores the share of the web indexed. 1998 and 2000 score search quality
(nDCG@5 times 100) on the activity's judged queries, kept to pages that exist
that year. The 2000 quality bar is 62.

`market.py` fails unless all of these hold:

- **LYCR wins 1996.** Its margin over the typical class company is exactly one
  forbidden fetch: the lab's crawler knows nothing of `robots.txt`. In 1996,
  what separated a big crawler from a small one was being allowed to crawl.
- **In 1998 the link farm is in LYCR's top five for flu and not in GOOG's,**
  and GOOG beats LYCR. From 1998 the directory lists the farm under "Natural
  Health" (spammers submitted to directories), so a breadth-first crawler
  meets the farm early and a word count ranks it first.
- **In 2000 LYCR busts and GOOG survives**, each by at least two points.
- **GOOG leads the Market** at the end.

## What building them taught (for the debrief)

These came out of tuning the engines. Each one is a historical point:

- **Ordering a crawl by link count fails on a link farm.** The first
  Googolplex fetched the most-linked page next, and capped each site at eight
  pages. Each farm page links to every other, so every farm page fetched added
  a link to all the rest. That version spent 14 of its 60 fetches in 1998
  inside the farm, about a quarter. It is not kept, so this number is a
  record, not something `market.py` prints. Ordering by PageRank
  fixes it, because a farm page shares its small rank among all its links.
  This is the comparison Cho, Garcia-Molina and Page made in 1998.
- **A crawler that resists a farm can still be fooled by the part it fetched.**
  With PageRank ordering, Googolplex fetches only two farm pages in 1998 (the
  `farm pages` count that `market.py` prints; in 2000, with three sites gone,
  it reaches eight). Ranked on
  those two alone, they linked only to each other and kept all their rank: a
  rank sink. Ranking over every page the crawler knows of, fetched or not,
  lets that rank flow out. A keyword-stuffing penalty catches the rest.
- **The crash is about quality, not about dead links.** Googolplex's dead-site
  rule saves a few fetches in 2000, but the scores barely move. What sinks
  Lycrawl is that a word count was never good search. In 1998 the farm hid
  that, and in 2000 the bar exposes it.

## What is a stand-in

- **The year webs** are derived from the main web by `years.py`, not written
  by the generator. Slice 3 of the design replaces them.
- **The judged queries** are the in-class activity's 18 queries. A game year
  would have its own.
- **The typical class company** is the lab's reference solution, with `fetch`
  passed in. A real class will spread on both sides of it.
- **LYCR's 1996 win is narrow.** Both crawlers index 34 pages, and LYCR wins
  only because the lab's crawler makes one forbidden fetch. A change to the
  lab's crawler or to one `Disallow` rule can flip it. `market.py` checks it,
  so a change that flips it fails loudly.
- **The scores and the bar** are from this prototype. Retune with `market.py`
  when the real year webs exist.
