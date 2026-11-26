"""Generate the HLTH 230 mini web: a small, fictional internet for a search lab.

Writes two JSON files next to this script. Each maps a canonical URL to the
HTML that a server would return for it:

- miniweb.json        the web students crawl (about 150 pages)
- miniweb_small.json  a second, smaller web that the graded tests run against,
                      so an answer hard-coded from the main web fails

Stdlib only, deterministic: the same script always writes the same bytes.

Every domain ends in .example, a top-level domain reserved for documentation
(RFC 2606), so no URL here names a real site. The organisations are fictional.
The history pages describe real events and people; see README.md for sources.

Canonical form of a URL (what a key looks like, and what a student's
normalize() must produce):

1. Resolve the href against the page it appears on (urllib.parse.urljoin).
2. Drop the fragment (#...).
3. Lower-case the scheme and the host.
4. Remove a trailing "/" from the path, unless the path is just "/".
5. Keep the query string: ?dept=cardiology names a different page.

The generator writes links in many equivalent spellings (absolute,
root-relative, ../relative, with a fragment, with a trailing slash, with an
upper-case host) and asserts that each one normalizes to its intended target.
"""

from __future__ import annotations

import json
import posixpath
import random
import sys
from html import escape
from pathlib import Path
from urllib.parse import urljoin, urlsplit, urlunsplit

SEED = 230


# --------------------------------------------------------------------------
# Canonical URLs
# --------------------------------------------------------------------------


def normalize(url: str) -> str:
    """The reference normalizer. The lab's stage 1 asks students to write this."""
    parts = urlsplit(url)
    path = parts.path or "/"
    if path != "/" and path.endswith("/"):
        path = path.rstrip("/") or "/"
    return urlunsplit((parts.scheme.lower(), parts.netloc.lower(), path, parts.query, ""))


# --------------------------------------------------------------------------
# Building pages
# --------------------------------------------------------------------------


class Web:
    """Collects pages, then renders each one with varied link spellings."""

    def __init__(self, seed: int) -> None:
        self.rng = random.Random(seed)
        # url -> (title, paragraphs, [(target or raw href, anchor, raw?)])
        self.pages: dict[str, tuple[str, list[str], list[tuple[str, str, bool]]]] = {}

    def add(self, url: str, title: str, paragraphs: list[str]) -> str:
        assert normalize(url) == url, f"key is not canonical: {url}"
        assert url not in self.pages, f"duplicate page: {url}"
        self.pages[url] = (title, paragraphs, [])
        return url

    def link(self, src: str, dst: str, anchor: str) -> None:
        """A link to another page in this web (dst must exist by render time)."""
        self.pages[src][2].append((dst, anchor, False))

    def raw(self, src: str, href: str, anchor: str) -> None:
        """A link written exactly as given: broken, external, mailto, and so on."""
        self.pages[src][2].append((href, anchor, True))

    def spell(self, src: str, dst: str) -> str:
        """Pick one of several equivalent ways to write a link from src to dst."""
        s, d = urlsplit(src), urlsplit(dst)
        same_host = s.netloc == d.netloc
        choices = ["absolute", "fragment", "trailing", "upper"]
        if same_host:
            choices += ["root", "root", "relative", "relative"]
        style = self.rng.choice(choices)
        query = f"?{d.query}" if d.query else ""
        if style == "root":
            href = d.path + query
        elif style == "relative":
            base_dir = posixpath.dirname(s.path) or "/"
            rel = posixpath.relpath(d.path, base_dir)
            href = ("./" if rel == "." else rel) + query
        elif style == "fragment":
            href = dst + "#" + self.rng.choice(["top", "main", "details", "more"])
        elif style == "trailing" and d.path != "/" and not d.query:
            href = urlunsplit((d.scheme, d.netloc, d.path + "/", "", ""))
        elif style == "upper":
            host = "".join(c.upper() if i % 2 == 0 else c for i, c in enumerate(d.netloc))
            href = urlunsplit((d.scheme.upper(), host, d.path, d.query, ""))
        else:
            href = dst
        if normalize(urljoin(src, href)) != dst:
            href = dst  # fall back rather than emit a link that misleads
        assert normalize(urljoin(src, href)) == dst, (src, href, dst)
        return href

    def render(self) -> dict[str, str]:
        out: dict[str, str] = {}
        for url, (title, paragraphs, links) in self.pages.items():
            body: list[str] = [f"<h1>{escape(title)}</h1>"]
            body += [f"<p>{escape(p)}</p>" for p in paragraphs]
            if links:
                body.append("<ul>")
                for target, anchor, is_raw in links:
                    if not is_raw:
                        assert target in self.pages, f"{url} links to missing {target}"
                    href = target if is_raw else self.spell(url, target)
                    body.append(f'  <li><a href="{escape(href)}">{escape(anchor)}</a></li>')
                body.append("</ul>")
            out[url] = (
                "<!DOCTYPE html>\n<html>\n<head>\n"
                f"<title>{escape(title)}</title>\n"
                "</head>\n<body>\n" + "\n".join(body) + "\n</body>\n</html>\n"
            )
        return out


