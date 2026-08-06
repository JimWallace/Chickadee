# Test: Check
# Generated from notebook check "chk" kind=figure_count spec_hash=038b5cd3cf3cbd13 — edit the check, not this file.
source("test_runtime.R")

minimum <- 1

# `plot.new` fires once per high-level plot (hist, plot, barplot) and
# never for a low-level addition (lines, points, abline), so this counts
# charts rather than drawing operations.  `grid.newpage` is the same
# signal for grid-based graphics, so lattice and a printed ggplot object
# count too where a course has installed them.  Both must be armed
# before the submission runs.
#
# A ggplot object only draws when it is printed — assigning it to a
# variable and never printing it produces no figure, in a notebook or
# here.  Base graphics draw as a side effect and always count.
.ck_figures <- 0L
setHook("plot.new",     function(...) .ck_figures <<- .ck_figures + 1L)
setHook("grid.newpage", function(...) .ck_figures <<- .ck_figures + 1L)

student <- chickadee_load_student()

figure_count <- .ck_figures
if (figure_count < minimum) {
    failed(paste0(
        "Your notebook produced too few figures.\n",
        "  expected at least: ", minimum, "\n",
        "  got:               ", figure_count))
}

passed(paste0("Your notebook produced ", figure_count, " figure(s) (minimum ", minimum, ")"))