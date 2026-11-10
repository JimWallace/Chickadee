# Shared delivery of dataset files

Status:

| Step | State |
|---|---|
| 1. `shared`: a whole file is linked | **built** |
| 2. `perPart`: each partition part is stored once and linked | **built** |

## The problem

A file marked as a dataset reaches each student's editor working copy
(`jupyterlite/files/users/<id>/<setupID>/`) as a **real file of its own**,
written by `writeDatasetFiles` (`Services/NotebookWorkingCopyStore.swift`).
That holds even when every student receives the same bytes. A library dataset
given whole to every student (no sample, no transforms) is stored once per
student who opens the notebook, where an ordinary support file would be one
symlink to the shared extraction.

For HLTH 230 Assignment 0 the file is 11.5 KB, so the cost does not matter.
A later assignment that gives a 5 MB cohort file to 300 students would store
1.5 GB for one file.

## What is already true

- **Delivered files are already read-only to students.** The editor's write
  routes refuse every file in `StudentWorkspaceFiles.delivered`, datasets
  included (`WorkingCopyProtectedFiles`). This design does not change who may
  write what. It changes how the bytes are stored.
- **The editor's read route follows a link.** Support files are already links
  into `{testSetupsDirectory}shared/<setupID>/`. The directory listing marks a
  link `writable: false` (`JupyterLiteContentsRoutes.swift`), so a linked
  dataset would also show as read-only in the file browser. A real dataset
  file shows as writable today, although a save to it is refused.
- **The storage quota skips links** (`UserFolderUsage`), so a linked dataset
  costs the student nothing against the quota.
- **Grading does not read the working copy.** The worker job, the browser
  runner download and the student's "my rows" download each call
  `DatasetResolver.resolve` and receive bytes (`StudentDatasetDelivery`,
  `WorkerJobRoutes`, `BrowserRunnerRoutes`). Only the editor working copy
  stores a per-student file.

## The rule

> A student's file can be a link when the bytes do not depend on the student,
> or depend on them only through a value with few possible settings.

Classify each `DatasetSpec` into one of three delivery modes:

| Mode | When | Stored once per | Student's file |
|---|---|---|---|
| `shared` | not a partition, `sampleSize` is nil and `transforms` is empty | setup | a link to `shared/<setupID>/<file>` |
| `perPart` | `kind == .partition`, a part count above zero, and `transforms` is empty | setup, source and part | a link to that part's file |
| `perStudent` | everything else: a real sample, or any transform | student | a real file, as today |

The two cases that link are exactly the cases where a large file costs the
most: a whole file given to everyone, and a partition, whose parts together
are the whole file. A real sample or a transform is unique to each student,
but its size is the sample size, which the author chooses and which is small
by design, so a per-student copy stays cheap.

A partition student who holds no part yet (a class composite before the slot
is dealt, `DatasetDeals.withholdingUndealtParts`) receives the header row
only. That is one more shared file per partition: a link to the header file.

### Where the classification lives

`DatasetDeliveryMode` in `Sources/Core/Models/DatasetDeliveryMode.swift`, read
as `DatasetSpec.deliveryMode`. A transformed partition is `perStudent`,
because a transform varies the cells per student. So is a partition with no
part count, which authoring refuses and which the materializer would deliver
whole.

**Decision: only an empty sample size is `shared`.** A sample size at or above
the row count also gives the whole file, but it classifies as `perStudent`.
The rule then reads only the spec, never the file, and it is the safe
direction: a wrong `perStudent` costs storage, but a wrong `shared` would hand
one student's rows to every student. An author who wants the whole file
leaves the sample empty. `DatasetMaterializer` stays the one answer to what
the bytes are. The mode only decides whether they can be stored once.

## Storage

**`shared`.** The link target is the existing extraction,
`shared/<setupID>/<file>`. No new file is written.

**`perPart`.** Parts are written once (`DatasetPartStore`,
`Sources/APIServer/Utilities/`), to a directory that the setup-save wipe does
not touch:

```
{testSetupsDirectory}dataset-parts/<setupID>/<fingerprint>/header.csv
{testSetupsDirectory}dataset-parts/<setupID>/<fingerprint>/part-<k>.csv
```

