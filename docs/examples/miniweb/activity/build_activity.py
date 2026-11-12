"""Build the in-class activity's files, then check that the contest is a fair one.

Writes, next to this script:

- miniweb_ranks.json  PageRank and in-degree of every page, so searchkit.py
                      needs no crawler or PageRank code (it would give away the lab)
- activity.ipynb      the notebook students open

Then checks, and exits non-zero if a check fails:

- the simple strategies rank in the order the lecture predicts
  (PageRank alone < word count alone < the starter < the instructor's entry)
- the instructor's entry scores about the same on the hidden queries as on
  the practice queries, so tuning on the practice set is not a trap
- the grading test, run on the starter notebook, prints a footer with a metric

Run ../generate_miniweb.py first.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))

import build_lab  # noqa: E402  (the notebook writer)
import miniweb  # noqa: E402
import reference_solution as ref  # noqa: E402

CELLS: list[tuple[str, str]] = [
    ("md", """# Class Activity: The Best Search Engine

A search engine can find every page that matches a query. The hard part of search is the order. A person reads the first five results and rarely looks further, so a search engine is judged on what it puts at the top.

In this activity you write one function, `score`, that gives a page a number for how well it answers a query. The search engine ranks the matching pages by that number. Everything else (the crawl, the index, PageRank) is done for you in `searchkit`.

Each submission is graded on twelve **hidden** queries, which are not the practice queries below. The leaderboard ranks the class by the result, highest first. Submit as often as you like during the session; the leaderboard keeps your best."""),
    ("code", """import json
import searchkit

web = searchkit.Web()
practice = json.load(open("practice_judgments.json"))
print(len(practice), "practice queries:", ", ".join(practice))"""),
    ("md", """## What `score` receives

For each query, the search engine finds every page that contains at least one of the query's words. It calls `score(features)` once for each of those pages. `features` is a dictionary:

| Key | Meaning |
|---|---|
| `pagerank` | The page's PageRank, from the lab. All pages together sum to 1. |
| `in_degree` | How many pages link to this page. |
| `title_matches` | How many of the query's words appear in the page's title. |
| `body_matches` | How many times the query's words appear in the page's text, counting repeats. |
| `all_words` | `True` if every word of the query appears somewhere on the page. |
| `query_words` | How many different words the query has. |
| `page_words` | How many words the page has. |

The features are numbers only. `score` does not see the URL or the query, so it has to judge a page by its features, as a search engine judges a page it has never seen.

Run the cell below to see the features of three pages for the query `flu vaccine`."""),
    ("code", """for url in ["https://publichealth.example/topics/flu",
            "https://jhi.example/",
            "https://miraclecure.example/"]:
    print(web.features(url, "flu vaccine"))"""),
    ("md", """## How a ranking is measured

Each practice query comes with **judgments**: for each page, 2 if it answers the query, 1 if it is related, and 0 for every page not listed. The measure is **nDCG@5** (normalized discounted cumulative gain over the top five). It rewards relevant pages near the top: a page at position 1 counts fully, and each position below counts a little less. A ranking that puts the best possible five pages in the best possible order scores 1. Missing a relevant page, or placing it low, costs points.

The cell below scores two simple strategies. The first ranks by PageRank alone. The second ranks by how often the query's words appear."""),
    ("code", """def by_pagerank(f):
    return f["pagerank"]


def by_word_count(f):
    return f["body_matches"]


for name, strategy in [("PageRank alone", by_pagerank), ("word count alone", by_word_count)]:
    mean, per_query = searchkit.evaluate(web, strategy, practice)
    print(f"{name}: {100 * mean:.1f}")
    for query, value in per_query.items():
        print(f"    {query:20s} {100 * value:5.1f}")"""),
    ("md", """Look at the top five for one query under each strategy. Neither strategy is good, and each fails in a different way."""),
    ("code", """for url in web.search("flu vaccine", by_pagerank):
    print("PageRank:  ", url)
print()
for url in web.search("flu vaccine", by_word_count):
    print("word count:", url)"""),
    ("md", """## Your `score` function

Edit `score` below. It must return a number, and it may use any of the features. Combine them however you like: add them, weight them, compare them, cap them.

Some questions to work from:

- Which pages in the top five above should not be there? What do their features have in common, and what do the correct pages have that they lack?
- The lecture showed that a link farm has many links pointing in, but each link carries little PageRank. Which two features together measure that?
- A page that repeats a word many times is not necessarily about that word. How could `page_words` help?

`score` is graded on queries you have not seen. A rule that fixes one practice query but makes no sense in general will not help on the leaderboard."""),
    ("code", """def score(f):
    return 2 * f["title_matches"] + f["all_words"]"""),
    ("code", """mean, per_query = searchkit.evaluate(web, score, practice)
print(f"Your score on the practice queries: {100 * mean:.1f}")
for query, value in per_query.items():
    print(f"    {query:20s} {100 * value:5.1f}")"""),
    ("code", """query = "flu vaccine"
for url in web.search(query, score):
    print(url)"""),
    ("md", """## Submitting

Submit the notebook. The grader runs your `score` on the twelve hidden queries and reports your nDCG@5, from 0 to 100, which places you on the leaderboard. Your best submission counts.

`score` must work from `features` alone. A function that reads files or remembers earlier calls is not a search engine, and it is removed from the leaderboard."""),
]


