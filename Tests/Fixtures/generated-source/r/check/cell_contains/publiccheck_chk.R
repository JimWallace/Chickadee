# Test: Check
# Generated from notebook check "chk" kind=cell_contains spec_hash=3933c523f64e655d — edit the check, not this file.
source("test_runtime.R")

needle <- ""

cells <- chickadee_student_cells()
matched <- cells[grepl(needle, cells, fixed = TRUE)]

if (length(matched) == 0L) {
    failed(paste0(
        "No code cell in your notebook matches `", needle, "`.\n",
        "  expected: at least one cell containing the pattern\n",
        "  searched: ", length(cells), " code cell(s)"))
}

# (no must-differ-from constraint)

passed(paste0("Found ", length(matched), " cell(s) containing `", needle, "`"))