# --------------------------------------------------------------------------
# The main web
# --------------------------------------------------------------------------

DIRECTORY = "https://directory.example/"
PH = "https://publichealth.example"
HOSP = "https://maplevalleyhospital.example"
JOURNAL = "https://jhi.example"
PHARM = "https://riverbendpharmacy.example"
HISTORY = "https://searchhistory.example"
LIBRARY = "https://library.mvu.example"

PH_TOPICS: dict[str, tuple[str, str]] = {
    "flu": ("Influenza", "Influenza (the flu) is a respiratory infection. Annual flu vaccination is the most effective prevention. Most people recover in one to two weeks; seek care for difficulty breathing."),
    "covid-19": ("COVID-19", "COVID-19 is a respiratory illness caused by a coronavirus. Vaccination, ventilation and staying home when sick reduce spread."),
    "measles": ("Measles", "Measles is one of the most contagious diseases known. Two doses of the MMR vaccine protect against measles, mumps and rubella."),
    "vaccines": ("Vaccines and Immunization", "Routine immunization schedules protect children and adults. Records can be checked at any public health clinic."),
    "handwashing": ("Handwashing", "Washing hands with soap for twenty seconds removes most germs. Hand sanitizer works when soap is not available."),
    "heat": ("Extreme Heat", "Heat warnings are issued when temperatures reach dangerous levels. Older adults and infants face the greatest risk of heat illness."),
    "water": ("Drinking Water Advisories", "A boil-water advisory means tap water must be boiled for one minute before drinking. Advisories are posted here as they are issued."),
    "food-safety": ("Food Safety", "Keep cold food cold and hot food hot. Food poisoning often comes from undercooked meat or unwashed produce."),
    "sexual-health": ("Sexual Health", "Free and confidential testing for sexually transmitted infections is available at the sexual health clinic."),
    "mental-health": ("Mental Health Resources", "Crisis lines are open at all hours. Counselling services are listed by neighbourhood."),
    "smoking": ("Quit Smoking", "Nicotine replacement therapy and counselling double the chance of quitting smoking."),
    "air-quality": ("Air Quality", "Wildfire smoke raises fine particulate levels. People with asthma should limit time outdoors on poor air quality days."),
    "travel": ("Travel Health", "Some destinations require vaccines before travel. Book a travel clinic visit six weeks before departure."),
    "outbreaks": ("Current Outbreaks", "This page lists outbreaks in long-term care homes and schools, updated daily during flu season."),
    "data": ("Health Data and Reports", "Weekly surveillance reports summarize flu, COVID-19 and other reportable diseases in the region."),
}
PH_RELATED = {
    "flu": ["vaccines", "covid-19", "handwashing", "outbreaks"],
    "covid-19": ["vaccines", "flu", "outbreaks", "data"],
    "measles": ["vaccines", "travel", "outbreaks"],
    "vaccines": ["flu", "measles", "covid-19", "travel"],
    "handwashing": ["flu", "food-safety"],
    "heat": ["air-quality", "water"],
    "water": ["food-safety", "heat"],
    "food-safety": ["handwashing", "water"],
    "sexual-health": ["mental-health"],
    "mental-health": ["sexual-health", "smoking"],
    "smoking": ["mental-health", "air-quality"],
    "air-quality": ["heat", "smoking"],
    "travel": ["vaccines", "measles"],
    "outbreaks": ["flu", "covid-19", "data"],
    "data": ["outbreaks", "flu"],
}

