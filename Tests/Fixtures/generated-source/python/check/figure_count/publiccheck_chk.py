# Test: Check
# Generated from notebook check "chk" kind=figure_count spec_hash=038b5cd3cf3cbd13 — edit the check, not this file.

minimum = 1

try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
except Exception as ex:
    errored(f"matplotlib is not available in the grading environment: {ex}")

import test_runtime as _tr

# Plotting calls are side effects, which the extractor quarantines out
# of plain imports — so execute the notebook in main mode (with the Agg
# backend already selected above) and count charts as Jupyter renders
# them.  In a notebook each plt.show() flushes the current figure(s);
# under batch Agg execution show() is a no-op, so successive .plot()
# calls without plt.figure() would overlay one figure and undercount.
# Emulate the notebook: each show() counts the open figures and closes
# them; figures left open at the end (plt.figure() without show) count
# once more.
_shown_total = 0

def _counting_show(*args, **kwargs):
    global _shown_total
    _shown_total += len(plt.get_fignums())
    plt.close("all")

_real_show = plt.show
plt.show = _counting_show
try:
    _tr.student_main_state()
finally:
    plt.show = _real_show

figure_count = _shown_total + len(plt.get_fignums())

if figure_count < minimum:
    failed(
        f"Student notebook produced too few figures.\n"
        f"  expected at least: {minimum}\n"
        f"  got:               {figure_count}\n"
    )

passed(f"Student notebook produced {figure_count} figure(s) (minimum {minimum})")