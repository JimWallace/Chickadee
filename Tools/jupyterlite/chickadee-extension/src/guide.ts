// The student guide (docs/notebook-guide.md) placed on the notebook: which
// cell each task's header sits above, which cell its checks line sits under,
// and the status each task shows (notebook views NB4, frame 18a).
//
// Pure, so `node --test` checks it with no browser. The plugin reads the
// cells, calls these functions, and draws what they return.

import { definedNames, sectionHeading } from './definitions.js';

export interface GuideAnchor {
  kind: string;
  name: string;
  /** True when a script test names several defined names and this one was
   * taken only because it comes first in the notebook: a helper the test
   * calls, such as `bmi` in a test of `bmi_category`, not the task's own cell. */
  ambiguous?: boolean | null;
}

export interface GuideCheck {
  name: string;
  kind: string;
  result?: string | null;
  detail?: string | null;
  hint?: string | null;
}

export interface GuideTask {
  sectionID?: string | null;
  heading?: string | null;
  label?: string | null;
  name: string;
  points: number;
  anchors: GuideAnchor[];
  status?: string | null;
  checks: GuideCheck[];
  hiddenCount: number;
}

export interface Guide {
  version: number;
  attempt?: { number: number; pending: boolean; url: string } | null;
  tasks: GuideTask[];
  starterSources: { [key: string]: string };
  reflections?: { label: string; tag: string }[];
}

/** One notebook cell, as the placement reads it. */
export interface CellInfo {
  type: string;
  source: string;
}

/** Where a task's UI goes, by cell index. */
export interface Placement {
  /** The cell the header sits above, or null to draw no header. */
  headerCell: number | null;
  /** The cell the checks line sits under, or null to draw none. */
  checksCell: number | null;
  /** The cell of each anchor, in the guide's order; null when not found. */
  anchorCells: (number | null)[];
  /** The anchor names the notebook no longer defines (a renamed function). */
  missing: string[];
  /** The markdown cell whose `## ` heading the task sits under, or null. */
  headingCell: number | null;
  /** What the task is called, in the editor and in the page's outline alike:
   * the notebook heading it sits under, else the suite's name for it. */
  title: string;
  /** The cells of the placing anchors that were found. */
  found: number[];
  /** The cell of the task's own `## ` heading, or null. */
  own: number | null;
}

/** Trailing whitespace on each line and at the end gone, CRLF as LF: the
 * normalization the server applies to `starterSources`. */
export function normalizedSource(source: string): string {
  const lines = source
    .replace(/\r\n/g, '\n')
    .split('\n')
    .map(line => line.replace(/[ \t]+$/, ''));
  while (lines.length && lines[lines.length - 1] === '') {
    lines.pop();
  }
  return lines.join('\n');
}

/** The key of an anchor in `starterSources`. */
export function starterKey(anchor: GuideAnchor): string {
  return anchor.kind === 'section' ? `section:${anchor.name}` : anchor.name;
}

/** The cell an anchor points at in `cells`, or null. */
export function anchorCell(anchor: GuideAnchor, cells: CellInfo[], patterns: RegExp[]): number | null {
  if (anchor.kind === 'section') {
    const heading = cells.findIndex(c => c.type === 'markdown' && sectionHeading(c.source) === anchor.name);
    if (heading === -1) {
      return null;
    }
    const code = cells.findIndex((c, i) => i > heading && c.type === 'code');
    return code === -1 ? null : code;
  }
  // The last definition wins, as on the server.
  for (let i = cells.length - 1; i >= 0; i--) {
    if (cells[i].type === 'code' && definedNames(cells[i].source, patterns).includes(anchor.name)) {
      return i;
    }
  }
  return null;
}

/**
 * The positions in `task.anchors` that place the task. An ambiguous anchor is
 * a helper that several tasks' tests call, so it would pull every one of their
 * headers up to the same cell. It counts only when the task has no other.
 */
export function placingAnchors(task: GuideTask): number[] {
  const all = task.anchors.map((_, i) => i);
  const firm = all.filter(i => !task.anchors[i].ambiguous);
  return firm.length ? firm : all;
}

/** The nearest markdown cell with a `## ` heading at or above `cell`, or null. */
export function headingAbove(cell: number, cells: CellInfo[]): number | null {
  for (let i = cell; i >= 0; i--) {
    if (cells[i].type === 'markdown' && sectionHeading(cells[i].source) !== null) {
      return i;
    }
  }
  return null;
}

/**
 * Where `task` goes in `cells`, on its own. `placeTasks` places a whole guide,
 * and settles two tasks that would take the same notebook heading.
 *
 * The task sits under a notebook heading: its own section name when the
 * notebook has that `## ` heading, else the nearest `## ` heading above its
 * first anchored cell. That heading is the task's title, so the outline, the
 * header and the notebook all say "Part 4: Write two small functions", not
 * one of those plus a suite name ("Other checks", "Question 1") the student
 * never sees in the notebook. A task placed only by a shared helper takes no
 * heading: the helper's heading belongs to another task.
 */
export function placeTask(task: GuideTask, cells: CellInfo[], patterns: RegExp[]): Placement {
  const anchorCells = task.anchors.map(a => anchorCell(a, cells, patterns));
  const missing = task.anchors.filter((a, i) => anchorCells[i] === null && a.kind !== 'section').map(a => a.name);
  const placing = placingAnchors(task);
  const found = placing.map(i => anchorCells[i]).filter((i): i is number => i !== null);
  const own = task.heading
    ? cells.findIndex(c => c.type === 'markdown' && sectionHeading(c.source) === task.heading)
    : -1;
  const firm = placing.every(i => !task.anchors[i].ambiguous);
  const headingCell = own !== -1 ? own : firm && found.length ? headingAbove(Math.min(...found), cells) : null;
  return layout(task, cells, anchorCells, missing, found, own !== -1 ? own : null, headingCell);
}

