"""Read a FHIR NDJSON file as if it were a FHIR server, with a simulated clock.

This module is a support file of an assignment (docs/fhir-datasets-plan.md
§8(c)). It reads the attached file and nothing else: no network, no current
time, no randomness. A search or a clock step is a pure function of the file
and the arguments, so the same call gives the same answer in the editor, on
the native grader and in the browser grader.

    from chickadee_fhir import Feed

    feed = Feed("ed_feed.ndjson")
    page = feed.search("Observation", code="8310-5", _count=50)
    while page:
        for observation in page.resources:
            ...
        page = page.next()

    feed.clock.start_at("2027-03-01T08:00:00Z")
    arrivals = feed.clock.advance(minutes=15)

Standard library only, Python 3.10 or later.
"""

from __future__ import annotations

import datetime as _dt
import json as _json

__all__ = ["Feed", "Page", "Clock", "reference_id", "coding_code", "quantity_value", "resource_time"]

# Where each resource type records its time. A type not listed has none and
# is visible from the start of the clock.
_TIME_FIELDS = {
    "Observation": ("effectiveDateTime", "issued"),
    "Encounter": ("period.start",),
    "Condition": ("onsetDateTime", "recordedDate"),
    "Procedure": ("performedDateTime", "performedPeriod.start"),
    "MedicationAdministration": ("effectiveDateTime", "effectivePeriod.start"),
}


def _parse_time(text: str) -> _dt.datetime:
    """A FHIR dateTime as an aware datetime. A date alone is midnight UTC."""
    if len(text) == 10:
        text += "T00:00:00Z"
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    moment = _dt.datetime.fromisoformat(text)
    return moment if moment.tzinfo else moment.replace(tzinfo=_dt.timezone.utc)


def _path(resource: dict, dotted: str):
    value = resource
    for key in dotted.split("."):
        if not isinstance(value, dict) or key not in value:
            return None
        value = value[key]
    return value


def resource_time(resource: dict) -> _dt.datetime | None:
    """The time a resource records, or None for a type with no time field."""
    for field in _TIME_FIELDS.get(resource.get("resourceType"), ()):
        value = _path(resource, field)
        if isinstance(value, str):
            return _parse_time(value)
    return None


def reference_id(reference: dict | None) -> str | None:
    """The id in a reference such as {"reference": "Patient/p001"}: "p001"."""
    if not reference or "reference" not in reference:
        return None
    return reference["reference"].split("/")[-1]


def coding_code(resource: dict, system: str | None = None) -> str | None:
    """The first code in the resource's `code`, from `system` when given."""
    for coding in (resource.get("code") or {}).get("coding", []):
        if system is None or coding.get("system") == system:
            return coding.get("code")
    return None


def quantity_value(resource: dict) -> float | None:
    """The number in the resource's valueQuantity, or None."""
    quantity = resource.get("valueQuantity")
    return quantity.get("value") if isinstance(quantity, dict) else None


class Page:
    """One page of search results, with a link to the next."""

    def __init__(self, matches: list[dict], start: int, count: int):
        self._matches = matches
        self._start = start
        self._count = count
        self.resources = matches[start : start + count]
        self.total = len(matches)

    def next(self) -> "Page | None":
        """The next page, or None after the last one."""
        start = self._start + self._count
        return Page(self._matches, start, self._count) if start < len(self._matches) else None

    def __bool__(self) -> bool:
        return bool(self.resources)

    def __len__(self) -> int:
        return len(self.resources)

    def __iter__(self):
        return iter(self.resources)


class Clock:
    """A simulated clock over the feed. It never reads the current time.

    `advance` returns the resources whose time falls after the clock's time
    and at or before the new time, in file order, and moves the clock. A
    resource with no time arrives on the first `advance`.
    """

    def __init__(self, feed: "Feed"):
        self._feed = feed
        self.now: _dt.datetime | None = None
        self._sent_timeless = False

    def start_at(self, when: str) -> None:
        """Set the clock to `when`, a FHIR dateTime such as "2027-03-01T08:00:00Z"."""
        self.now = _parse_time(when)
        self._sent_timeless = False

    def advance(self, minutes: int = 0, hours: int = 0) -> list[dict]:
        """Move the clock forward and return what arrived in that interval."""
        if self.now is None:
            raise RuntimeError("Call clock.start_at(...) before clock.advance(...).")
        if minutes < 0 or hours < 0:
            raise ValueError("The clock only moves forward.")
        start = self.now
        end = start + _dt.timedelta(minutes=minutes, hours=hours)
        arrived = []
        for resource in self._feed.resources:
            moment = resource_time(resource)
            if moment is None:
                if not self._sent_timeless:
                    arrived.append(resource)
            elif start < moment <= end:
                arrived.append(resource)
        self._sent_timeless = True
        self.now = end
        return arrived


class Feed:
    """The resources of one FHIR NDJSON file, searchable by type and field."""

    def __init__(self, path: str):
        with open(path, encoding="utf-8") as handle:
            self.resources = [_json.loads(text) for text in handle if text.strip()]
        self._by_key = {(r["resourceType"], r["id"]): r for r in self.resources}
        self.clock = Clock(self)

    def get(self, resource_type: str, resource_id: str) -> dict | None:
        """The resource `resource_type`/`resource_id`, or None."""
        return self._by_key.get((resource_type, resource_id))

    def search(
        self, resource_type: str, *, code: str | None = None, patient: str | None = None, _count: int = 50
    ) -> Page:
        """Resources of `resource_type`, in file order, a page of `_count` at a time.

        `code` matches any coding's code in the resource's `code`. `patient`
        matches the id in `subject` or `patient`, with or without "Patient/".
        """
        if _count < 1:
            raise ValueError("_count must be 1 or more.")
        wanted_patient = patient.split("/")[-1] if patient else None
        matches = []
        for resource in self.resources:
            if resource.get("resourceType") != resource_type:
                continue
            if code is not None and code not in [c.get("code") for c in (resource.get("code") or {}).get("coding", [])]:
                continue
            if wanted_patient is not None:
                owner = reference_id(resource.get("subject")) or reference_id(resource.get("patient"))
                if owner != wanted_patient:
                    continue
            matches.append(resource)
        return Page(matches, 0, _count)
