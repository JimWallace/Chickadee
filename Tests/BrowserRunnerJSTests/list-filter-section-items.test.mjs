// Public/list-filter.js on the student dashboard's mixed-content section table
// (.section-items): five tracks, a hidden thead, no sorter loaded, and rows of
// three shapes — graded, material, and a one-cell heading row.
//
// The filter must match the Name cell (title + details line) and the Status
// cell, and nothing else: the tile and Actions cells hold labels ("Open … in a
// new tab") that are not data a reader sees as content.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

const source = await fs.readFile(path.resolve('Public/list-filter.js'), 'utf8');

function element(tag) {
  const el = {
    tagName: tag.toUpperCase(), className: '', textContent: '', hidden: false, attrs: {},
    children: [], parentNode: null, nextSibling: null,
    setAttribute(name, value) { this.attrs[name] = String(value); },
    getAttribute(name) { return name in this.attrs ? this.attrs[name] : null; },
    hasAttribute(name) { return name in this.attrs; },
    removeAttribute(name) { delete this.attrs[name]; },
    appendChild(child) { this.children.push(child); child.parentNode = this; return child; },
    insertBefore(child) { this.children.push(child); child.parentNode = this; return child; },
    addEventListener() {},
    querySelector() { return null; },
    closest() { return null; },
  };
  const classes = () => new Set(el.className.split(/\s+/).filter(Boolean));
  el.classList = {
    add(name) { const set = classes(); set.add(name); el.className = [...set].join(' '); },
    remove(name) { const set = classes(); set.delete(name); el.className = [...set].join(' '); },
    contains(name) { return classes().has(name); },
  };
  return el;
}

function cell(text) {
  const td = element('td');
  td.textContent = text;
  return td;
}

function row(...texts) {
  const tr = element('tr');
  tr.cells = texts.map(cell);
  tr.textContent = texts.join(' ');
  return tr;
}

const graded = (title, details, status) =>
  row('', `${title} ${details}`, status, '87%', 'Edit Upload');
const material = (title, details) =>
  row('', `${title} ${details}`, '', '', 'Open lecture-08.pdf in a new tab (3.1 MB)');
const heading = (title) => row(title);

function load(rows) {
  const tbody = element('tbody');
  tbody.querySelectorAll = () => rows;
  tbody.querySelector = (sel) => {
    const match = /^tr\.(.+)$/.exec(sel);
    return match ? rows.find((r) => r.classList.contains(match[1])) || null : null;
  };
  // Tile, Name, Status, Grade, Actions — only Name and Status declare keys.
  const headers = [null, 'name', 'status', null, null].map((key) => {
    const th = element('th');
    if (key !== null) th.setAttribute('data-sort-key', key);
    return th;
  });
  const table = element('table');
  table.querySelector = (sel) => (sel === 'tbody' ? tbody : null);
  table.querySelectorAll = (sel) => (sel === 'thead th' ? headers : []);
  element('div').appendChild(table);
  const sandbox = {
    document: {
      readyState: 'complete',
      getElementById: (id) => (id === 'assignments-0' ? table : null),
      querySelectorAll: () => [],
      addEventListener() {},
      createElement: (tag) => element(tag),
    },
    module: { exports: {} },
    WeakMap,
  };
  sandbox.self = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(source, sandbox);
  return sandbox.module.exports;
}

function input(value) {
  const box = element('input');
  box.value = value;
  box.setAttribute('data-list-filter', 'assignments-0');
  element('span').appendChild(box);
  return box;
}

function fixture() {
  return [
    heading('Week 1'),
    material('Lecture 8', 'SLIDES · Updated Sep 3 · lecture-08.pdf, 3.1 MB'),
    graded('Lab 3', 'Due in 2 days · 2 submissions', 'open'),
    graded('Lab 2', 'Due last week', 'closed'),
    material('Reading', 'DOCUMENT · Chapter 4 exercises'),
  ];
}

const visible = (rows) => rows.filter((r) => !r.hidden).map((r) => r.cells[1]?.textContent ?? r.cells[0].textContent);

test('filter matches a material by its details line', () => {
  const rows = fixture();
  load(rows).apply(input('chapter 4'));
  assert.deepEqual(visible(rows), ['Reading DOCUMENT · Chapter 4 exercises']);
});

test('filter matches graded and material rows by title together', () => {
  const rows = fixture();
  load(rows).apply(input('lab'));
  assert.equal(rows.filter((r) => !r.hidden).length, 2);
});

test('filter matches the Status cell', () => {
  const rows = fixture();
  load(rows).apply(input('closed'));
  assert.deepEqual(visible(rows), ['Lab 2 Due last week']);
});

test('the Actions cell is not searched', () => {
  const rows = fixture();
  load(rows).apply(input('new tab'));
  assert.equal(rows.every((r) => r.hidden), true);
});

test('a heading row has no searchable cell and hides while a filter is active', () => {
  const rows = fixture();
  const filter = load(rows);
  const box = input('lab');
  filter.apply(box);
  assert.equal(rows[0].hidden, true);
  box.value = '';
  filter.apply(box);
  assert.equal(rows.every((r) => !r.hidden), true);
});

test('the last visible row carries the border mark across mixed rows', () => {
  const rows = fixture();
  load(rows).apply(input('lab'));
  const marked = rows.filter((r) => r.classList.contains('row-last-visible'));
  assert.deepEqual(marked, [rows[3]]);
});
