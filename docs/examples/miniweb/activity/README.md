# Class activity: the best search engine

A 50-minute in-class contest that follows the search-engine lab
(`../README.md`). Each student writes one function, `score(features)`, that
gives a page a number for how well it answers a query. The grader ranks the
matching pages by that number for twelve hidden health queries and reports the
mean nDCG@5 (0 to 100) as the leaderboard metric. It is a `bestMetric` activity
(`docs/class-activities.md`), graded on the worker so the hidden judgments stay
on the server.

The activity does not need a finished lab. `searchkit.py` supplies the crawl,
the index and the ranks, so a student who did not complete Stage 5 can still
play. It reads PageRank from a precomputed file and contains no crawler or
PageRank code, so it does not give the lab away.

| File | Role | Visible to students |
|---|---|---|
| `activity.ipynb` | The notebook students open and submit | yes |
| `searchkit.py` | Features, ranking, nDCG@5, `evaluate` | yes (support file) |
| `../miniweb.json` | The main mini web | yes (support file) |
| `miniweb_ranks.json` | PageRank and in-degree of every page | yes (support file) |
| `practice_judgments.json` | 6 queries, 27 judgments, for tuning | yes (support file) |
| `hidden_judgments.json` | 12 queries, 39 judgments, for grading | **no: grader-only** |
| `publictest_search_quality.py` | The one test: prints `score: 1` and `metric` | yes |
| `build_activity.py` | Writes the ranks and the notebook, then runs the checks below | (not uploaded) |

Rebuild and check:

```sh
cd docs/examples/miniweb/activity
python3 build_activity.py
```

## The contest is fair, and the lesson shows up

`build_activity.py` fails unless these hold. Scores are nDCG@5 times 100.

| Strategy | Practice | Hidden |
|---|---|---|
| PageRank alone | 36.5 | 35.0 |
| Word count alone | 67.2 | 54.9 |
| The starter (`2 * title_matches + all_words`) | 65.4 | 64.4 |
| The instructor's entry | 83.5 | 83.0 |

- **Each simple strategy fails a different way.** PageRank alone puts the
  journal's home page (which lists every article title) and the hospital's
  visiting-hours page at the top of almost every query. Word count alone puts
  the link farm at the top of anything about flu: its pages repeat "flu cure"
  more than 60 times each.
- **The instructor's entry uses the lecture's lesson.** A farm page has many
  links in but little PageRank per link (about 0.5 per thousand, against 1.7
  or more for real pages). Penalizing that, and capping how much word
  repetition can earn, reaches 83. The entry is in `build_activity.py`
  (`instructor_score`). Do not hand it out before the debrief.
- **Practice predicts hidden.** The instructor's entry scores within one point
  on both sets (the check fails beyond three), so tuning on the practice queries is a reasonable strategy and
  not a trap. A student who writes rules for single practice queries will see
  their hidden score fall, which is the debrief's point about generalization.
- **The ceiling is not reached.** `flu cure` stays hard for every strategy
  tried: the honest answer, the public health flu page, does not contain the
  word "cure". Leave it in. It is a good debrief question.

## Session plan (50 minutes)

| Minutes | What happens |
|---|---|
| 0 to 10 | Recap. Show the in-degree and PageRank tables from `../check_story.py`, and the damping sweep. |
| 10 to 15 | Open the notebook. Walk through the features and run the two example strategies. Explain nDCG@5 with one query. |
| 15 to 40 | The window is open. The leaderboard is on the projector. Students edit `score`, check it on the practice queries, and submit. |
| 40 to 50 | Debrief, below. |

Debrief questions:

1. What did the top entries do? Ask two or three students to describe their
   rule in one sentence.
2. Whose practice score was much higher than their hidden score, and why?
   (Rules written for one practice query.)
3. Why is `flu cure` still wrong at the top? What would a search engine need
   to know that these features do not capture? (That "influenza" means "flu";
   that a page can answer a question without repeating its words.)
4. Real engines combine hundreds of features, and the weights are learned
   from judged queries rather than written by hand. Connect this to the model
   fitting in Lab 9: the judgments are the training labels.

## Setting it up in Chickadee

1. Create the assignment with type **Class activity**, language **Python**,
   and grading mode **worker**. Worker grading is required: on browser grading
   every support file reaches the student's browser, and grader-only files are
   refused (`docs/grading-integrity.md`).
2. Upload `activity.ipynb` as the starter. Upload `searchkit.py`,
   `miniweb.json`, `miniweb_ranks.json`, `practice_judgments.json` and
   `hidden_judgments.json` as support files, and mark `hidden_judgments.json`
   grader-only. Add `publictest_search_quality.py` as the one test, worth one
   point.
3. Set the activity: the edit page's "Class activity" select, or MCP
   `set_activity` with `kind: "bestMetric"`. This seeds the `highestMetric`
   record.
4. Set the window to the lecture's contest period (`opensAt` and `closesAt`,
   ISO-8601). Submissions outside it are refused; staff are never gated, so a
   demonstration entry before class works.
5. Turn the leaderboard visible when the window opens, so the projector shows
   it live (`leaderboardVisibility: "visible"`).

Credit is a point for any submission that runs. The leaderboard ranks on the
metric and nothing reads the metric for a grade. A class activity keeps its
points in Chickadee (`docs/assignment-types.md`).

## What the grader does not stop

- **The hidden judgments are readable from the submission's own process.** On
  the worker, a support file is readable by every test, and the submission is
  imported into the test's process (`docs/grading-integrity.md`, phase 2). A
  `score` that opens `hidden_judgments.json` could cheat. The notebook says
  that a function which reads files is removed from the leaderboard, and staff
  can read every submission. Phase 3 (#2242) closes this.
- **Repeated submissions probe the hidden set.** Each submission reports one
  number for all twelve queries together. `score` receives numbers only, never
  the URL or the query, so it cannot echo a hidden query into an error, a
  return value or a print (the test discards its output as well). Probing one number across twelve queries in 25 minutes is not a
  practical attack.
- **Ties keep the earlier submission.** The metric is rounded to one decimal,
  so two students with the same rule tie, and the one who submitted first
  ranks higher (`docs/class-activities.md`, "The leaderboard").

## Validation

On 2026-11-12, `build_activity.py` ran the grading test on the starter's
`score`. It exited 0 with the footer
`{"score": 1, "metric": 64.4, "shortResult": "nDCG@5 of 64.4 on 12 hidden queries"}`,
which matches the starter's hidden score above. A `score` that returns text
fails with "score() must return a number", and one that raises an error is
reported as an error. `score` never receives a page or a query, so neither
message can name one. The run used a
staged directory with `test_runtime.py`, not the worker, so a validation run
on the server is the real check.
