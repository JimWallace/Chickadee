# Stage 2: extract_links
from urllib.parse import urljoin

from test_runtime import errored, failed, passed, require_function

extract_links = require_function("extract_links", 2)

BASE = "https://maplevalleyhospital.example/departments/cardiology"
HTML = """<html><body>
<a href="https://maplevalleyhospital.example/">Home</a>
<a href="/visiting">Visiting hours</a>
<a href="../find-a-doctor?dept=cardiology">Find a doctor</a>
<a href="oncology#services">Oncology</a>
<a href="mailto:info@maplevalleyhospital.example">Email</a>
<a href="tel:+1-555-0100">Call</a>
<a href="HTTPS://PublicHealth.example/topics/flu/">Flu</a>
<a href="/visiting">Visiting hours, again</a>
<p>No link here.</p>
</body></html>"""
EXPECTED = [
    "https://maplevalleyhospital.example/",
    "https://maplevalleyhospital.example/visiting",
    "https://maplevalleyhospital.example/find-a-doctor?dept=cardiology",
    "https://maplevalleyhospital.example/departments/oncology",
    "https://publichealth.example/topics/flu",
    "https://maplevalleyhospital.example/visiting",
]

# Stage 1 is graded on its own, so this test supplies the canonical form of each
# URL it uses. A mistake in normalize() does not cost marks here.
CANONICAL = {urljoin(BASE, href): canonical for href, canonical in [
    ("https://maplevalleyhospital.example/", EXPECTED[0]),
    ("/visiting", EXPECTED[1]),
    ("../find-a-doctor?dept=cardiology", EXPECTED[2]),
    ("oncology#services", EXPECTED[3]),
    ("HTTPS://PublicHealth.example/topics/flu/", EXPECTED[4]),
]}
extract_links.__globals__["normalize"] = lambda url: CANONICAL.get(url, url)

try:
    got = extract_links(BASE, HTML)
except Exception as exc:
    errored(f"extract_links raised {type(exc).__name__}: {exc}", exc)

if not isinstance(got, list):
    failed(f"extract_links should return a list, but returned a {type(got).__name__}.")
if got != EXPECTED:
    lines = [f"Page: {BASE}", "Expected, in page order:"] + [f"  {u}" for u in EXPECTED]
    lines += ["Got:"] + [f"  {u}" for u in got]
    if any(u.startswith(("mailto:", "tel:")) for u in got):
        lines.append("Links that are not http or https should be left out.")
    if len(got) == len(set(got)) and len(EXPECTED) != len(set(EXPECTED)):
        lines.append("A link that appears twice on the page appears twice in the list.")
    failed("extract_links returned the wrong links.\n" + "\n".join(lines))
passed("Stage 2: links resolved, normalized and filtered correctly")
