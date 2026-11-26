"""The three game years' webs, derived from the main mini web.

A stand-in for slice 3 of docs/search-business-game.md, which extends the
generator itself. This derives each year from ../miniweb.json, so the house
engines can be checked against a 1996, a 1998 and a 2000 web today.

- 1996: before the link farm and before Google. The farm, the history pages
  about events after 1996, half the journal and one blog do not exist yet.
  Links to them are removed, since the pages they point to were never written.
- 1998: the whole main web, plus one link: the directory now lists the link
  farm under "Natural Health". Spammers submitted their sites to directories,
  and some directories took the money.
- 2000: the crash. Three sites are gone: the online pharmacy (a dot-com) and
  two blogs. Links to them stay, so they return 404 (link rot).

Every year adds robots.txt files, which a polite crawler fetches and obeys.
A robots.txt is a plain-text value in the web, not HTML. Fetching one costs
no budget, so obeying the rules is never a disadvantage.
"""

import json
import re
from pathlib import Path
from urllib.parse import urljoin, urlsplit, urlunsplit

HERE = Path(__file__).resolve().parent
SEED = "https://directory.example/"

FARM_HOSTS = {"miraclecure.example", "naturalflucure.example", "detoxtruth.example"}
NOT_YET_1996 = {
    "https://searchhistory.example/backrub",
    "https://searchhistory.example/google-founding",
    "https://searchhistory.example/cheriton",
    "https://searchhistory.example/pagerank-patent",
    "https://searchhistory.example/after-pagerank",
}
NOT_YET_1996_HOSTS = FARM_HOSTS | {"newparentnotes.example"}
CRASHED_2000_HOSTS = {"riverbendpharmacy.example", "runnersknee.example",
                      "livingwithdiabetes.example"}

ROBOTS = {
    # The classic use: keep crawlers out of search-result pages.
    "maplevalleyhospital.example": "User-agent: *\nDisallow: /find-a-doctor\n",
    # A personal blog that asks not to be indexed at all.
    "runnersknee.example": "User-agent: *\nDisallow: /\n",
    # A journal that keeps crawlers out of nothing, but says so.
    "jhi.example": "User-agent: *\nDisallow:\n",
}

BUDGET = {1996: 35, 1998: 60, 2000: 60}


def normalize(url):
    parts = urlsplit(url)
    path = parts.path or "/"
    if path != "/" and path.endswith("/"):
        path = path.rstrip("/") or "/"
    return urlunsplit((parts.scheme.lower(), parts.netloc.lower(), path, parts.query, ""))


def host(url):
    return urlsplit(url).netloc


_LINK_ITEM = re.compile(r'  <li><a href="([^"]*)">[^<]*</a></li>\n')


def _drop_links_to(web, gone):
    """Remove each list item whose link resolves to a page in `gone`."""
    out = {}
    for url, html in web.items():
        def keep(match, base=url):
            href = match.group(1).replace("&amp;", "&")
            return "" if normalize(urljoin(base, href)) in gone else match.group(0)
        out[url] = _LINK_ITEM.sub(keep, html)
    return out


def _add_robots(web):
    for h, text in ROBOTS.items():
        if any(host(u) == h for u in web):
            web[f"https://{h}/robots.txt"] = text
    return web


def year_web(year):
    main = json.loads((HERE.parent / "miniweb.json").read_text(encoding="utf-8"))
    if year == 1996:
        gone = {u for u in main
                if u in NOT_YET_1996 or host(u) in NOT_YET_1996_HOSTS
                or re.search(r"/articles/(01[1-9]|020)$", u)}
        web = {u: h for u, h in main.items() if u not in gone}
        web = _drop_links_to(web, gone)
    elif year in (1998, 2000):
        web = dict(main)
        web[SEED] = web[SEED].replace(
            "</ul>", '  <li><a href="https://miraclecure.example/">Natural Health</a></li>\n</ul>', 1)
        if year == 2000:
            web = {u: h for u, h in web.items() if host(u) not in CRASHED_2000_HOSTS}
    else:
        raise ValueError(f"no game year {year}")
    return _add_robots(web)


def judgments(year):
    """The activity's practice and hidden judgments, kept to pages that exist."""
    web = year_web(year)
    act = HERE.parent / "activity"
    out = {}
    for name in ["practice_judgments.json", "hidden_judgments.json"]:
        for query, judged in json.loads((act / name).read_text(encoding="utf-8")).items():
            kept = {u: r for u, r in judged.items() if u in web}
            if any(r == 2 for r in kept.values()):
                out[query] = kept
    return out


if __name__ == "__main__":
    for y in (1996, 1998, 2000):
        web = year_web(y)
        pages = [u for u in web if not u.endswith("/robots.txt")]
        print(f"{y}: {len(pages)} pages, {len({host(u) for u in pages})} hosts, "
              f"{len(web) - len(pages)} robots.txt, budget {BUDGET[y]}, "
              f"{len(judgments(y))} judged queries")
