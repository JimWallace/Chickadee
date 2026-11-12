"""The search engine for the in-class activity, minus the one part students write.

Students write score(features): one number for how well a page answers a
query. Everything else is here: the pages, their PageRank and link counts,
the features of a page for a query, the ranking, and the nDCG@5 measure.

PageRank and in-degree are read from miniweb_ranks.json, precomputed, so this
file contains no crawler and no PageRank code. It does not give away the lab.
"""

import json
import math
import re
from html.parser import HTMLParser
from pathlib import Path

K = 5


class _TextParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.in_title = False
        self.title = []
        self.text = []

    def handle_starttag(self, tag, attrs):
        if tag == "title":
            self.in_title = True

    def handle_endtag(self, tag):
        if tag == "title":
            self.in_title = False

    def handle_data(self, data):
        (self.title if self.in_title else self.text).append(data)


def tokenize(text):
    return re.findall(r"[a-z0-9]+", text.lower())


class Web:
    """The mini web, loaded once: each page's title words, body words and ranks."""

    def __init__(self, folder="."):
        folder = Path(folder)
        pages = json.loads((folder / "miniweb.json").read_text(encoding="utf-8"))
        ranks = json.loads((folder / "miniweb_ranks.json").read_text(encoding="utf-8"))
        self.pagerank = ranks["pagerank"]
        self.in_degree = ranks["in_degree"]
        self.title = {}
        self.body = {}
        for url, html in pages.items():
            parser = _TextParser()
            parser.feed(html)
            self.title[url] = tokenize(" ".join(parser.title))
            self.body[url] = tokenize(" ".join(parser.text))

    def candidates(self, query):
        """Every page that contains at least one word of the query."""
        words = set(tokenize(query))
        return sorted(url for url in self.body
                      if words & (set(self.body[url]) | set(self.title[url])))

    def features(self, url, query):
        """What score() may use to judge one page for one query.

        Numbers only. The URL and the query text are left out on purpose: at
        grading time the query is hidden, and a score() that could see it could
        echo it into a message or answer it from a lookup table.
        """
        words = tokenize(query)
        body, title = self.body[url], self.title[url]
        return {
            "pagerank": self.pagerank[url],
            "in_degree": self.in_degree[url],
            "title_matches": sum(1 for w in set(words) if w in title),
            "body_matches": sum(body.count(w) for w in words),
            "all_words": all(w in body or w in title for w in words),
            "query_words": len(set(words)),
            "page_words": len(body),
        }

    def search(self, query, score, k=K):
        """The top k candidate pages by score, ties in alphabetical order of URL."""
        scored = []
        for url in self.candidates(query):
            value = score(self.features(url, query))
            if isinstance(value, bool) or not isinstance(value, (int, float)) or math.isnan(value):
                # The message names neither the page nor the query: on the
                # hidden queries, either would tell a student what is graded.
                # score() never sees either, so its return value cannot carry them.
                raise TypeError(f"score() must return a number, but returned {value!r} "
                                f"({type(value).__name__})")
            scored.append((-float(value), url))
        return [url for _, url in sorted(scored)[:k]]


def ndcg(ranked, judgments, k=K):
    """Normalized discounted cumulative gain at k.

    judgments maps URL to relevance: 2 answers the query, 1 is related, and any
    page not listed is 0. A perfect top k scores 1; the best pages placed low,
    or missing, score less.
    """
    def dcg(rels):
        return sum((2 ** r - 1) / math.log2(i + 2) for i, r in enumerate(rels[:k]))

    ideal = dcg(sorted(judgments.values(), reverse=True))
    return dcg([judgments.get(url, 0) for url in ranked]) / ideal if ideal else 0.0


def evaluate(web, score, judged_queries, k=K):
    """Mean nDCG@k over a dict of query -> judgments, and the score per query."""
    per_query = {q: ndcg(web.search(q, score, k), j, k) for q, j in judged_queries.items()}
    return sum(per_query.values()) / len(per_query), per_query
