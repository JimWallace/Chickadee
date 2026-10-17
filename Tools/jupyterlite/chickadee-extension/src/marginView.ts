// Draws the instructor's test cards beside the notebook (notebook views NB7,
// design frame 18c): a section card beside each `## ` heading, and the cards
// of the tests linked to a cell beside that cell. Under about 1100px of
// notebook width the margin folds into a strip under the cell, which opens
// into the same cards.
//
// The cards are UI the extension adds to each cell's node, so the notebook's
// cells, metadata and outputs never change. The extension never writes the
// suite: each action (Edit test, Run again, Pin to a cell, a section action,
// Add check) is posted to the workbench page, which owns the editors.
//
// Performance (docs/browser-freeze-investigation.md): a redraw happens at most
// once per animation frame, an edit schedules one after 500ms of quiet, and a
// redraw whose cells and suite did not change touches no node. Keeping a cell
// as tall as its cards takes one layout read per redraw, in the frame after.

import { Notebook } from '@jupyterlab/notebook';
import { Cell } from '@jupyterlab/cells';

import { CellInfo } from './guide.js';
import {
  CellMargin,
  Suite,
  SuiteItem,
  SuiteSection,
  findItem,
  issueText,
  marginKey,
  itemIssue,
  itemState,
  pinName,
  sectionMeta,
  sectionOf,
  stripSummary,
  placeSuite
} from './margin.js';
import { post } from './events.js';

const MARK = 'ck-margin';
/** Below this notebook width the margin folds into a strip under each cell. */
const FOLD_PX = 1100;

export class MarginView {
  private suite: Suite | null = null;
  private patterns: RegExp[] = [];
  private selected: string | null = null;
  private pinning: string | null = null;
  private frame = 0;
  private quiet: ReturnType<typeof setTimeout> | null = null;
  private lastInput = '';
  private lastWidgets: readonly Cell[] = [];
  private awaited = new WeakSet<Cell>();
  /** What each cell's cards were drawn from, so an unchanged cell is left. */
  private drawnKeys = new WeakMap<Cell, string>();
  /** Bumped when the suite, the patterns or the selection change. */
  private generation = 0;
  private observed: Element | null = null;
  private resize = new ResizeObserver(entries => {
    const width = entries[0]?.contentRect.width ?? 0;
    const fold = width > 0 && width < FOLD_PX;
    if (document.body.classList.contains('ck-margin-fold') !== fold) {
      document.body.classList.toggle('ck-margin-fold', fold);
      // The cards change layout: draw and measure them again.
      this.generation += 1;
      this.lastInput = '';
      this.schedule();
    }
  });

  constructor(private readonly notebook: () => Notebook | null) {}

  setSuite(suite: Suite | null): void {
    this.suite = suite;
    this.generation += 1;
    this.lastInput = '';
    this.schedule();
  }

  setPatterns(patterns: RegExp[]): void {
    this.patterns = patterns;
    this.generation += 1;
    this.lastInput = '';
    this.schedule();
  }

