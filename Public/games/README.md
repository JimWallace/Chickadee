# Vendored games

Games that Chickadee serves as static files. Each one is a copy, not a
submodule, pinned to the commit named below. The server serves every file under
`Public/`, so each game is reachable at `/games/<name>/index.html`.

The repository guards (`scripts/check-styles.sh`, `scripts/eslint.sh` and the
rest) read only the top-level `Public/*.js` and `Public/styles.css`, so they do
not apply to the code here. It is not ours to restyle.

## quantum-cats

- Source: <https://github.com/iqc-scientific-outreach/quantum-cats>
- Commit: `6478c24` ("Update index.html")
- Licence: CC0 1.0 (`quantum-cats/LICENSE`)
- How it is found: the Konami code on any signed-in page
  (`Public/quantum-cats-egg.js`), which also grants the Quantum Cats ring
  (docs/student-wardrobe.md, "Found items").

The game runs under Chickadee's default Content-Security-Policy unchanged: its
scripts are files, its fonts are `data:` URLs, and it fetches only its own
files.

The copy leaves out the files that the game reads only when its bundled data is
missing:

- `levels.json` and `sprites.json`, which `data.js` carries
- every `snd/*.mp3` except `music.mp3`, since `sfx.js` carries the effects as base64
- `README.txt`, which is about unzipping the game
- one image that no file references

To update the copy, run the steps below from the repository root, with the
source cloned beside it. They copy the files the game needs and every image
that a file names. Then update the commit above.

```sh
cp ../quantum-cats/index.html ../quantum-cats/boot.js ../quantum-cats/data.js ../quantum-cats/game.js ../quantum-cats/physics.js ../quantum-cats/sfx.js ../quantum-cats/strings.js ../quantum-cats/ui.js ../quantum-cats/LICENSE Public/games/quantum-cats/
cp ../quantum-cats/snd/music.mp3 Public/games/quantum-cats/snd/
cat ../quantum-cats/*.js ../quantum-cats/index.html | grep -oE "img/[A-Za-z0-9_.-]+" | sort -u | xargs -I{} cp ../quantum-cats/{} Public/games/quantum-cats/{}
```
