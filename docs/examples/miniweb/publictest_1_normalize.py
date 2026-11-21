# Stage 1: normalize
from test_runtime import errored, failed, passed, require_function

normalize = require_function("normalize", 1)

CASES = [
    ("https://publichealth.example/topics/flu", "https://publichealth.example/topics/flu"),
    ("https://publichealth.example/topics/flu/", "https://publichealth.example/topics/flu"),
    ("https://publichealth.example/topics/flu#symptoms", "https://publichealth.example/topics/flu"),
    ("HTTPS://PublicHealth.example/topics/flu", "https://publichealth.example/topics/flu"),
    ("https://publichealth.example/Topics/Flu", "https://publichealth.example/Topics/Flu"),
    ("https://maplevalleyhospital.example", "https://maplevalleyhospital.example/"),
    ("https://maplevalleyhospital.example/", "https://maplevalleyhospital.example/"),
    ("https://maplevalleyhospital.example/#top", "https://maplevalleyhospital.example/"),
    ("https://maplevalleyhospital.example/find-a-doctor?dept=cardiology",
     "https://maplevalleyhospital.example/find-a-doctor?dept=cardiology"),
    ("https://maplevalleyhospital.example/find-a-doctor/?dept=oncology#list",
     "https://maplevalleyhospital.example/find-a-doctor?dept=oncology"),
]

wrong = []
for given, expected in CASES:
    try:
        got = normalize(given)
    except Exception as exc:
        errored(f"normalize({given!r}) raised {type(exc).__name__}: {exc}", exc)
    if got != expected:
        wrong.append(f"normalize({given!r})\n  expected {expected!r}\n  got      {got!r}")

if wrong:
    failed(f"{len(wrong)} of {len(CASES)} URLs were not normalized correctly.\n" + "\n".join(wrong))
passed(f"Stage 1: all {len(CASES)} URLs normalized correctly")
