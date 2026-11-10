# Shared delivery of dataset files

Status:

| Step | State |
|---|---|
| 1. `shared`: a whole file is linked | **built** |
| 2. `perPart`: each partition part is stored once and linked | proposed |

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
| `perPart` | `kind == .partition` and `transforms` is empty | setup and part | a link to that part's file |
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
as `DatasetSpec.deliveryMode`. Step 1 has two cases, `shared` and
`perStudent`; step 2 adds `perPart`, and until then a partition is
`perStudent`.

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

**`perPart`.** Parts are written once, to a directory that the setup-save wipe
does not touch:

```
{testSetupsDirectory}dataset-parts/<setupID>/<fingerprint>/<file>/header.csv
{testSetupsDirectory}dataset-parts/<setupID>/<fingerprint>/<file>/part-<k>.csv
```

- `fingerprint` hashes the source bytes and the spec, as
  `datasetMaterializationFingerprint` does today without the student's seeds.
  A fingerprint directory is immutable once written. A new source or a new
  `partCount` writes a new directory, so a link never points at a part that is
  being rewritten.
- Parts are written with `DatasetMaterializer.materialize` for each part
  number, so the bytes are the ones grading uses.
- Each part is written to a temporary name in the same directory and then
  renamed into place, so two students who open at the same moment cannot read
  a half-written part.
- Why not under `shared/<setupID>/`: `extractSupportFilesToSharedDirectory`
  removes that directory on every setup save. Parts kept there would vanish on
  each save, and `DatasetOverlayDirectory` would also link a parts directory
  into every personalization overlay, because it lists the shared directory.
- Old fingerprint directories are removed once no working copy links to them.
  The simplest safe policy is a sweep that keeps the current fingerprint and
  deletes any directory older than a day. A link to a removed part dangles,
  and the next visit repairs it (see "Repair").

## The working-copy pass

`writeDatasetFiles` keeps its job and its fingerprint cache. For each dataset
it computes the mode, then:

| Mode | Action at `studentDir/<file>` |
|---|---|
| `shared` | make it a link to `shared/<setupID>/<file>` |
| `perPart` | make it a link to the student's part, or to `header.csv` while no part is dealt |
| `perStudent` | make it a real file holding the student's slice |

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

A `shared` file is never read by this pass. Only the `perStudent` specs go
through `DatasetResolver`, so a large shared file costs a link and nothing
else.

`linkSupportFiles` does not change. `StudentWorkspaceFiles.linkedSupportFiles`
still leaves datasets out, so the support-file pass never makes a link the
dataset pass did not choose.

**The fingerprint** already folds in the whole spec, and the mode is derived
from the spec, so a change of mode changes the fingerprint. The skip check
also asks whether each target is in its mode's form (`datasetTargetIsCurrent`
in `NotebookWorkingCopyStore.swift`): a live link to the shared copy for
`shared`, a real file for `perStudent`. A working copy written before this
change holds a real file for a `shared` spec, so it is relinked on the next
visit even while the in-memory fingerprint cache is warm. Step 2 adds the part
number and the parts fingerprint.

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
2. **`perPart`.** The parts directory, its writer and its sweep.

Each step is one PR with one `changelog.d/` fragment. Step 1 needs no
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

Step 2 adds a row to `docs/feature-interactions.md` for `dataset-parts/`,
which is a new shared object.

## Decisions

- **Only an empty sample size is `shared`** (see "Where the classification
  lives").
- **The listing shows the mode.** The Files panel shows "One shared copy." or
  "One copy per student." under each dataset except a partition, whose own
  note already says each student is dealt a part. The words live once, in
  `DatasetDeliveryNote`, and are sent on the datasets panel response
  (`deliveryNotes`) so the panel repaints it after every edit. MCP
  `get_support_files` reports `datasetDelivery`: `shared` or `perStudent`.