DEPARTMENTS: dict[str, str] = {
    "emergency": "The emergency department is open at all hours. Call 911 for chest pain, stroke symptoms or severe bleeding.",
    "cardiology": "Cardiology treats heart disease, including heart attack, arrhythmia and heart failure. Referral from a family doctor is required.",
    "oncology": "The cancer centre offers chemotherapy, radiation therapy and support services for patients and families.",
    "pediatrics": "Pediatrics cares for infants, children and adolescents, including a neonatal intensive care unit.",
    "maternity": "The birthing unit supports more than two thousand births a year. Prenatal classes are offered monthly.",
    "mental-health": "Inpatient and outpatient mental health services, including an urgent care clinic for adults in crisis.",
    "diabetes": "The diabetes education centre teaches blood glucose monitoring, insulin use and nutrition.",
    "imaging": "Diagnostic imaging includes X-ray, CT, MRI and ultrasound. Bring your requisition to every appointment.",
    "respiratory": "Respiratory therapy supports patients with asthma, COPD and those recovering from pneumonia or flu.",
    "infection-control": "Infection prevention and control monitors hospital-acquired infections and outbreak response.",
}

CLINICS: dict[str, tuple[str, str]] = {
    "northside": ("Northside Family Health Team", "Family physicians and nurse practitioners serving the north end. Flu shots available each fall."),
    "lakeside": ("Lakeside Walk-In Clinic", "Walk-in care for minor illness and injury. No appointment needed."),
    "eastgate": ("Eastgate Community Health Centre", "Primary care, diabetes education and a dental program for families without coverage."),
    "campus": ("MVU Campus Health Services", "Health services for students: physicians, counselling, travel vaccines and sexual health testing."),
}

BLOGS: dict[str, tuple[str, list[tuple[str, str]]]] = {
    "livingwithdiabetes": (
        "Living with Type 1 Diabetes",
        [
            ("my-first-pump", "Notes from my first month on an insulin pump. The diabetes education centre at the hospital made the change much easier."),
            ("carb-counting", "How I count carbohydrates at restaurants. Food safety matters too when you eat out."),
            ("flu-season", "Why I get my flu shot every year: an infection can send blood glucose out of control."),
        ],
    ),
    "runnersknee": (
        "Runner's Knee",
        [
            ("heat-running", "Running in a heat warning is a bad idea. I check the public health heat page before every long run."),
            ("air-quality-days", "Wildfire smoke days and when I move my training indoors."),
            ("recovery", "Physiotherapy after a knee injury, week by week."),
        ],
    ),
    "newparentnotes": (
        "New Parent Notes",
        [
            ("vaccine-schedule", "Our pediatrician walked us through the infant vaccine schedule. Measles protection starts at twelve months."),
            ("fever", "What we learned about fever in babies, and when to go to the emergency department."),
            ("sleep", "Sleep schedules, and a reader in the comments who swears by a miracle cure for flu."),
        ],
    ),
}

ARTICLE_TOPICS = [
    ("Influenza vaccine uptake in long-term care homes", "influenza vaccine uptake long-term care outbreak"),
    ("Measles outbreak response in a school population", "measles outbreak vaccination school"),
    ("Wildfire smoke and emergency visits for asthma", "air quality asthma emergency wildfire"),
    ("Heat warnings and mortality in older adults", "heat mortality older adults warning"),
    ("Electronic health records and medication errors", "electronic health records medication error"),
    ("Predicting hypertension from survey data", "hypertension blood pressure prediction survey"),
    ("Diabetes self-management apps: a review", "diabetes apps self-management glucose"),
    ("Search engine queries as flu surveillance", "influenza surveillance search queries"),
    ("Health misinformation on the web", "misinformation health web credibility"),
    ("Ranking hospitals by referral networks", "referral network hospital ranking pagerank"),
    ("Citation analysis of health informatics journals", "citation analysis bibliometrics impact"),
    ("Privacy of patient data in research datasets", "privacy patient data deidentification"),
    ("Telehealth use in rural communities", "telehealth rural access"),
    ("Contact tracing and network structure", "contact tracing network outbreak"),
    ("Readability of patient education materials", "readability patient education"),
    ("Vaccine hesitancy and online information", "vaccine hesitancy misinformation online"),
    ("Machine learning for sepsis alerts", "sepsis machine learning alert"),
    ("Food-borne illness reporting systems", "food safety illness surveillance"),
    ("Smoking cessation program outcomes", "smoking cessation nicotine"),
    ("Emergency department crowding and wait times", "emergency department wait times"),
]