function layout(
  task: GuideTask,
  cells: CellInfo[],
  anchorCells: (number | null)[],
  missing: string[],
  found: number[],
  own: number | null,
  headingCell: number | null
): Placement {
  // Above the heading; with none, above the first anchored cell.
  const headerCell = headingCell ?? (found.length ? Math.min(...found) : null);
  // Under the last anchored cell; with none found, under its own heading.
  const checksCell = found.length ? Math.max(...found) : own;
  const title = (headingCell !== null ? sectionHeading(cells[headingCell].source) : null) ?? task.heading ?? task.name;
  return { headerCell, checksCell, anchorCells, missing, headingCell, title, found, own };
}

/**
 * Where each task in `tasks` goes. A notebook heading is one task's title.
 * A task's own heading is always its own. A heading found above the anchors
 * goes to the task whose first anchored cell comes first under it, in
 * notebook order, so the cells from the heading on belong to that task
 * (`taskOfCell`). Any other task that finds it sits above its own first
 * anchored cell, under the suite name.
 */
export function placeTasks(tasks: GuideTask[], cells: CellInfo[], patterns: RegExp[]): Placement[] {
  const placements = tasks.map(t => placeTask(t, cells, patterns));
  const owner = new Map<number, number>();
  placements.forEach((p, i) => {
    if (p.own !== null) {
      owner.set(p.own, i);
    }
  });
  const first = (p: Placement) => Math.min(...p.found);
  placements.forEach((p, i) => {
    if (p.headingCell === null || p.headingCell === p.own) {
      return;
    }
    const current = owner.get(p.headingCell);
    if (current === undefined) {
      owner.set(p.headingCell, i);
    } else if (placements[current].own !== p.headingCell && first(p) < first(placements[current])) {
      owner.set(p.headingCell, i);
    }
  });
  return placements.map((p, i) =>
    p.headingCell === null || owner.get(p.headingCell) === i
      ? p
      : layout(tasks[i], cells, p.anchorCells, p.missing, p.found, p.own, null)
  );
}

/**
 * The status a task shows: the server's (`pass`, `fail`, `fresh` or null),
 * or `starter` when every placing anchor cell still holds the student's
 * starter. `starter` wins over the attempt: the student has reset the cell.
 * A shared helper the task's tests call does not decide it: a finished `bmi`
 * does not make an untouched `is_obese` anything but the starter.
 */
export function taskStatus(
  task: GuideTask,
  placement: Placement,
  cells: CellInfo[],
  starterSources: { [key: string]: string }
): string | null {
  const keyed = placingAnchors(task).map(i => ({
    key: starterKey(task.anchors[i]),
    cell: placement.anchorCells[i]
  }));
  const comparable =
    keyed.length > 0 && keyed.every(({ key, cell }) => cell !== null && starterSources[key] !== undefined);
  if (
    comparable &&
    keyed.every(({ key, cell }) => normalizedSource(cells[cell as number].source) === starterSources[key])
  ) {
    return 'starter';
  }
  return task.status ?? null;
}

/** The status pill's text, or null for no pill. */
export function pillText(
  status: string | null,
  task: GuideTask,
  attempt: Guide['attempt'],
  editedSince: boolean
): string | null {
  const n = attempt?.number;
  const edited = editedSince ? ' · edited since' : '';
  switch (status) {
    case 'pass':
      return `Passed in attempt ${n}${edited}`;
    case 'fail': {
      const failed = task.checks.filter(c => c.result && c.result !== 'pass').length;
      return `${failed} ${failed === 1 ? 'check' : 'checks'} failed in attempt ${n}${edited}`;
    }
    case 'starter':
      return 'Still the starter code';
    case 'fresh':
      return 'Not submitted yet';
    default:
      return attempt?.pending ? `Attempt ${n} is being graded` : null;
  }
}

/** The glyph beside a status. Never the only carrier: text is always beside it. */
export function statusGlyph(status: string | null): string {
  switch (status) {
    case 'pass':
      return '✓';
    case 'fail':
      return '✗';
    case 'starter':
      return '!';
    default:
      return '○';
  }
}

/** The glyph for one check's result. */
export function resultGlyph(result: string | null | undefined): string {
  if (!result) {
    return '○';
  }
  return result === 'pass' ? '✓' : '✗';
}

/** "Checked in attempt 2", or "Checked when you submit" before an attempt and
 * while the cell is the starter. */
export function checksPrefix(status: string | null, attempt: Guide['attempt']): string {
  if (!attempt || attempt.pending || status === 'starter' || status === 'fresh') {
    return 'Checked when you submit';
  }
  return `Checked in attempt ${attempt.number}`;
}

/** Splits text on `inline code` spans: odd entries are code. */
export function inlineCodeParts(text: string): string[] {
  return text.split('`');
}

/** The task each cell belongs to: from a task's header cell to the next. */
export function taskOfCell(index: number, headers: { sectionID: string | null; cell: number }[]): string | null {
  let owner: string | null = null;
  let start = -1;
  for (const header of headers) {
    if (header.cell <= index && header.cell > start) {
      owner = header.sectionID;
      start = header.cell;
    }
  }
  return owner;
}

/** `written` when any cell with `tag` has text, else `empty`. */
export function reflectionStatus(tag: string, cells: { tags: string[]; source: string }[]): 'written' | 'empty' {
  return cells.some(c => c.tags.includes(tag) && c.source.trim() !== '') ? 'written' : 'empty';
}