- `fingerprint` hashes the whole spec (which names the file) and the source's
  modification time, size and file number. A setup save re-extracts the source
  as a new file, so an edit that kept the size and the time still gets a new
  fingerprint, and stored parts are never served stale. A fingerprint directory is never written again once it is
  published. A new source or a new `partCount` writes a new directory, so a
  link never points at a part that is being rewritten. A setup save
  re-extracts the source, which changes its modification time, so each save
  writes the parts once more.
- The parts come from `DatasetMaterializer.allParts`, which splits the file in
  one pass. `DatasetAllPartsTests` pins each part to what `materialize` gives
  that part, so the bytes are the ones grading uses.
- The whole directory is written under a temporary name (`.tmp-<uuid>`) and
  renamed into place. Two students who open at the same moment cannot read a
  half-written part. If two visits publish the same fingerprint at once, the
  second rename fails, and the second visit uses the first one's parts, which
  are the same bytes.
- Why not under `shared/<setupID>/`: `extractSupportFilesToSharedDirectory`
  removes that directory on every setup save. Parts kept there would vanish on
  each save, and `DatasetOverlayDirectory` would also link a parts directory
  into every personalization overlay, because it lists the shared directory.
- **The sweep** runs after each new publish. The first time it finds a
  directory that is not a current fingerprint of one of the setup's
  partitions, it writes a `.superseded` marker into it. It removes the
  directory once that marker is more than a day old
  (`DatasetPartStore.staleRetention`). Retention therefore starts when the
  parts stop being current, not when they were written, and a student linked
  to them has a day to revisit and be relinked. A directory that is current
  again loses its marker. A staging directory left by a failed write is
  removed a day after it was made. A student still linked to a removed part
  has a dangling link, and the next visit repairs it (see "Repair"). A deleted
  assignment's parts stay, as its `shared/<setupID>/` extraction does.
- `DiskUsage` counts `dataset-parts/<setupID>/` with the setup, beside
  `shared/` and `notebooks/`.

## The working-copy pass

`writeDatasetFiles` keeps its job and its fingerprint cache. For each dataset
it computes the mode, then:

| Mode | Action at `studentDir/<file>` |
|---|---|
| `shared` | make it a link to `shared/<setupID>/<file>` |
| `perPart` | make it a link to the student's part, or to `header.csv` while no part is dealt |
| `perStudent` | make it a real file holding the student's slice |

Where each file belongs is `DatasetLinkTargets.placement`
(`Sources/APIServer/Utilities/`): a link to a named path, a real file, or
`unavailable` when the source is not extracted yet. The writer places from it
and the skip check compares against it, so the two cannot disagree. A
partition student with no deal number outside a class composite would
receive the whole file, so that case links to the source. A source that is
not UTF-8 text is skipped, as `DatasetResolver` skips it.

"Make it" means replace whatever is there (`DatasetWorkingCopyPlacement`,
`Sources/APIServer/Utilities/`). Every transition is one step:

- real file to link, which is every existing working copy on the first visit
  after this ships;
- link to real file, when an author adds a sample;
- link to a different link, when a deal or a fingerprint changes.

**Safety: never write through a link.** A `perStudent` write must never open
the existing path for writing, because a write through a link would overwrite
the shared extraction or a part, and every student would receive one
student's rows. `DatasetWorkingCopyPlacement.write` removes a link at the path
before it writes, and `removeItem` removes a link without following it.
`DatasetWorkingCopyPlacementTests` pins that the shared copy keeps its bytes.

Replacing is remove-then-create, not one rename, so the file is missing for a
moment while it is replaced. Support files already behave this way on a setup
save. Two visits by the same student can race on a link: the loser succeeds
when the winner made the same link.

A `shared` file is never read by this pass. A partition's source is read
only when its fingerprint has no stored parts yet. Only the `perStudent`
specs go through `DatasetResolver`.

`linkSupportFiles` does not change. `StudentWorkspaceFiles.linkedSupportFiles`
still leaves datasets out, so the support-file pass never makes a link the
dataset pass did not choose.

**The fingerprint** already folds in the whole spec, and the mode is derived
from the spec, so a change of mode changes the fingerprint. The skip check
also asks whether each target is where `DatasetLinkTargets` places it
(`datasetTargetIsCurrent` in `NotebookWorkingCopyStore.swift`): a live link to
the right path, or a real file. The editor copy's fingerprint folds in the
deal number, and the part path folds in the parts fingerprint, so a new deal
or a new source moves the link. A working copy written before a change holds
the old form, so it is moved on the next visit even while the in-memory
fingerprint cache is warm.

