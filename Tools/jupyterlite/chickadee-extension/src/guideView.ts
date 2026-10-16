// Draws the student guide on the open notebook (notebook views NB4, frame
// 18a): a task header above each task's `## ` heading and a checks line under
// its last anchored code cell. Both go into the cell's own header and footer
// widgets (`jp-CellHeader`, `jp-CellFooter`), which JupyterLab creates empty,
// so the notebook's cells, metadata and outputs are never touched.
//
// Performance (docs/browser-freeze-investigation.md): no layout is read, a
// redraw happens at most once per animation frame, an edit schedules one only
// after 500ms of quiet, and a redraw whose cells did not change touches no
// node. A run changes only outputs, so it redraws nothing.
//
// Every string from the payload goes in through textContent, never as HTML.

import { Notebook } from '@jupyterlab/notebook';
import { Cell } from '@jupyterlab/cells';
import { PanelLayout } from '@lumino/widgets';

import {
  CellInfo,
  Guide,
  GuideCheck,
  GuideTask,
  checksPrefix,
  inlineCodeParts,
  normalizedSource,
  pillText,
  placeTask,
  resultGlyph,
  starterKey,
  statusGlyph,
  taskOfCell,
  taskStatus
} from './guide.js';
import { post } from './events.js';

const MARK = 'ck-guide-node';
/** On a header or footer that holds a guide node. JupyterLab gives both a
 * zero height, so the stylesheet gives a host its natural height. */
const HOST = 'ck-guide-host';
const MAX_FAILURES_SHOWN = 2;

/** What a redraw worked out, for the page's outline and `ck:active-cell`. */
export interface DrawnTask {
  sectionID: string | null;
  status: string | null;
  headerCell: number | null;
}

export class GuideView {
  private guide: Guide | null = null;
  private patterns: RegExp[] = [];
  private frame = 0;
  private quiet: ReturnType<typeof setTimeout> | null = null;
  private drawn: DrawnTask[] = [];
  /** What the last redraw read, to skip a redraw that would change nothing. */
  private lastInput = '';
  private lastWidgets: readonly Cell[] = [];

  constructor(private readonly notebook: () => Notebook | null) {}

  setGuide(guide: Guide | null): void {
    this.guide = guide;
    this.lastInput = '';
    this.schedule();
  }

  setPatterns(patterns: RegExp[]): void {
    this.patterns = patterns;
    this.lastInput = '';
    this.schedule();
  }

  /** An edit: redraw after 500ms with no further edit. */
  edited(): void {
    if (this.quiet) {
      clearTimeout(this.quiet);
    }
    this.quiet = setTimeout(() => {
      this.quiet = null;
      this.schedule();
    }, 500);
  }

  /** The task that holds cell `index`, by the last redraw. */
  taskOf(index: number): string | null {
    const headers = this.drawn
      .filter((t): t is DrawnTask & { headerCell: number } => t.headerCell !== null)
      .map(t => ({ sectionID: t.sectionID, cell: t.headerCell }));
    return taskOfCell(index, headers);
  }

  /** At most one redraw per animation frame. */
  schedule(): void {
    if (this.frame) {
      return;
    }
    this.frame = requestAnimationFrame(() => {
      this.frame = 0;
      this.draw();
    });
  }

