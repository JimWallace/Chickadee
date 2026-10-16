// The names a code cell defines, read with the definition patterns the host
// page passes in (`chickadee:configure`). The server derives those patterns
// from `LanguageDescriptor` (Sources/Core/LanguageDescriptor.swift), so this
// file holds no language facts of its own. Each pattern matches one line, and
// its capture group 1 is the defined name.
//
// Pure, so `node --test` can check it with no browser.

/** Compiles the patterns once. A pattern that does not compile is dropped. */
export function compilePatterns(patterns: readonly string[]): RegExp[] {
  const compiled: RegExp[] = [];
  for (const pattern of patterns) {
    try {
      compiled.push(new RegExp(pattern));
    } catch {
      // A pattern this engine cannot read names nothing.
    }
  }
  return compiled;
}

/**
 * The names `source` defines at the top level, each once, in order. A name
 * that starts with `_` is private, as in the server's scan.
 */
export function definedNames(source: string, patterns: readonly RegExp[]): string[] {
  const names: string[] = [];
  for (const line of source.split('\n')) {
    for (const pattern of patterns) {
      const match = pattern.exec(line);
      const name = match?.[1];
      if (name && !name.startsWith('_') && !names.includes(name)) {
        names.push(name);
        break;
      }
    }
  }
  return names;
}

/** The first `## ` heading in a markdown cell, as the server reads sections. */
export function sectionHeading(source: string): string | null {
  for (const line of source.split('\n')) {
    const trimmed = line.trim();
    if (trimmed.startsWith('## ')) {
      const title = trimmed.slice(3).trim();
      if (title) {
        return title;
      }
    }
  }
  return null;
}