## Repair

`writeDatasetFiles` already rewrites when a target is missing:
`targetsPresent` checks `FileManager.fileExists`, which follows a link, so a
dangling link counts as missing. That covers the three ways a link can break:
a setup save wipes `shared/<setupID>/` and re-extracts it, a parts sweep
removes an old fingerprint, or a new library version is attached. The next
notebook visit relinks.

Between a wipe and the re-extraction a linked dataset is briefly missing.
Support files already behave this way.

## What does not change

- Grading bytes: the worker, the browser runner and the "my rows" download.
- `WorkingCopyProtectedFiles`: datasets stay protected by name.
- `files.missing` (#2747): it asks `StudentWorkspaceFiles.delivered`, which is
  unchanged.
- Personalization overlays (`DatasetOverlayDirectory`): per evaluation and
  temporary. They could link the `shared` case as well, but the saving is
  small, so that is out of scope.
- The manifest: no new field. The mode is derived from the spec.

## Rollout

1. **`shared` only (built).** The `Core` classification, the link-or-file
   replace in `writeDatasetFiles`, the target check, the delivery note in the
   Files panel and `datasetDelivery` in MCP `get_support_files`, and the
   tests. This covers HLTH 230 Assignment 0 and every whole-file library
   attachment.
2. **`perPart` (built).** `DatasetPartStore` (the parts directory, its
   publish and its sweep), `DatasetLinkTargets`, `DatasetMaterializer.allParts`,
   `perPart` in `datasetDelivery`, and the tests. No HLTH 230 assignment uses
   a partition yet; it is to be tried later in the Winter 2027 term.

Each step is one PR with one `changelog.d/` fragment. Neither needs a
migration: the first visit after deploy turns each student's real copy into a
link.

## Tests

Step 1:

- `DatasetDeliveryModeTests` (`Core`, parameterized): the mode for each kind,
  with and without a sample, a partition and a transform; a sample at or above
  the row count stays `perStudent`; and a `shared` spec materializes to the
  source bytes for any seed, which is what makes a link correct.
- `DatasetSharedDeliveryTests` (APIServer): through `writeDatasetFiles`, a
  real file from before the change becomes a link, a sampled dataset beside it
  stays a real file, and a shared source the extraction lacks is not linked.
- `DatasetWorkingCopyPlacementTests` (APIServer), on a temporary directory:
  - a real file becomes a link;
  - a write over a link replaces the link, and **the shared source keeps its
    bytes** (the safety test);
  - a link to somewhere else is retargeted;
  - a dangling link is replaced;
  - linking twice is a no-op.

Step 2:

- `DatasetDeliveryModeTests` gains a partition (`perPart`), a transformed
  partition and a partition with no part count (both `perStudent`).
- `DatasetAllPartsTests` (`Core`, parameterized over files and part counts):
  each part from `allParts` equals `materialize` for that part and for a deal
  one round later.
- `DatasetPartStoreTests` (APIServer), on a temporary directory: the stored
  parts and header match the materializer; a published fingerprint is not
  written again; a new part count is a new directory with no staging left;
  retention starts when a sweep first marks a fingerprint superseded, not when
  it was written; a marked fingerprint goes once the mark is past retention
  while a current one stays; a fingerprint that is current again loses its
  mark; a missing source has no fingerprint.
- `DatasetPartDeliveryTests` (APIServer): through `writeDatasetFiles`, two
  students in a two-part partition each get a link into `dataset-parts/`, to
  different parts, holding exactly what `DatasetResolver` grades for their
  deal, and a real file from before the change becomes the link.

`docs/feature-interactions.md` has a row for `dataset-parts/`.

## Decisions

- **Only an empty sample size is `shared`** (see "Where the classification
  lives").
- **The listing shows the mode.** The Files panel shows "One shared copy." or
  "One copy per student." under each dataset except a partition, whose own
  note already says each student is dealt a part. The words live once, in
  `DatasetDeliveryNote`, and are sent on the datasets panel response
  (`deliveryNotes`) so the panel repaints it after every edit. MCP
  `get_support_files` reports `datasetDelivery`: `shared`, `perPart` or
  `perStudent`.
