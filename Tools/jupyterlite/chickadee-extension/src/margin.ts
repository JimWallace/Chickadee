// The instructor's suite placed on the notebook (notebook views NB7, design
// frame 18c): which cell each section's card sits beside, and which cell each
// test's card sits beside. The suite is the outline the workbench fetches
// (docs/notebook-guide.md, "The instructor's suite outline").
//
// Pure, so `node --test` checks it with no browser. marginView.ts reads the
// cells, calls these functions, and draws what they return.

import { definedNames, sectionHeading } from './definitions.js';
import { CellInfo, anchorCell } from './guide.js';

export interface SuiteAnchor {
  kind: string;
  name: string;
  source: string;
  ambiguous: boolean;
}

export interface SuiteResult {
  result: string;
  detail?: string | null;
}

export interface SuiteItem {
  id: string;
  name: string;
  kind: string;
  checkKind?: string | null;
  tier: string;
  points: number;
  anchor?: SuiteAnchor | null;
  solution?: SuiteResult | null;
  starter?: SuiteResult | null;
  source?: string | null;
}

export interface SuiteSection {
  id?: string | null;
  title?: string | null;
  label?: string | null;
  points: number;
  items: SuiteItem[];
}

export interface Suite {
  version: number;
  sections: SuiteSection[];
  unlinked: SuiteItem[];
}

/** What sits beside one cell. */
export interface CellMargin {
  /** The section whose `## ` heading this cell is. */
  section: SuiteSection | null;
  /** The tests linked to this cell, in suite order. */
  items: SuiteItem[];
  /** The names the tests link by, each once. */
  linkedBy: string[];
}

/** Each cell's margin, by cell index. A cell with nothing beside it is absent. */
export function placeSuite(suite: Suite, cells: CellInfo[], patterns: RegExp[]): Map<number, CellMargin> {
  const margins = new Map<number, CellMargin>();
  const at = (index: number): CellMargin => {
    let margin = margins.get(index);
    if (!margin) {
      margin = { section: null, items: [], linkedBy: [] };
      margins.set(index, margin);
    }
    return margin;
  };
  for (const section of suite.sections) {
    if (section.title) {
      const heading = cells.findIndex(c => c.type === 'markdown' && sectionHeading(c.source) === section.title);
      if (heading !== -1) {
        at(heading).section = section;
      }
    }
    for (const item of section.items) {
      const anchor = item.anchor;
      if (!anchor) {
        continue;
      }
      const index = anchorCell(
        { kind: anchor.kind === 'section' ? 'section' : 'name', name: anchor.name },
        cells,
        patterns
      );
      if (index === null) {
        continue;
      }
      const margin = at(index);
      margin.items.push(item);
      if (anchor.kind !== 'section' && !margin.linkedBy.includes(anchor.name)) {
        margin.linkedBy.push(anchor.name);
      }
    }
  }
  return margins;
}

/** The issue a test raises, if any: it fails on the solution (red), or it
 * passes on the starter and earns points for no work (amber). */
export function itemIssue(item: SuiteItem): 'failsOnSolution' | 'passesOnStarter' | null {
  const solution = item.solution?.result;
  if (solution && solution !== 'pass') {
    return 'failsOnSolution';
  }
  if (item.starter?.result === 'pass' && item.points > 0) {
    return 'passesOnStarter';
  }
  return null;
}

export function issueText(issue: 'failsOnSolution' | 'passesOnStarter'): string {
  return issue === 'failsOnSolution'
    ? 'Fails on the solution'
    : 'Passes on the starter too, so it earns its point with no work';
}

/** The state of a test's glyph: its result on the solution, or `starter`
 * when the starter passes it too for points (NB8). */
export function itemState(item: SuiteItem): 'pass' | 'fail' | 'starter' | 'none' {
  const result = item.solution?.result;
  if (!result) {
    return 'none';
  }
  if (result !== 'pass') {
    return 'fail';
  }
  return itemIssue(item) === 'passesOnStarter' ? 'starter' : 'pass';
}

/** "3 pts · 3 checks" for a section card. */
export function sectionMeta(section: SuiteSection): string {
  const n = section.items.length;
  return `${section.points} ${section.points === 1 ? 'pt' : 'pts'} · ${n} ${n === 1 ? 'check' : 'checks'}`;
}

/** The folded strip's summary: "3 checks · 3 pts", then "1 fails on the
 * solution" and "1 passes on the starter" when any does. */
export function stripSummary(items: SuiteItem[]): string[] {
  const points = items.reduce((sum, item) => sum + item.points, 0);
  const parts = [
    `${items.length} ${items.length === 1 ? 'check' : 'checks'} · ${points} ${points === 1 ? 'pt' : 'pts'}`
  ];
  const failing = items.filter(item => itemIssue(item) === 'failsOnSolution').length;
  if (failing > 0) {
    parts.push(`${failing} ${failing === 1 ? 'fails' : 'fail'} on the solution`);
  }
  const free = items.filter(item => itemIssue(item) === 'passesOnStarter').length;
  if (free > 0) {
    parts.push(`${free} ${free === 1 ? 'passes' : 'pass'} on the starter`);
  }
  return parts;
}

/** The name a code cell is pinned by: the first name it defines, or null. */
export function pinName(source: string, patterns: RegExp[]): string | null {
  return definedNames(source, patterns)[0] ?? null;
}

/** The test with `id`, wherever it is in the suite. */
export function findItem(suite: Suite, id: string): SuiteItem | null {
  for (const section of suite.sections) {
    const found = section.items.find(item => item.id === id);
    if (found) {
      return found;
    }
  }
  return suite.unlinked.find(item => item.id === id) ?? null;
}

/** The section that holds the test with `id`, or null. */
export function sectionOf(suite: Suite, id: string): SuiteSection | null {
  return suite.sections.find(section => section.items.some(item => item.id === id)) ?? null;
}

/** What a cell's cards are drawn from, as a string: equal strings draw the
 * same cards. */
export function marginKey(margin: CellMargin, selected: string | null): string {
  return JSON.stringify([
    margin.section?.id ?? null,
    margin.items.map(item => item.id),
    margin.linkedBy,
    margin.items.some(item => item.id === selected) ? selected : null
  ]);
}
