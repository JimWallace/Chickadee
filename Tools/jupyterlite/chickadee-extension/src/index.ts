// @chickadee/jupyterlite-extension: Chickadee's part of the embedded editor
// (notebook views brief, NB2).
//
// - Two themes, "Chickadee" and "Chickadee dark", on top of JupyterLab's own
//   light and dark themes. The variable map is style/index.css.
// - Commands the notebook page calls through the jupyter-iframe-commands
//   bridge: chickadee:set-theme, chickadee:configure, chickadee:set-guide,
//   chickadee:set-suite and chickadee:reveal.
// - Events it posts up to the page: ck:kernel, ck:active-cell, ck:cell-ran
//   (events.ts).
//
// It writes nothing into a notebook: no cell source, metadata or output. It
// reads no layout, so it adds no reflow to the editor.

import { JupyterFrontEnd, JupyterFrontEndPlugin } from '@jupyterlab/application';
import { IThemeManager } from '@jupyterlab/apputils';
import { INotebookTracker, Notebook, NotebookActions, NotebookPanel } from '@jupyterlab/notebook';

import { compilePatterns, definedNames, sectionHeading } from './definitions.js';
import { kernelState, post } from './events.js';
import { Guide } from './guide.js';
import { GuideView } from './guideView.js';

const LIGHT = 'Chickadee';
const DARK = 'Chickadee dark';

/** The two Chickadee themes. The body attribute selects the variable block. */
const themePlugin: JupyterFrontEndPlugin<void> = {
  id: '@chickadee/jupyterlite-extension:theme',
  description: 'The Chickadee light and dark editor themes.',
  autoStart: true,
  requires: [IThemeManager],
  activate: (_app: JupyterFrontEnd, manager: IThemeManager) => {
    const register = (name: string, isLight: boolean, base: string) => {
      manager.register({
        name,
        displayName: name,
        isLight,
        themeScrollbars: false,
        load: () => {
          document.body.dataset.ckTheme = isLight ? 'light' : 'dark';
          return manager.loadCSS(base);
        },
        unload: () => {
          delete document.body.dataset.ckTheme;
          return Promise.resolve(undefined);
        }
      });
    };
    register(LIGHT, true, '@jupyterlab/theme-light-extension/index.css');
    register(DARK, false, '@jupyterlab/theme-dark-extension/index.css');
  }
};

/** What the page has told the extension so far. NB4 and NB7 render from it. */
class PageState {
  patterns: RegExp[] = [];
  suite: unknown = null;
  constructor(readonly view: GuideView) {}
}

/** The bridge commands and the events. */
const bridgePlugin: JupyterFrontEndPlugin<void> = {
  id: '@chickadee/jupyterlite-extension:bridge',
  description: 'The commands the notebook page calls, and the events it reads.',
  autoStart: true,
  requires: [INotebookTracker, IThemeManager],
  activate: (app: JupyterFrontEnd, tracker: INotebookTracker, manager: IThemeManager) => {
    const state = new PageState(new GuideView(() => tracker.currentWidget?.content ?? null));

    app.commands.addCommand('chickadee:set-theme', {
      label: 'Set the Chickadee theme',
      execute: async args => {
        const theme = args['theme'] === 'dark' ? DARK : LIGHT;
        if (manager.theme !== theme) {
          await manager.setTheme(theme);
        }
      }
    });

    app.commands.addCommand('chickadee:configure', {
      label: 'Configure the Chickadee extension',
      execute: args => {
        const patterns = args['patterns'];
        state.patterns = Array.isArray(patterns)
          ? compilePatterns(patterns.filter((p): p is string => typeof p === 'string'))
          : [];
        state.view.setPatterns(state.patterns);
        postActiveCell(tracker, state);
      }
    });

    app.commands.addCommand('chickadee:set-guide', {
      label: 'Set the student guide',
      execute: args => {
        const guide = args['guide'];
        state.view.setGuide(isGuide(guide) ? guide : null);
      }
    });

    app.commands.addCommand('chickadee:set-suite', {
      label: 'Set the instructor suite',
      execute: args => {
        state.suite = args['suite'] ?? null;
      }
    });

    app.commands.addCommand('chickadee:reveal', {
      label: 'Reveal a cell',
      execute: async args => {
        const notebook = tracker.currentWidget?.content;
        if (!notebook) {
          return false;
        }
        const index = findCell(notebook, args, state.patterns);
        if (index === null) {
          return false;
        }
        notebook.activeCellIndex = index;
        const cell = notebook.widgets[index];
        if (cell) {
          await notebook.scrollToCell(cell, 'center');
        }
        return true;
      }
    });

    hideNotebookChrome(app, tracker);
    watchKernel(tracker);
    watchSaves(tracker);
    watchEdits(tracker, state.view);
    tracker.activeCellChanged.connect(() => postActiveCell(tracker, state));
    NotebookActions.executed.connect((_, { cell, success }) => {
      post({ ck: 'ck:cell-ran', cellId: cell.model.id, status: success ? 'ok' : 'error' });
    });
  }
};

