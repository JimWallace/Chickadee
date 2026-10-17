// A small DOM for running a page script under `node:vm` without jsdom.
//
// Elements and the document are real `EventTarget`s from Node, so listeners,
// `dispatchEvent` and `preventDefault` behave as in a browser. Only the parts
// of the DOM that page scripts here use are modelled: attributes, a child
// tree, text, focus, and `querySelector` for `#id`, `tag`, `.class` and
// `tag[attr="value"]`. A selector outside that grammar throws, so a script
// that starts to depend on more fails loudly instead of matching nothing.

export class StubElement extends EventTarget {
  constructor(tagName, ownerDocument) {
    super();
    this.tagName = tagName.toUpperCase();
    this.ownerDocument = ownerDocument;
    this.attributes = new Map();
    this.children = [];
    this.parentNode = null;
    this.ownText = '';
  }

  get id() { return this.attributes.get('id') ?? ''; }
  set id(value) { this.attributes.set('id', String(value)); }
  get className() { return this.attributes.get('class') ?? ''; }
  set className(value) { this.attributes.set('class', String(value)); }

  setAttribute(name, value) { this.attributes.set(name, String(value)); }
  getAttribute(name) { return this.attributes.has(name) ? this.attributes.get(name) : null; }
  hasAttribute(name) { return this.attributes.has(name); }
  removeAttribute(name) { this.attributes.delete(name); }

  appendChild(child) {
    child.parentNode = this;
    this.children.push(child);
    return child;
  }

  get textContent() {
    return this.ownText + this.children.map(c => c.textContent).join('');
  }

  set textContent(value) {
    this.children = [];
    this.ownText = String(value);
  }

  focus() { this.ownerDocument.activeElement = this; }

  /** Every element below this one, depth first. */
  *descendants() {
    for (const child of this.children) {
      if (child instanceof StubElement) {
        yield child;
        yield* child.descendants();
      }
    }
  }

  querySelector(selector) {
    const matches = compileSelector(selector);
    for (const el of this.descendants()) if (matches(el)) return el;
    return null;
  }
}

class StubText {
  constructor(text) { this.textContent = text; }
}

export class StubDocument extends EventTarget {
  constructor() {
    super();
    this.head = new StubElement('head', this);
    this.body = new StubElement('body', this);
    this.activeElement = this.body;
    this.visibilityState = 'visible';
  }

  createElement(tagName) { return new StubElement(tagName, this); }
  createTextNode(text) { return new StubText(text); }

  querySelector(selector) {
    return this.head.querySelector(selector) ?? this.body.querySelector(selector);
  }

  /** Adds `<meta name content>` to the head. */
  addMeta(name, content) {
    const meta = this.createElement('meta');
    meta.setAttribute('name', name);
    meta.setAttribute('content', String(content));
    this.head.appendChild(meta);
    return meta;
  }
}

function compileSelector(selector) {
  let m;
  if ((m = selector.match(/^#([\w-]+)$/))) {
    return el => el.id === m[1];
  }
  if ((m = selector.match(/^\.([\w-]+)$/))) {
    return el => el.className.split(/\s+/).includes(m[1]);
  }
  if ((m = selector.match(/^([a-z][\w-]*)$/i))) {
    return el => el.tagName === m[1].toUpperCase();
  }
  if ((m = selector.match(/^([a-z][\w-]*)\[([\w-]+)="([^"]*)"\]$/i))) {
    return el => el.tagName === m[1].toUpperCase() && el.getAttribute(m[2]) === m[3];
  }
  throw new Error(`dom-stub: unsupported selector '${selector}'`);
}

/// A clock that page scripts read through `Date.now` and drive through
/// `setInterval` / `setTimeout`. Nothing runs until the test advances it.
export class FakeClock {
  constructor(start = 1_000_000) {
    this.now = start;
    this.timers = [];
    this.nextID = 1;
  }

  install(context) {
    const clock = this;
    const RealDate = Date;
    context.Date = class extends RealDate {
      static now() { return clock.now; }
    };
    context.setInterval = (fn, ms) => clock.add(fn, ms, true);
    context.setTimeout = (fn, ms) => clock.add(fn, ms, false);
    context.clearInterval = id => clock.cancel(id);
    context.clearTimeout = id => clock.cancel(id);
  }

  add(fn, ms, repeat) {
    const id = this.nextID++;
    this.timers.push({ id, fn, ms: Math.max(0, ms ?? 0), due: this.now + Math.max(0, ms ?? 0), repeat });
    return id;
  }

  cancel(id) { this.timers = this.timers.filter(t => t.id !== id); }

  get intervalCount() { return this.timers.filter(t => t.repeat).length; }

  /** Moves time forward, firing each due timer in order. */
  advance(ms) {
    const target = this.now + ms;
    for (;;) {
      const next = this.timers.filter(t => t.due <= target).sort((a, b) => a.due - b.due)[0];
      if (!next) break;
      this.now = next.due;
      if (next.repeat) next.due += Math.max(1, next.ms);
      else this.cancel(next.id);
      next.fn();
    }
    this.now = target;
  }

  /** Moves time forward WITHOUT firing timers: a backgrounded tab. */
  jump(ms) {
    this.now += ms;
    for (const t of this.timers) while (t.due <= this.now) t.due += Math.max(1, t.ms);
  }
}

/** Lets pending promise callbacks run. */
export function flushMicrotasks() {
  return new Promise(resolve => setImmediate(resolve));
}