HISTORY_PAGES: dict[str, tuple[str, list[str]]] = {
    "/": ("A Short History of Web Search", [
        "Search engines grew out of decades of work on indexing text and ranking documents. These pages trace a path from the Oxford English Dictionary to PageRank, with several stops at the University of Waterloo.",
    ]),
    "/oed": ("The New Oxford English Dictionary Project", [
        "In the 1980s the University of Waterloo worked with Oxford University Press to put the Oxford English Dictionary into electronic form.",
        "Gaston Gonnet and Frank Tompa led the Waterloo work on searching the dictionary's full text quickly. Their indexing techniques became the basis of a company.",
    ]),
    "/open-text": ("Open Text and the Open Text Index", [
        "Gonnet and Tompa founded Open Text to commercialize the text indexing built for the dictionary project. The company is still headquartered in Waterloo.",
        "In April 1995 Open Text launched the Open Text Index, one of the first commercial web search engines. Tim Bray built its web crawler.",
        "For part of 1995, Yahoo used Open Text to search the web. The Open Text Index closed around 1997, and the company turned to enterprise software.",
    ]),
    "/archie": ("Archie, 1990", [
        "Archie, written at McGill University in Montreal in 1990, indexed the names of files on public FTP servers. It is often called the first internet search engine.",
    ]),
    "/directories": ("Directories and Portals", [
        "Early web portals such as Yahoo began as directories: people chose and categorized sites by hand. A directory does not scale with a web that doubles in size every few months.",
    ]),
    "/citation-analysis": ("Citation Analysis", [
        "Eugene Garfield's Science Citation Index, first published in 1964, counted how often scientific papers cite one another. The journal impact factor comes from this work.",
        "Later bibliometric methods weighted a citation by the importance of the citing journal. PageRank applies the same recursive idea to links between web pages.",
    ]),
    "/backrub": ("BackRub and PageRank", [
        "At Stanford, Larry Page and Sergey Brin built a crawler called BackRub to study the links pointing back to each page.",
        "PageRank models a random surfer who follows links and sometimes jumps to a random page. A page ranks highly when highly ranked pages link to it.",
        "Page and Brin offered the technology to portals including Yahoo, AltaVista and Excite. None bought it.",
    ]),
    "/google-founding": ("The Founding of Google", [
        "In August 1998 Andy Bechtolsheim wrote a cheque for 100,000 dollars to a company that did not yet exist. Google was incorporated on September 4, 1998.",
        "David Cheriton, a Stanford professor, was one of Google's earliest investors.",
    ]),
    "/cheriton": ("David Cheriton and Waterloo", [
        "David Cheriton earned his MMath in 1974 and his PhD in 1978 at the University of Waterloo, then became a professor at Stanford.",
        "On November 18, 2005, Waterloo announced a 25 million dollar gift from Cheriton for graduate studies and research in computer science. In recognition, the university named the David R. Cheriton School of Computer Science.",
    ]),
    "/pagerank-patent": ("The PageRank Patent", [
        "US Patent 6,285,999, Method for node ranking in a linked database, was filed on January 9, 1998 and granted on September 4, 2001. Stanford University owned it, and Google held a licence.",
        "The patent expired on January 9, 2018, twenty years after it was filed.",
    ]),
    "/after-pagerank": ("After PageRank", [
        "Once rankings drove traffic, people built link farms: groups of pages that link to one another to raise their rank. Search engines responded with spam detection and, later, machine-learned ranking.",
        "PageRank remains one signal among hundreds.",
    ]),
}
HISTORY_ORDER = ["/oed", "/open-text", "/archie", "/directories", "/citation-analysis",
                 "/backrub", "/google-founding", "/cheriton", "/pagerank-patent", "/after-pagerank"]

FARM_DOMAINS = ["miraclecure.example", "naturalflucure.example", "detoxtruth.example"]
FARM_SLUGS = ["", "flu-cure", "secret", "testimonials", "doctors-hate-this", "order",
              "immune-boost", "detox", "cure-flu-fast", "vaccine-truth"]
FARM_TEXT = [
    "Cure the flu in one hour with our all natural tonic. Flu cure flu cure flu cure.",
    "Doctors do not want you to know about this flu cure. Thousands cured.",
    "Boost your immune system and cure flu, colds and more. Natural cure.",
    "Real people, real cures. Order the miracle flu cure today.",
]