/**
 * One toolbar: the page draws it, so the editor's own chrome goes. The top
 * area is hidden by a settings override (`@jupyter-notebook/application-
 * extension:top`), and the notebook toolbar's items by another. Notebook 7
 * has no setting for the menu bar or for the toolbar strip itself, so both
 * are hidden here through the shell and the panel. Keyboard shortcuts stay.
 *
 * The override keeps two items, `executionProgress` and `kernelName`: the
 * strip is hidden, but jl-kernel-diagnostics.js reads the kernel state from
 * the execution indicator's `data-status`, so it must stay in the DOM.
 */
function hideNotebookChrome(app: JupyterFrontEnd, tracker: INotebookTracker): void {
  void app.restored.then(() => {
    const menu = (app.shell as unknown as { menu?: { setHidden(hidden: boolean): void } }).menu;
    menu?.setHidden(true);
  });
  const hideToolbar = (panel: NotebookPanel) => panel.toolbar.setHidden(true);
  tracker.forEach(hideToolbar);
  tracker.widgetAdded.connect((_, panel) => hideToolbar(panel));
}

/** Posts ck:kernel for the current notebook's session, now and on each change. */
function watchKernel(tracker: INotebookTracker): void {
  let watched: NotebookPanel | null = null;
  const report = (panel: NotebookPanel) => {
    post({ ck: 'ck:kernel', status: kernelState(panel.sessionContext.kernelDisplayStatus) });
  };
  const onStatus = () => {
    if (watched) {
      report(watched);
    }
  };
  const follow = (panel: NotebookPanel | null) => {
    if (watched) {
      watched.sessionContext.statusChanged.disconnect(onStatus);
      watched.sessionContext.connectionStatusChanged.disconnect(onStatus);
    }
    watched = panel;
    if (panel) {
      panel.sessionContext.statusChanged.connect(onStatus);
      panel.sessionContext.connectionStatusChanged.connect(onStatus);
      report(panel);
    }
  };
  tracker.currentChanged.connect((_, panel) => follow(panel));
  follow(tracker.currentWidget);
}

/** Posts ck:saved as each notebook's document saves: started, completed or failed. */
function watchSaves(tracker: INotebookTracker): void {
  const watch = (panel: NotebookPanel) => {
    panel.context.saveState.connect((_, state) => post({ ck: 'ck:saved', state }));
  };
  tracker.forEach(watch);
  tracker.widgetAdded.connect((_, panel) => watch(panel));
}

/** An edit or a cell added, moved or removed redraws the guide, after quiet. */
function watchEdits(tracker: INotebookTracker, view: GuideView): void {
  const watch = (panel: NotebookPanel) => {
    const connect = () => panel.model?.contentChanged.connect(() => view.edited());
    if (panel.model) {
      connect();
    } else {
      void panel.context.ready.then(connect);
    }
  };
  tracker.forEach(watch);
  tracker.widgetAdded.connect((_, panel) => watch(panel));
  tracker.currentChanged.connect(() => view.schedule());
}

/** The payload's shape, checked once at the door. */
function isGuide(value: unknown): value is Guide {
  const guide = value as Guide | null;
  return !!guide && typeof guide === 'object' && Array.isArray(guide.tasks) && typeof guide.starterSources === 'object';
}

function postActiveCell(tracker: INotebookTracker, state: PageState): void {
  const notebook = tracker.currentWidget?.content;
  const cell = tracker.activeCell;
  if (!notebook || !cell) {
    return;
  }
  const names = cell.model.type === 'code' ? definedNames(cell.model.sharedModel.getSource(), state.patterns) : [];
  const index = notebook.activeCellIndex;
  post({ ck: 'ck:active-cell', cellId: cell.model.id, index, names, task: state.view.taskOf(index) });
}

/**
 * The index of the cell that `args` names: by `cellId`, by `index`, by a
 * defined `name` (the last definition wins, as on the server), or by a
 * `section` heading (the first code cell after it). Null when none matches.
 */
function findCell(notebook: Notebook, args: { [key: string]: unknown }, patterns: RegExp[]): number | null {
  const cells = notebook.widgets;
  const cellId = args['cellId'];
  if (typeof cellId === 'string') {
    const index = cells.findIndex(c => c.model.id === cellId);
    return index === -1 ? null : index;
  }
  const index = args['index'];
  if (typeof index === 'number') {
    return index >= 0 && index < cells.length ? index : null;
  }
  const name = args['name'];
  if (typeof name === 'string') {
    for (let i = cells.length - 1; i >= 0; i--) {
      const model = cells[i].model;
      if (model.type === 'code' && definedNames(model.sharedModel.getSource(), patterns).includes(name)) {
        return i;
      }
    }
    return null;
  }
  const tag = args['tag'];
  if (typeof tag === 'string') {
    const index = cells.findIndex(c => {
      const tags = c.model.getMetadata('tags');
      return Array.isArray(tags) && tags.includes(tag);
    });
    return index === -1 ? null : index;
  }
  const section = args['section'];
  if (typeof section === 'string') {
    const heading = cells.findIndex(
      c => c.model.type === 'markdown' && sectionHeading(c.model.sharedModel.getSource()) === section
    );
    if (heading === -1) {
      return null;
    }
    const code = cells.findIndex((c, i) => i > heading && c.model.type === 'code');
    return code === -1 ? heading : code;
  }
  return null;
}

export default [themePlugin, bridgePlugin];