  /** Expands the card of the test with `id`, or none for null. */
  select(id: string | null): void {
    this.selected = id;
    this.generation += 1;
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

  /** The pick mode of Pin to a cell: the next click on a code cell pins the
   * test to the first name that cell defines. Escape leaves it. */
  private startPinning(id: string): void {
    this.pinning = id;
    document.body.classList.add('ck-pinning');
  }

  private stopPinning(): void {
    this.pinning = null;
    document.body.classList.remove('ck-pinning');
  }

  /** Called by the plugin for a click in the notebook, before JupyterLab
   * handles it. True when the click was taken by the pick mode. */
  pick(cell: Cell | null): boolean {
    if (!this.pinning) {
      return false;
    }
    const id = this.pinning;
    this.stopPinning();
    const anchor =
      cell && cell.model.type === 'code' ? pinName(cell.model.sharedModel.getSource(), this.patterns) : null;
    if (anchor) {
      post({ ck: 'ck:pin', itemID: id, anchor });
    } else {
      post({ ck: 'ck:pin-refused', itemID: id });
    }
    return true;
  }

  cancelPinning(): boolean {
    if (!this.pinning) {
      return false;
    }
    this.stopPinning();
    return true;
  }

  private draw(): void {
    const notebook = this.notebook();
    if (!notebook) {
      return;
    }
    if (this.observed !== notebook.node) {
      if (this.observed) {
        this.resize.unobserve(this.observed);
      }
      this.observed = notebook.node;
      this.resize.observe(notebook.node);
    }
    const widgets = notebook.widgets as readonly Cell[];
    const cells: CellInfo[] = widgets.map(c => ({ type: c.model.type, source: c.model.sharedModel.getSource() }));
    const input = JSON.stringify([cells, this.selected]);
    const sameWidgets =
      widgets.length === this.lastWidgets.length && widgets.every((w, i) => w === this.lastWidgets[i]);
    if (sameWidgets && input === this.lastInput) {
      return;
    }
    this.lastInput = input;
    this.lastWidgets = [...widgets];
    const suite = this.suite;
    document.body.classList.toggle('ck-margin-on', suite !== null);
    const margins = suite ? placeSuite(suite, cells, this.patterns) : new Map<number, CellMargin>();
    const selected = suite && this.selected ? findItem(suite, this.selected) : null;
    // Only a cell whose cards changed is drawn again, and measured again: a
    // whole redraw forced a layout of every cell each time a cell made its DOM.
    const changed: Cell[] = [];
    widgets.forEach((cell, index) => {
      const margin = margins.get(index) ?? null;
      // The selected test's cell is outlined when the test fails on the
      // solution; there is no line to point at.
      const failing = !!(
        margin &&
        selected &&
        margin.items.includes(selected) &&
        itemIssue(selected) === 'failsOnSolution'
      );
      const key = margin ? `${this.generation}|${marginKey(margin, this.selected)}|${failing}` : '';
      if ((this.drawnKeys.get(cell) ?? '') === key) {
        return;
      }
      if (margin && cell.node.childElementCount === 0) {
        // The cell has not made its DOM yet: draw when it has.
        this.lastInput = '';
        if (!this.awaited.has(cell)) {
          this.awaited.add(cell);
          void cell.ready.then(() => this.schedule());
        }
        return;
      }
      clear(cell);
      this.drawnKeys.set(cell, key);
      if (!margin || !suite) {
        return;
      }
      cell.node.classList.add('ck-has-margin');
      cell.node.appendChild(this.marginNode(margin, suite));
      if (failing) {
        cell.node.classList.add('ck-cell-failing');
      }
      changed.push(cell);
    });
    if (changed.length > 0) {
      requestAnimationFrame(() => this.keepCellsTall(changed));
    }
  }

  /** One layout read per redraw, of the cells drawn: a cell is at least as
   * tall as its cards. */
  private keepCellsTall(widgets: readonly Cell[]): void {
    if (document.body.classList.contains('ck-margin-fold')) {
      return;
    }
    const heights = widgets.map(cell => {
      const margin = cell.node.querySelector<HTMLElement>(`:scope > .${MARK}`);
      return margin ? margin.offsetHeight : 0;
    });
    widgets.forEach((cell, i) => {
      cell.node.style.minHeight = heights[i] > 0 ? `${heights[i]}px` : '';
    });
  }

  // MARK: - Building the nodes

  private marginNode(margin: CellMargin, suite: Suite): HTMLElement {
    const box = el('div', MARK);
    if (margin.items.length > 0) {
      // Folded, a cell with tests shows a strip that opens into its cards.
      box.dataset.items = 'true';
      box.appendChild(this.strip(margin, box));
    }
    const cards = el('div', 'ck-cards');
    box.appendChild(cards);
    if (margin.section) {
      cards.appendChild(sectionCard(margin.section));
    }
    if (margin.items.length > 0) {
      if (margin.linkedBy.length > 0) {
        const linked = el('div', 'ck-linked');
        linked.appendChild(document.createTextNode('Linked by '));
        margin.linkedBy.forEach((name, i) => {
          if (i > 0) {
            linked.appendChild(document.createTextNode(', '));
          }
          linked.appendChild(el('code', '', name));
        });
        cards.appendChild(linked);
      }
      for (const item of margin.items) {
        cards.appendChild(this.card(item));
      }
      const section = sectionOf(suite, margin.items[0].id);
      const add = button('ck-add', '+ Add check for this cell');
      add.addEventListener('click', () =>
        post({ ck: 'ck:add-check', sectionID: section?.id ?? null, anchor: margin.linkedBy[0] ?? null })
      );
      cards.appendChild(add);
    }
    return box;
  }

  /** The folded strip: glyph, "3 checks · 3 pts", "1 fails on the solution",
   * "Linked by …" and ▸. It opens into the cards. */
  private strip(margin: CellMargin, box: HTMLElement): HTMLElement {
    const strip = button('ck-strip', '');
    const failing = margin.items.some(item => itemIssue(item) === 'failsOnSolution');
    const states = margin.items.map(itemState);
    strip.dataset.status = failing
      ? 'fail'
      : states.includes('starter')
        ? 'starter'
        : states.every(state => state === 'pass')
          ? 'pass'
          : 'none';
    strip.setAttribute('aria-expanded', 'false');
    strip.appendChild(glyphNode(strip.dataset.status));
    for (const part of stripSummary(margin.items)) {
      strip.appendChild(el('span', 'ck-strip-part', part));
    }
    if (margin.linkedBy.length > 0) {
      strip.appendChild(el('span', 'ck-strip-part', `Linked by ${margin.linkedBy.join(', ')}`));
    }
    strip.appendChild(el('span', 'ck-strip-toggle', '▸')).setAttribute('aria-hidden', 'true');
    strip.addEventListener('click', () => {
      const open = box.dataset.open !== 'true';
      box.dataset.open = open ? 'true' : 'false';
      strip.setAttribute('aria-expanded', open ? 'true' : 'false');
    });
    return strip;
  }

  private card(item: SuiteItem): HTMLElement {
    const state = itemState(item);
    const issue = itemIssue(item);
    const selected = item.id === this.selected;
    const card = el('div', 'ck-card');
    card.dataset.status = state;
    card.dataset.itemId = item.id;
    if (selected) {
      card.dataset.selected = 'true';
    }
    const head = button('ck-card-head', '');
    head.setAttribute('aria-expanded', selected ? 'true' : 'false');
    head.appendChild(glyphNode(state));
    head.appendChild(el('code', 'ck-card-name', item.name));
    head.appendChild(el('span', 'ck-card-points', `${item.points} ${item.points === 1 ? 'pt' : 'pts'}`));
    head.addEventListener('click', () => {
      this.select(selected ? null : item.id);
      post({ ck: 'ck:item-selected', itemID: selected ? null : item.id });
    });
    card.appendChild(head);
    card.appendChild(el('div', 'ck-card-meta', `${item.checkKind ?? item.kind} · ${item.tier}`));
    if (issue) {
      const line = el('div', 'ck-issue', issueText(issue));
      line.dataset.issue = issue;
      card.appendChild(line);
    }
    if (selected) {
      card.appendChild(this.details(item));
    }
    return card;
  }

  private details(item: SuiteItem): HTMLElement {
    const box = el('div', 'ck-card-details');
    if (item.source) {
      box.appendChild(el('pre', 'ck-source', item.source));
    }
    const detail = item.solution?.detail;
    if (detail) {
      box.appendChild(el('pre', 'ck-failure-detail', detail));
    }
    const actions = el('div', 'ck-actions');
    const edit = button('ck-action', 'Edit test');
    edit.addEventListener('click', () => post({ ck: 'ck:edit-test', itemID: item.id }));
    actions.appendChild(edit);
    const run = button('ck-action', 'Run again');
    run.addEventListener('click', () => post({ ck: 'ck:run-again', itemID: item.id }));
    actions.appendChild(run);
    if (item.kind === 'script') {
      const pin = button('ck-action', this.pinning === item.id ? PICK_TEXT : 'Pin to a cell');
      pin.addEventListener('click', () => {
        this.startPinning(item.id);
        pin.textContent = PICK_TEXT;
      });
      actions.appendChild(pin);
    }
    box.appendChild(actions);
    return box;
  }
}

// MARK: - Helpers

/** The pin button's text while the pick mode is on. */
const PICK_TEXT = 'Click a code cell · Esc cancels';

/** A `<details>` menu closes on a click outside it and on Escape. The
 * listeners go when the menu leaves the document. */
function closeOnOutsideOrEscape(menu: HTMLDetailsElement): void {
  const controller = new AbortController();
  const close = (): void => {
    if (!menu.isConnected) {
      controller.abort();
    } else if (menu.open) {
      menu.open = false;
    }
  };
  document.addEventListener(
    'click',
    event => {
      if (!menu.contains(event.target as Node)) {
        close();
      }
    },
    { signal: controller.signal }
  );
  document.addEventListener(
    'keydown',
    event => {
      if (event.key === 'Escape') {
        close();
      }
    },
    { signal: controller.signal }
  );
}

function clear(cell: Cell): void {
  if (!cell.node.classList.contains('ck-has-margin') && !cell.node.classList.contains('ck-cell-failing')) {
    return;
  }
  cell.node.querySelectorAll(`:scope > .${MARK}`).forEach(n => n.remove());
  cell.node.classList.remove('ck-has-margin', 'ck-cell-failing');
  cell.node.style.minHeight = '';
}

function el(tag: string, className: string, text?: string): HTMLElement {
  const node = document.createElement(tag);
  node.className = className;
  if (text !== undefined) {
    node.textContent = text;
  }
  return node;
}

function button(className: string, text: string): HTMLButtonElement {
  const node = el('button', className, text) as HTMLButtonElement;
  node.type = 'button';
  return node;
}

function glyphNode(state: string): HTMLElement {
  const node = el(
    'span',
    'ck-glyph',
    state === 'pass' ? '✓' : state === 'fail' ? '✗' : state === 'starter' ? '!' : '○'
  );
  node.dataset.status = state;
  node.setAttribute('aria-hidden', 'true');
  return node;
}

function sectionCard(section: SuiteSection): HTMLElement {
  const card = el('div', 'ck-section-card');
  card.appendChild(el('span', 'ck-task-label', section.label ?? section.title ?? 'Other checks'));
  card.appendChild(el('span', 'ck-task-points', sectionMeta(section)));
  card.appendChild(el('span', 'ck-spacer'));
  const menu = el('details', 'ck-section-menu');
  const summary = el('summary', 'ck-section-menu-button', '⋯');
  summary.setAttribute('aria-label', `Actions for ${section.label ?? section.title ?? 'this section'}`);
  menu.appendChild(summary);
  const list = el('div', 'ck-section-menu-list');
  for (const [action, label] of [
    ['rename', 'Rename'],
    ['add-check', 'Add check'],
    ['delete', 'Delete']
  ]) {
    const item = button('ck-section-menu-item', label);
    item.addEventListener('click', () => {
      (menu as HTMLDetailsElement).open = false;
      post({ ck: 'ck:section-action', sectionID: section.id ?? null, action });
    });
    list.appendChild(item);
  }
  menu.appendChild(list);
  card.appendChild(menu);
  closeOnOutsideOrEscape(menu as HTMLDetailsElement);
  return card;
}