def build_main() -> Web:
    w = Web(SEED)
    rng = random.Random(SEED + 1)

    # The directory: the seed page, a 1995-style portal.
    w.add(DIRECTORY, "Maple Valley Web Directory", [
        "A hand-picked directory of health sites in the Maple Valley region, in the style of a 1990s web portal.",
    ])

    # Public health.
    ph_home = w.add(PH + "/", "Maple Valley Public Health", [
        "Maple Valley Public Health protects and promotes the health of everyone in the region: vaccines, outbreaks, clean water and safe food.",
    ])
    contact = w.add(PH + "/contact", "Contact Public Health", [
        "Call the health line or visit a clinic. Clinic hours change during flu season.",
    ])
    for slug, (title, text) in PH_TOPICS.items():
        w.add(f"{PH}/topics/{slug}", title, [text])
    w.add(PH + "/topics/flu/clinics", "Flu Vaccine Clinics", [
        "Free flu vaccine clinics run from October to December. Bring your health card.",
    ])

    # Hospital.
    hosp_home = w.add(HOSP + "/", "Maple Valley General Hospital", [
        "Maple Valley General Hospital provides emergency, surgical and specialist care to the region.",
    ])
    w.add(HOSP + "/visiting", "Visiting Hours", [
        "Visiting hours are 9 a.m. to 9 p.m. Visitors with flu symptoms should stay home.",
    ])
    w.add(HOSP + "/patients", "Patients and Families", ["Information for patients before, during and after a hospital stay."])
    for slug, text in DEPARTMENTS.items():
        w.add(f"{HOSP}/departments/{slug}", slug.replace("-", " ").title(), [text])
    w.add(HOSP + "/find-a-doctor", "Find a Doctor", ["Search for physicians by department."])
    for slug in ["cardiology", "oncology", "pediatrics"]:
        w.add(f"{HOSP}/find-a-doctor?dept={slug}", f"Doctors in {slug.title()}",
              [f"Physicians accepting referrals in {slug}."])

    # Clinics.
    for slug, (title, text) in CLINICS.items():
        w.add(f"https://{slug}clinic.example/", title, [text])

    # Pharmacy.
    w.add(PHARM + "/", "Riverbend Pharmacy", ["Prescriptions, flu shots and medication reviews."])
    w.add(PHARM + "/flu-shots", "Flu Shots at Riverbend", ["Pharmacists give flu vaccines to anyone aged two and older, no appointment needed."])
    w.add(PHARM + "/medication-safety", "Medication Safety", ["Bring all your medications to a medication review once a year."])

    # Journal.
    w.add(JOURNAL + "/", "Journal of Health Informatics", ["A peer-reviewed journal on data, computing and health."])
    articles = []
    for i, (title, words) in enumerate(ARTICLE_TOPICS, start=1):
        url = w.add(f"{JOURNAL}/articles/{i:03d}", title, [
            f"Abstract. This study examines {words}. Methods, results and limitations follow.",
        ])
        articles.append(url)

    # University library and the history site.
    w.add(LIBRARY + "/", "Maple Valley University Library", ["Research guides, databases and course reserves."])
    w.add(LIBRARY + "/guides/health-informatics", "Research Guide: Health Informatics", [
        "Start here for health informatics sources: journals, public health data, and the history of search.",
    ])
    for path, (title, paras) in HISTORY_PAGES.items():
        w.add(HISTORY + path, title, paras)

    # Blogs.
    for blog, (title, posts) in BLOGS.items():
        w.add(f"https://{blog}.example/", title, [f"A personal blog: {title.lower()}."])
        for slug, text in posts:
            w.add(f"https://{blog}.example/posts/{slug}", slug.replace("-", " ").capitalize(), [text])

    # Link farm.
    farm = []
    for d_i, domain in enumerate(FARM_DOMAINS):
        for s_i, slug in enumerate(FARM_SLUGS):
            if d_i > 0 and s_i >= 8:
                continue  # the second and third farm domains are smaller
            path = "/" if slug == "" else "/" + slug
            title = "Miracle Flu Cure" if slug == "" else slug.replace("-", " ").title() + " | Natural Flu Cure"
            farm.append(w.add(f"https://{domain}{path}", title, [FARM_TEXT[(d_i + s_i) % len(FARM_TEXT)]]))

    # Dangling pages: a printable PDF stand-in with no links out.
    dangling = w.add(PH + "/topics/flu/fact-sheet", "Flu Fact Sheet (print version)", [
        "Flu symptoms: fever, cough, sore throat, aches. Get vaccinated every fall.",
    ])

    # ---------------- links ----------------

    # Directory: one link to each reputable site.
    for url, anchor in [
        (ph_home, "Maple Valley Public Health"),
        (hosp_home, "Maple Valley General Hospital"),
        (PHARM + "/", "Riverbend Pharmacy"),
        (JOURNAL + "/", "Journal of Health Informatics"),
        (LIBRARY + "/", "MVU Library"),
        (HISTORY + "/", "A Short History of Web Search"),
    ] + [(f"https://{s}clinic.example/", t) for s, (t, _) in CLINICS.items()] \
      + [(f"https://{b}.example/", t) for b, (t, _) in BLOGS.items()]:
        w.link(DIRECTORY, url, anchor)

    # Public health site: home <-> topics, related topics, contact.
    for slug, (title, _) in PH_TOPICS.items():
        w.link(ph_home, f"{PH}/topics/{slug}", title)
    w.link(ph_home, contact, "Contact us")
    w.raw(contact, "mailto:info@publichealth.example", "Email the health line")
    w.raw(contact, "tel:+1-555-0100", "Call the health line")
    for slug, related in PH_RELATED.items():
        src = f"{PH}/topics/{slug}"
        w.link(src, ph_home, "Public Health home")
        w.link(src, contact, "Contact")
        for r in related:
            w.link(src, f"{PH}/topics/{r}", PH_TOPICS[r][0])
    w.link(f"{PH}/topics/flu", f"{PH}/topics/flu/clinics", "Flu vaccine clinics")
    w.link(f"{PH}/topics/flu", dangling, "Printable fact sheet")
    w.link(f"{PH}/topics/flu/clinics", f"{PH}/topics/flu", "About the flu")
    w.link(f"{PH}/topics/flu/clinics", PHARM + "/flu-shots", "Flu shots at pharmacies")
    w.raw(f"{PH}/topics/flu", "/topics/flu/archive-2019", "2019 flu season report (archived)")  # broken
    w.raw(f"{PH}/topics/data", "https://publichealth.example/reports/weekly.pdf", "Download the weekly report")  # broken
    w.raw(ph_home, "https://www.who.int/", "World Health Organization")  # external
    w.link(f"{PH}/topics/vaccines", HOSP + "/departments/pediatrics", "Hospital pediatrics")
    w.link(f"{PH}/topics/mental-health", HOSP + "/departments/mental-health", "Hospital mental health services")
    w.link(f"{PH}/topics/sexual-health", "https://campusclinic.example/", "Campus sexual health testing")
    w.link(f"{PH}/topics/data", JOURNAL + "/articles/008", "Search queries as flu surveillance")

    # Hospital site.
    for slug in DEPARTMENTS:
        w.link(hosp_home, f"{HOSP}/departments/{slug}", slug.replace("-", " ").title())
        w.link(f"{HOSP}/departments/{slug}", hosp_home, "Hospital home")
        w.link(f"{HOSP}/departments/{slug}", HOSP + "/visiting", "Visiting hours")
    for page in ["/visiting", "/patients", "/find-a-doctor"]:
        w.link(hosp_home, HOSP + page, page.strip("/").replace("-", " ").title())
        w.link(HOSP + page, hosp_home, "Hospital home")
    for slug in ["cardiology", "oncology", "pediatrics"]:
        w.link(HOSP + "/find-a-doctor", f"{HOSP}/find-a-doctor?dept={slug}", slug.title())
        w.link(f"{HOSP}/departments/{slug}", f"{HOSP}/find-a-doctor?dept={slug}", "Find a doctor")
        w.link(f"{HOSP}/find-a-doctor?dept={slug}", f"{HOSP}/departments/{slug}", slug.title())
    w.link(hosp_home, ph_home, "Maple Valley Public Health")
    w.link(HOSP + "/departments/infection-control", f"{PH}/topics/outbreaks", "Current outbreaks")
    w.link(HOSP + "/departments/respiratory", f"{PH}/topics/flu", "Flu information")
    w.link(HOSP + "/departments/respiratory", f"{PH}/topics/air-quality", "Air quality")
    w.link(HOSP + "/departments/emergency", f"{PH}/topics/heat", "Heat warnings")
    w.raw(HOSP + "/patients", "/patients/parking-map", "Parking map")  # broken
    w.raw(HOSP + "/patients", "javascript:window.print()", "Print this page")

    # Clinics: each links to public health, the hospital, and a topic or two.
    for slug in CLINICS:
        src = f"https://{slug}clinic.example/"
        w.link(src, ph_home, "Public Health")
        w.link(src, hosp_home, "Maple Valley General Hospital")
        w.link(src, f"{PH}/topics/flu", "Flu season information")
    w.link("https://eastgateclinic.example/", HOSP + "/departments/diabetes", "Diabetes education centre")
    w.link("https://campusclinic.example/", f"{PH}/topics/sexual-health", "Sexual health")
    w.link("https://campusclinic.example/", f"{PH}/topics/travel", "Travel health")
    w.link("https://campusclinic.example/", f"{PH}/topics/mental-health", "Mental health resources")
    w.link("https://campusclinic.example/", LIBRARY + "/", "MVU Library")

    # Pharmacy.
    for page in ["/flu-shots", "/medication-safety"]:
        w.link(PHARM + "/", PHARM + page, page.strip("/").replace("-", " ").title())
        w.link(PHARM + page, PHARM + "/", "Pharmacy home")
    w.link(PHARM + "/flu-shots", f"{PH}/topics/flu", "About the flu")
    w.link(PHARM + "/flu-shots", f"{PH}/topics/flu/clinics", "Public health flu clinics")
    w.link(PHARM + "/medication-safety", HOSP + "/patients", "Going to hospital")

    # Journal: index links to every article; articles cite earlier articles and
    # public health data. A citation network inside the web.
    for url, (title, _) in zip(articles, ARTICLE_TOPICS):
        w.link(JOURNAL + "/", url, title)
        w.link(url, JOURNAL + "/", "Journal home")
    for i, url in enumerate(articles):
        earlier = articles[:i]
        for cited in rng.sample(earlier, k=min(len(earlier), rng.randint(1, 4))):
            w.link(url, cited, "Cited: " + ARTICLE_TOPICS[articles.index(cited)][0])
    w.link(articles[0], f"{PH}/topics/flu", "Regional flu data")
    w.link(articles[7], f"{PH}/topics/data", "Surveillance reports")
    w.link(articles[8], HISTORY + "/after-pagerank", "Link farms and ranking")
    w.link(articles[9], HISTORY + "/backrub", "PageRank")
    w.link(articles[10], HISTORY + "/citation-analysis", "A history of citation analysis")

    # Library guide.
    w.link(LIBRARY + "/", LIBRARY + "/guides/health-informatics", "Health informatics guide")
    w.link(LIBRARY + "/guides/health-informatics", LIBRARY + "/", "Library home")
    w.link(LIBRARY + "/guides/health-informatics", JOURNAL + "/", "Journal of Health Informatics")
    w.link(LIBRARY + "/guides/health-informatics", ph_home, "Public health data")
    w.link(LIBRARY + "/guides/health-informatics", HISTORY + "/", "A short history of web search")

    # History site: a chain through the story, each page back to the index.
    w.link(HISTORY + "/", DIRECTORY, "A web directory, 1990s style")
    for i, path in enumerate(HISTORY_ORDER):
        w.link(HISTORY + "/", HISTORY + path, HISTORY_PAGES[path][0])
        w.link(HISTORY + path, HISTORY + "/", "All history pages")
        if i + 1 < len(HISTORY_ORDER):
            nxt = HISTORY_ORDER[i + 1]
            w.link(HISTORY + path, HISTORY + nxt, "Next: " + HISTORY_PAGES[nxt][0])
    w.link(HISTORY + "/open-text", HISTORY + "/oed", "Where the indexing came from")
    w.link(HISTORY + "/cheriton", HISTORY + "/google-founding", "Google's first investors")
    w.link(HISTORY + "/google-founding", HISTORY + "/cheriton", "Cheriton and Waterloo")
    w.link(HISTORY + "/citation-analysis", HISTORY + "/backrub", "From citations to links")
    w.link(HISTORY + "/after-pagerank", "https://miraclecure.example/", "An example of a link farm")
    w.raw(HISTORY + "/open-text", "https://www.opentext.com/", "OpenText today")  # external

    # Blogs: home <-> posts, plus links to the sites they mention.
    for blog, (_, posts) in BLOGS.items():
        home = f"https://{blog}.example/"
        for slug, _text in posts:
            post = f"{home}posts/{slug}"
            w.link(home, post, slug.replace("-", " ").capitalize())
            w.link(post, home, "Blog home")
    w.link("https://livingwithdiabetes.example/posts/my-first-pump", HOSP + "/departments/diabetes", "Diabetes education centre")
    w.link("https://livingwithdiabetes.example/posts/carb-counting", f"{PH}/topics/food-safety", "Food safety")
    w.link("https://livingwithdiabetes.example/posts/flu-season", f"{PH}/topics/flu", "Flu information")
    w.link("https://livingwithdiabetes.example/posts/flu-season", PHARM + "/flu-shots", "Pharmacy flu shots")
    w.link("https://runnersknee.example/posts/heat-running", f"{PH}/topics/heat", "Heat warnings")
    w.link("https://runnersknee.example/posts/air-quality-days", f"{PH}/topics/air-quality", "Air quality")
    w.link("https://newparentnotes.example/posts/vaccine-schedule", f"{PH}/topics/vaccines", "Vaccine schedule")
    w.link("https://newparentnotes.example/posts/vaccine-schedule", f"{PH}/topics/measles", "Measles")
    w.link("https://newparentnotes.example/posts/fever", HOSP + "/departments/emergency", "Emergency department")
    w.link("https://newparentnotes.example/posts/fever", HOSP + "/departments/pediatrics", "Pediatrics")
    w.link("https://newparentnotes.example/posts/sleep", "https://miraclecure.example/flu-cure", "A commenter's miracle flu cure")
    w.link("https://newparentnotes.example/", "https://livingwithdiabetes.example/", "Blogs I read")
    w.link("https://runnersknee.example/", "https://newparentnotes.example/", "Blogs I read")

    # The farm: every farm page links to every other farm page. No link leaves it.
    for src in farm:
        for dst in farm:
            if dst != src:
                w.link(src, dst, w.pages[dst][0])

    return w