  private draw(): void {
    const notebook = this.notebook();
    if (!notebook) {
      return;
    }
    const widgets = notebook.widgets as readonly Cell[];
    const cells: CellInfo[] = widgets.map(c => ({
      type: c.model.type,
      source: c.model.sharedModel.getSource()
    }));
    const input = JSON.stringify(cells);
    const sameWidgets =
      widgets.length === this.lastWidgets.length && widgets.every((w, i) => w === this.lastWidgets[i]);
    if (sameWidgets && input === this.lastInput) {
      return;
    }
    this.lastInput = input;
    this.lastWidgets = [...widgets];
    for (const cell of widgets) {
      clear(cell);
    }
    const guide = this.guide;
    if (!guide) {
      this.drawn = [];
      return;
    }
    const editedSince = this.editedSince(guide, cells);
    this.drawn = guide.tasks.map((task, number) => {
      const placement = placeTask(task, cells, this.patterns);
      const status = taskStatus(task, placement, cells, guide.starterSources);
      const edited = editedSince.has(task.sectionID ?? '') && (status === 'pass' || status === 'fail');
      if (placement.headerCell !== null) {
        attach(
          header(widgets[placement.headerCell]),
          taskHeader(task, number, status, pillText(status, task, guide.attempt, edited))
        );
      }
      if (placement.checksCell !== null) {
        attach(footer(widgets[placement.checksCell]), checksLine(task, status, guide, placement.missing));
      }
      return {
        sectionID: task.sectionID ?? null,
        status,
        headerCell: placement.headerCell
      };
    });
    for (const cell of widgets) {
      if (isReflection(cell)) {
        attach(header(cell), reflectionHeader(cell.model.sharedModel.getSource()));
      }
    }
    post({
      ck: 'ck:tasks',
      tasks: this.drawn.map(t => ({
        sectionID: t.sectionID,
        status: t.status
      }))
    });
  }

  /**
   * The tasks whose anchor cells changed since the attempt. The sources are
   * taken the first time this browser sees the attempt, normally just after
   * the student submits it, and kept in localStorage per notebook and attempt.
   */
  private editedSince(guide: Guide, cells: CellInfo[]): Set<string> {
    const edited = new Set<string>();
    const attempt = guide.attempt;
    if (!attempt || attempt.pending) {
      return edited;
    }
    const current: { [key: string]: string } = {};
    for (const task of guide.tasks) {
      const placement = placeTask(task, cells, this.patterns);
      task.anchors.forEach((anchor, i) => {
        const cell = placement.anchorCells[i];
        if (cell !== null) {
          current[`${task.sectionID ?? ''}|${starterKey(anchor)}`] = normalizedSource(cells[cell].source);
        }
      });
    }
    const key = `ck-attempt-sources:${location.pathname}${location.search}:${attempt.number}`;
    let stored: { [key: string]: string } | null = null;
    try {
      const raw = localStorage.getItem(key);
      stored = raw ? JSON.parse(raw) : null;
      if (!stored) {
        localStorage.setItem(key, JSON.stringify(current));
        return edited;
      }
    } catch {
      return edited;
    }
    for (const [anchorKey, source] of Object.entries(current)) {
      if (stored[anchorKey] !== undefined && stored[anchorKey] !== source) {
        edited.add(anchorKey.split('|')[0]);
      }
    }
    return edited;
  }
}

// MARK: - Cell header and footer

function part(cell: Cell, className: string) {
  const layout = cell.layout as PanelLayout | null;
  return layout?.widgets.find(w => w.hasClass(className))?.node ?? null;
}

function header(cell: Cell): HTMLElement | null {
  return part(cell, 'jp-CellHeader');
}

function footer(cell: Cell): HTMLElement | null {
  return part(cell, 'jp-CellFooter');
}

function clear(cell: Cell): void {
  for (const host of [header(cell), footer(cell)]) {
    if (host?.classList.contains(HOST)) {
      host.querySelectorAll(`:scope > .${MARK}`).forEach(n => n.remove());
      host.classList.remove(HOST);
    }
  }
}

function attach(host: HTMLElement | null, node: HTMLElement): void {
  if (host) {
    host.classList.add(HOST);
    host.appendChild(node);
  }
}

function isReflection(cell: Cell): boolean {
  const tags = cell.model.getMetadata('tags');
  return Array.isArray(tags) && tags.includes('reflection');
}

// MARK: - Building the nodes

function el(tag: string, className: string, text?: string): HTMLElement {
  const node = document.createElement(tag);
  node.className = className;
  if (text !== undefined) {
    node.textContent = text;
  }
  return node;
}

/** `text` with its `inline code` spans as <code>. */
function withCode(className: string, text: string): HTMLElement {
  const node = el('span', className);
  inlineCodeParts(text).forEach((part, i) => {
    node.appendChild(i % 2 === 1 ? el('code', '', part) : document.createTextNode(part));
  });
  return node;
}

