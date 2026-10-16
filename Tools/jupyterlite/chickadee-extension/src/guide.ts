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

/** Where `task` goes in `cells`. */
export function placeTask(task: GuideTask, cells: CellInfo[], patterns: RegExp[]): Placement {
  const anchorCells = task.anchors.map(a => anchorCell(a, cells, patterns));
  const missing = task.anchors.filter((a, i) => anchorCells[i] === null && a.kind !== 'section').map(a => a.name);
  const found = anchorCells.filter((i): i is number => i !== null);
  const heading = task.heading
    ? cells.findIndex(c => c.type === 'markdown' && sectionHeading(c.source) === task.heading)
    : -1;
  // Above the `## ` heading; with no heading, above the first anchored cell.
  const headerCell = heading !== -1 ? heading : found.length ? Math.min(...found) : null;
  // Under the last anchored cell; with none found, under the heading.
  const checksCell = found.length ? Math.max(...found) : heading !== -1 ? heading : null;
  return { headerCell, checksCell, anchorCells, missing };
}

/**
 * The status a task shows: the server's (`pass`, `fail`, `fresh` or null),
 * or `starter` when every anchor cell still holds the student's starter.
 * `starter` wins over the attempt: the student has reset the cell.
 */
export function taskStatus(
  task: GuideTask,
  placement: Placement,
  cells: CellInfo[],
  starterSources: { [key: string]: string }
): string | null {
  const keyed = task.anchors.map((a, i) => ({ key: starterKey(a), cell: placement.anchorCells[i] }));
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