# --------------------------------------------------------------------------
# The small web for graded tests
# --------------------------------------------------------------------------


def build_small() -> Web:
    w = Web(SEED + 100)
    clinic = "https://harbourclinic.example"
    w.add("https://start.example/", "Harbour Town Links", ["Links to health sites in Harbour Town."])
    w.add(clinic + "/", "Harbour Town Clinic", ["Family medicine and a weekly asthma clinic."])
    w.add(clinic + "/asthma", "Asthma Clinic", ["Inhaler technique and asthma action plans."])
    w.add(clinic + "/services/allergy", "Allergy Testing", ["Skin prick testing for seasonal allergies."])
    w.add(clinic + "/hours?day=saturday", "Saturday Hours", ["Open Saturday mornings for urgent visits."])
    w.add("https://harbourhealth.example/", "Harbour Health Unit", ["Public health for Harbour Town: pollen counts and asthma alerts."])
    w.add("https://harbourhealth.example/pollen", "Pollen Forecast", ["Daily pollen forecast for allergy and asthma sufferers."])
    w.add("https://harbourhealth.example/print", "Pollen Forecast (print)", ["Printable pollen forecast."])
    w.add("https://wheezeless.example/", "Wheezeless Cure", ["Cure asthma forever. Asthma cure asthma cure."])
    w.add("https://wheezeless.example/buy", "Buy Wheezeless", ["Asthma cure, order now."])
    w.add("https://wheezeless.example/proof", "Proof Wheezeless Works", ["Asthma cure testimonials."])

    w.link("https://start.example/", clinic + "/", "Harbour Town Clinic")
    w.link("https://start.example/", "https://harbourhealth.example/", "Harbour Health Unit")
    w.link(clinic + "/", clinic + "/asthma", "Asthma clinic")
    w.link(clinic + "/", clinic + "/services/allergy", "Allergy testing")
    w.link(clinic + "/", clinic + "/hours?day=saturday", "Saturday hours")
    w.link(clinic + "/asthma", clinic + "/", "Clinic home")
    w.link(clinic + "/asthma", "https://harbourhealth.example/pollen", "Pollen forecast")
    w.link(clinic + "/services/allergy", clinic + "/asthma", "Asthma clinic")
    w.link(clinic + "/services/allergy", clinic + "/", "Clinic home")
    w.link(clinic + "/hours?day=saturday", clinic + "/", "Clinic home")
    w.link("https://harbourhealth.example/", "https://harbourhealth.example/pollen", "Pollen forecast")
    w.link("https://harbourhealth.example/", clinic + "/asthma", "Asthma clinic")
    w.link("https://harbourhealth.example/pollen", "https://harbourhealth.example/", "Health unit home")
    w.link("https://harbourhealth.example/pollen", "https://harbourhealth.example/print", "Print")
    w.link("https://harbourhealth.example/pollen", clinic + "/services/allergy", "Allergy testing")
    w.raw("https://harbourhealth.example/pollen", "/pollen/archive", "Archive")  # broken
    w.raw(clinic + "/", "mailto:desk@harbourclinic.example", "Email the clinic")
    w.link(clinic + "/services/allergy", "https://wheezeless.example/", "Sponsored: asthma cure")
    farm = ["https://wheezeless.example/", "https://wheezeless.example/buy", "https://wheezeless.example/proof"]
    for src in farm:
        for dst in farm:
            if dst != src:
                w.link(src, dst, w.pages[dst][0])
    return w


def main() -> int:
    here = Path(__file__).resolve().parent
    for name, web in [("miniweb.json", build_main()), ("miniweb_small.json", build_small())]:
        pages = web.render()
        (here / name).write_text(json.dumps(pages, indent=1, sort_keys=True) + "\n", encoding="utf-8")
        print(f"{name}: {len(pages)} pages")
    return 0


if __name__ == "__main__":
    sys.exit(main())