function taskHeader(task: GuideTask, number: number, status: string | null, pill: string | null): HTMLElement {
  const row = el('div', `${MARK} ck-task-header`);
  row.dataset.status = status ?? 'none';
  row.appendChild(el('span', 'ck-glyph', statusGlyph(status))).setAttribute('aria-hidden', 'true');
  row.appendChild(el('span', 'ck-task-label', task.label ?? `Task ${number + 1}`));
  row.appendChild(el('span', 'ck-task-points', `${task.points} ${task.points === 1 ? 'pt' : 'pts'}`));
  row.appendChild(el('span', 'ck-spacer'));
  if (pill) {
    row.appendChild(el('span', 'ck-pill', pill));
  }
  return row;
}

function reflectionHeader(source: string): HTMLElement {
  const empty = source.trim() === '';
  const row = el('div', `${MARK} ck-task-header`);
  row.dataset.status = empty ? 'none' : 'written';
  row.appendChild(el('span', 'ck-glyph', empty ? '○' : '✓')).setAttribute('aria-hidden', 'true');
  row.appendChild(el('span', 'ck-task-label', 'Reflection'));
  row.appendChild(el('span', 'ck-spacer'));
  row.appendChild(el('span', 'ck-pill', empty ? 'Empty' : 'Written'));
  return row;
}

function checksLine(task: GuideTask, status: string | null, guide: Guide, missing: string[]): HTMLElement {
  const box = el('div', `${MARK} ck-checks`);
  const line = el('div', 'ck-checks-line');
  box.appendChild(line);
  if (missing.length) {
    line.appendChild(withCode('ck-missing', `Can't find \`${missing.join('`, `')}\` in your notebook`));
    return box;
  }
  const showResults = status !== 'starter';
  line.appendChild(el('span', 'ck-checks-prefix', checksPrefix(status, guide.attempt)));
  for (const check of task.checks) {
    const result = showResults ? check.result : null;
    const chip = el('span', 'ck-chip');
    chip.dataset.result = result ?? 'none';
    chip.appendChild(el('span', 'ck-glyph', resultGlyph(result))).setAttribute('aria-hidden', 'true');
    chip.appendChild(el('span', check.kind === 'check' ? 'ck-chip-name' : 'ck-chip-name ck-mono', check.name));
    line.appendChild(chip);
  }
  if (task.hiddenCount > 0) {
    const n = task.hiddenCount;
    line.appendChild(el('span', 'ck-chip ck-chip-hidden', `• ${n} hidden ${n === 1 ? 'test' : 'tests'}`));
  }
  const failures = showResults ? task.checks.filter(c => c.result && c.result !== 'pass') : [];
  failures.slice(0, MAX_FAILURES_SHOWN).forEach(check => box.appendChild(failure(check, guide)));
  if (failures.length > MAX_FAILURES_SHOWN && guide.attempt) {
    const more = el('div', 'ck-more');
    more.appendChild(document.createTextNode(`and ${failures.length - MAX_FAILURES_SHOWN} more · `));
    const link = el('a', '', 'See results') as HTMLAnchorElement;
    link.href = guide.attempt.url;
    link.target = '_top';
    more.appendChild(link);
    box.appendChild(more);
  }
  return box;
}

function failure(check: GuideCheck, guide: Guide): HTMLElement {
  const box = el('div', 'ck-failure');
  const title = el('div', 'ck-failure-title');
  title.appendChild(el('code', '', check.name));
  title.appendChild(document.createTextNode(` failed in attempt ${guide.attempt?.number ?? ''}`));
  box.appendChild(title);
  if (check.detail) {
    box.appendChild(el('pre', 'ck-failure-detail', check.detail));
  }
  if (check.hint) {
    const hint = el('div', 'ck-hint');
    hint.appendChild(el('strong', '', 'Hint from your instructor: '));
    hint.appendChild(withCode('', check.hint));
    box.appendChild(hint);
  }
  return box;
}
