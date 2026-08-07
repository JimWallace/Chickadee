% Test: Check
% Generated from notebook check [chk] spec_hash=038b5cd3cf3cbd13 — edit the check, not this file.
chickadee = test_runtime();

min_figures = 1;

student = chickadee.load_student();
figure_count = numel(findall(0, "type", "figure"));

if figure_count < min_figures
    chickadee.failed(["Your notebook produced " num2str(figure_count) " figure(s).\n" ...
        "  expected at least: " num2str(min_figures) " figure(s)\n" ...
        "  hint:     make sure your plotting cells actually run (plot, bar, hist, ...)"]);
end

chickadee.passed(["Produced " num2str(figure_count) " figure(s)"]);