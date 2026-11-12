# A FHIR feed for HLTH 230 Assignment 3

This folder holds the material for a fourth question in HLTH 230 Assignment 3
(`eQCS0i`): a screen of a simulated emergency department feed, delivered as a
FHIR NDJSON dataset from the course library (`docs/fhir-datasets-plan.md`,
Stage B). Every student receives the same file (decision 1 of that plan).

| File | What it is |
|---|---|
| `generate_ed_feed.py` | Writes the feed. The same seed always writes the same bytes. |
| `chickadee_fhir.py` | The support-file helper: search with paging, and a simulated clock. |
| `test_chickadee_fhir.py` | The helper's own checks. Exits 0 or 1, so it can run as a suite script. |
| `reference_solution.py` | The reference answers to Question 4, and the values the tests expect. |

Rebuild the feed and print the expected answers from this folder. The second
command imports the helper from this folder, so it runs without `-I`:

```bash
python3 -I generate_ed_feed.py ed_feed.ndjson
```

```bash
python3 reference_solution.py ed_feed.ndjson
```

```bash
python3 -I test_chickadee_fhir.py
```

## The feed

`generate_ed_feed.py` with its defaults (300 patients, seed 230) writes 6,580
resources, about 3.2 MB: 300 Patients, 300 Encounters and 5,980 vital-sign
Observations. The vital signs are body temperature (LOINC 8310-5, Cel), heart
rate (8867-4, /min), oxygen saturation (59408-5, %) and respiratory rate
(9279-1, /min), taken at triage and then every hour. About one patient in
eight deteriorates during the stay. With the defaults, 20 patients meet two
or more of the vital-sign SIRS criteria on their latest values, and the first
of them does so in the third hour of the day.

## The proposed question

The text below follows the authoring voice in `CLAUDE.md`. It assumes the
library dataset is attached as `ed_feed.ndjson` and `chickadee_fhir.py` is a
support file.

> ## Question 4: Screening an Emergency Department Feed
>
> Hospitals now exchange clinical data as FHIR resources: small JSON
> documents, each of one type, such as a `Patient`, an `Encounter` or an
> `Observation`. A feed delivers them one per line, a format called NDJSON.
> The file `ed_feed.ndjson` is one simulated day of an emergency department:
> 300 patients, each with vital signs taken at triage and every hour after.
> The Data page for this course describes every resource type and code in it.
>
> An `Observation` names what it measured by a LOINC code and holds the
> measurement in `valueQuantity`. The temperature observation below records
> 38.3 °C:
>
> ```json
> {"resourceType": "Observation", "id": "p001-obs-029",
>  "code": {"coding": [{"system": "http://loinc.org", "code": "8310-5"}]},
>  "subject": {"reference": "Patient/p001"},
>  "effectiveDateTime": "2027-03-01T21:53:00Z",
>  "valueQuantity": {"value": 38.3, "unit": "Cel"}}
> ```
>
> The systemic inflammatory response syndrome (SIRS) is an early warning
> sign of sepsis. Three of its four criteria are vital signs: a temperature
> above 38.0 °C or below 36.0 °C, a heart rate above 90 per minute, and a
> respiratory rate above 20 per minute. Emergency departments screen for
> two or more of them, because sepsis is treatable when it is caught early
> and often fatal when it is not.
>
> Write the five functions below.
>
> - `readFeed(path)` returns the resources of the file as a list of
>   dictionaries, one per line. Call `json.loads` on each line that is not
>   blank.
> - `latestVitals(feed, patientID)` returns a dictionary from LOINC code to
>   the patient's most recent value of that code. The times are written so
>   that comparing two of them as strings with `>` compares them as times.
> - `sirsCount(vitals)` returns how many of the three criteria a dictionary
>   from `latestVitals` meets. A code that is missing meets no criterion.
> - `flaggedPatients(feed)` returns the ids of the patients whose latest
>   vital signs meet two or more criteria, sorted.
> - `firstAlertHour(path)` replays the day with the `Feed` class in
>   `chickadee_fhir.py`. Start its clock at `"2027-03-01T00:00:00Z"`, advance
>   it one hour at a time, and keep every resource received so far. Return
>   the hour at which `flaggedPatients` first returns a patient, or -1 if no
>   patient is flagged within 24 hours.

The starter cells are the five stubs, each with the docstring of
`reference_solution.py` and `# Write your code here`, after a cell with
`import json` and `from chickadee_fhir import Feed`.

## The proposed tests

The families follow the shapes of Questions 1 to 3: an "is defined" case,
public cases on the student's own data, then release and secret edge cases.
Because the feed is shared, "your feed" cases use literal expected values,
which `reference_solution.py` prints.

| Family | Kind | Public | Release | Secret |
|---|---|---|---|---|
| `readFeed` | `boundary_equality` on `len(readFeed("ed_feed.ndjson"))` via a hand-written script | 6,580 resources | a file with a blank last line | — |
| `latestVitals` | `boundary_equality` | p001 on the feed: `{"8310-5": 38.3, "8867-4": 113, "59408-5": 94, "9279-1": 21}` | two observations of one code out of time order | a patient with no observations: `{}` |
| `sirsCount` | `boundary_equality` | 0, 1, 2 and 3 criteria | 38.0 exactly (not above) | a low temperature (35.8) |
| `flaggedPatients` | `unordered_equality` | the 20 ids on the feed | an empty feed | a patient flagged earlier but not on the latest values |
| `firstAlertHour` | `boundary_equality` | 3 on the feed | — | a feed with no positive patient: -1 |

The helper's own checks (`test_chickadee_fhir.py`) can run as a release-tier
script with 0 points, so a broken helper shows up in validation and not in a
student's grade.

## Before it goes into the live assignment

1. Add the feed to the HLTH 230 library on the Datasets tab, as FHIR NDJSON,
   with a provenance ("Generated by docs/examples/fhir/generate_ed_feed.py,
   seed 230") and a licence, and publish it. Write the descriptions of the
   four codes on its page.
2. Attach it to Assignment 3 as `ed_feed.ndjson`, add `chickadee_fhir.py` as
   a support file, add the question cells and the families, and run a
   validation on the worker.
3. Check the editor: a student cell that calls `readFeed("ed_feed.ndjson")`
   reads all 6,580 lines.