def instructor_score(f):
    """The instructor's entry: text match, capped density, and a link farm penalty."""
    rank_per_link = f["pagerank"] * 1000 / max(f["in_degree"], 1)
    density = min(10 * f["body_matches"] / f["page_words"], 1.5) if f["page_words"] else 0
    return 2 * f["title_matches"] + f["all_words"] + density - 5 * (rank_per_link < 0.6)


def starter_score(f):
    return 2 * f["title_matches"] + f["all_words"]


def write_ranks() -> None:
    miniweb.load(str(HERE.parent / "miniweb.json"))
    pages = ref.crawl("https://directory.example/")
    graph = ref.build_graph(pages)
    ranks = {"pagerank": ref.pagerank(graph), "in_degree": ref.in_degree(graph)}
    (HERE / "miniweb_ranks.json").write_text(json.dumps(ranks, indent=1, sort_keys=True) + "\n",
                                             encoding="utf-8")
    print(f"miniweb_ranks.json: {len(pages)} pages")


def write_notebook() -> None:
    (HERE / "activity.ipynb").write_text(json.dumps(build_lab.notebook(CELLS), indent=1) + "\n",
                                         encoding="utf-8")
    print(f"activity.ipynb: {len(CELLS)} cells")


def check() -> list[str]:
    failures: list[str] = []
    with tempfile.TemporaryDirectory() as tmp:
        stage = Path(tmp)
        for name in ["searchkit.py", "miniweb_ranks.json", "practice_judgments.json",
                     "hidden_judgments.json", "publictest_search_quality.py"]:
            shutil.copy(HERE / name, stage)
        shutil.copy(HERE.parent / "miniweb.json", stage)
        import searchkit

        web = searchkit.Web(stage)
        practice = json.loads((HERE / "practice_judgments.json").read_text(encoding="utf-8"))
        hidden = json.loads((HERE / "hidden_judgments.json").read_text(encoding="utf-8"))
        strategies = [
            ("PageRank alone", lambda f: f["pagerank"]),
            ("word count alone", lambda f: f["body_matches"]),
            ("the starter", starter_score),
            ("the instructor's entry", instructor_score),
        ]
        results = []
        print("\nStrategy                  practice  hidden")
        for name, strategy in strategies:
            p = 100 * searchkit.evaluate(web, strategy, practice)[0]
            h = 100 * searchkit.evaluate(web, strategy, hidden)[0]
            results.append((name, p, h))
            print(f"  {name:24s} {p:6.1f}  {h:6.1f}")
        hidden_scores = [h for _, _, h in results]
        if hidden_scores != sorted(hidden_scores):
            failures.append("the strategies do not rank in the expected order on the hidden queries")
        _, p, h = results[-1]
        if abs(p - h) > 3:
            failures.append(f"the instructor's entry scores {p:.1f} on practice but {h:.1f} hidden")

        # The grading test, run on the starter's score function the way the runner would.
        (stage / "solution.py").write_text(
            "def score(f):\n    return 2 * f[\"title_matches\"] + f[\"all_words\"]\n", encoding="utf-8")
        (stage / ".chickadee_student_module").write_text("solution.py", encoding="utf-8")
        shutil.copy(HERE.parents[3] / "Tools" / "runner-support" / "test_runtime.py", stage)
        run = subprocess.run([sys.executable, "publictest_search_quality.py"], cwd=stage,
                             capture_output=True, text=True, timeout=60)
        footer = json.loads([line for line in run.stdout.splitlines() if line.strip()][-1])
        print(f"\nGrading test on the starter: exit {run.returncode}, footer {footer}")
        if run.returncode != 0 or abs(footer.get("metric", -1) - round(results[2][2], 1)) > 0.05:
            failures.append("the grading test does not report the starter's hidden score")
    return failures


if __name__ == "__main__":
    write_ranks()
    write_notebook()
    problems = check()
    if problems:
        print("\nFAILED:\n  " + "\n  ".join(problems))
        sys.exit(1)
    print("\nAll checks hold.")
