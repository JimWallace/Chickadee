% test_runtime.m — Chickadee Octave test helper library.
% Obtain at the top of each Octave test script:
%     chickadee = test_runtime();
%
% API (a struct of function handles — Octave's one-function-per-file rule
% means separate helpers would each need their own file, and the runner
% injects exactly one; a handle struct is the idiomatic single-file namespace):
%   chickadee.passed(message)        — exit 0  (pass)
%   chickadee.failed(message)        — exit 1  (fail)
%   chickadee.errored(message)       — exit 2  (error)
%   chickadee.label()                — the test's name, from program_name()
%   chickadee.seed()                 — deterministic per-student integer seed
%   chickadee.inputs()               — per-student inputs from _ck_inputs.m
%   chickadee.student_file()         — the submitted .m file to grade
%   chickadee.load_student()         — that file, loaded; returns an env struct
%   chickadee.require_fn(env, name)  — a function the student had to write
%   chickadee.has_var(env, name)     — is a workspace variable defined?
%   chickadee.get_var(env, name)     — that variable's value
%   chickadee.student_cells()        — submission split into notebook cells
%   chickadee.format(value)          — one-line rendering, for failure messages
%   chickadee.equal(a, b)            — value equality (see below)
%   chickadee.unordered_equal(a, b)  — same elements, any order
%
% No package dependencies: JSON is hand-formatted, so this works on a bare
% `octave-cli` install and inside the xeus-octave kernel alike.
%
% WHAT MAKES THIS FILE WORK IN BOTH RUNNERS. The native runner spawns
% `octave-cli publictest_foo.m`, so the contract is a PROCESS contract:
% exit() sets the status, program_name() names the script, getenv reads the
% environment. A xeus-octave kernel has none of those — there is no process to
% exit. The browser wrapper (Public/octave-grading-shared.js) re-creates the
% contract inside one session by masking `exit`/`quit` and `program_name`
% (command-line functions shadow builtins) before any script runs. This file
% resolves all three by NAME at call time, so the masks are what its helpers
% reach and the canonical copy stays byte-identical across both runners. Do
% not replace exit() with a return-based protocol: under `octave-cli` that
% would exit 0 for a failing test.
%
% THE SUBMISSION CONTRACT (the function-file/script-file question, decided):
% a submission is loaded by evaluating its text prefixed with `1;`, which
% forces Octave to read it as a SCRIPT whatever its first token is. That one
% rule covers all three shapes a student can hand in:
%   * a flattened notebook (statements + `function` definitions in any order),
%   * a hand-written script,
%   * a traditional one-function-per-file submission — the `1;` prefix stops
%     Octave treating the FILE as the function, so the definition registers
%     under its own name (`function r = classify(x)` defines `classify`
%     whatever the file is called, where file-based resolution would have
%     bound it to the filename).
% Functions defined this way are command-line functions (exist() == 103),
% fetched with str2func by require_fn. Variables land in the loader's private
% workspace and are captured into the returned env struct. A runtime error
% mid-file keeps everything defined before it, matching the R runtime's
% expression-by-expression tolerance for the common shape (working functions
% above, a stray failing call below); definitions after the error are lost,
% which R's loader would have kept — a smaller promise, stated honestly.

function M = test_runtime()
    M = struct( ...
        "passed", @ck_passed, ...
        "failed", @ck_failed, ...
        "errored", @ck_errored, ...
        "label", @ck_label, ...
        "seed", @ck_seed, ...
        "inputs", @ck_inputs, ...
        "student_file", @ck_student_file, ...
        "load_student", @ck_load_student, ...
        "require_fn", @ck_require_fn, ...
        "has_var", @ck_has_var, ...
        "get_var", @ck_get_var, ...
        "student_cells", @ck_student_cells, ...
        "format", @ck_format, ...
        "equal", @ck_equal, ...
        "unordered_equal", @ck_unordered_equal);
end

function s = ck_json_str(value)
    s = num2str(value);
    if ischar(value)
        s = value;
    end
    s = strrep(s, "\\", "\\\\");
    s = strrep(s, "\"", "\\\"");
    s = strrep(s, sprintf("\n"), "\\n");
    s = strrep(s, sprintf("\r"), "\\r");
    s = strrep(s, sprintf("\t"), "\\t");
    s = ["\"" s "\""];
end

% The test's name, as the grader labels it: the script filename without its
% directory or extension. program_name() is what `octave-cli script.m`
% populates and what the browser wrapper masks, so both runners answer the
% same thing.
function name = ck_label()
    path = program_name();
    [~, stem, ~] = fileparts(path);
    if isempty(stem)
        name = "test";
    else
        name = stem;
    end
end

% The script currently executing, with its extension — never mistakable for
% the student's submission.
function name = ck_running_script()
    path = program_name();
    [~, stem, ext] = fileparts(path);
    name = [stem ext];
end

function ck_emit(status, short_result, err)
    parts = { ...
        ["\"status\":" ck_json_str(status)], ...
        ["\"shortResult\":" ck_json_str(short_result)], ...
        ["\"test\":" ck_json_str(ck_label())]};
    if nargin >= 3 && !isempty(err)
        parts{end + 1} = ["\"error\":" ck_json_str(err)];
    end
    printf("{%s}\n", strjoin(parts, ","));
end

function ck_passed(message)
    if nargin < 1 || isempty(message)
        message = [ck_label() ": passed"];
    end
    ck_emit("pass", message);
    exit(0);
end

function ck_failed(message)
    if nargin < 1 || isempty(message)
        message = "failed";
    end
    ck_emit("fail", [ck_label() ": " message], message);
    exit(1);
end

function ck_errored(message)
    if nargin < 1 || isempty(message)
        message = "error";
    end
    ck_emit("error", [ck_label() ": " message], message);
    exit(2);
end

% --- Value formatting + comparison ------------------------------------------
% Used by generated pattern-family tests (and available to hand-authored ones)
% so failure messages read the same whatever produced them.

% One-line, student-readable rendering — the Octave analogue of Python's
% repr(). mat2str handles numeric/logical/char matrices; cells are shown one
% level deep; a containers.Map shows its keys. Anything deeper or unprintable
% is elided rather than recursed, so a cyclic struct cannot hang the grader.
function s = ck_format(value, max_chars)
    if nargin < 2
        max_chars = 300;
    end
    s = ck_format_value(value);
    if numel(s) > max_chars
        s = [s(1:max_chars) " ..."];
    end
end

function s = ck_format_value(value)
    if ischar(value)
        s = ["\"" value "\""];
    elseif isa(value, "containers.Map")
        keys_list = value.keys();
        parts = cell(1, numel(keys_list));
        for i = 1:numel(keys_list)
            parts{i} = [keys_list{i} ": " ck_format_scalar(value(keys_list{i}))];
        end
        s = ["{" strjoin(parts, ", ") "}"];
    elseif iscell(value)
        parts = cell(1, numel(value));
        for i = 1:numel(value)
            parts{i} = ck_format_scalar(value{i});
        end
        s = ["{" strjoin(parts, ", ") "}"];
    elseif isnumeric(value) || islogical(value)
        s = mat2str(value);
    elseif isstruct(value)
        s = ["<struct with fields: " strjoin(fieldnames(value)', ", ") ">"];
    elseif is_function_handle(value)
        s = func2str(value);
    else
        s = ["<" class(value) ">"];
    end
end

function s = ck_format_scalar(value)
    if iscell(value) || isstruct(value)
        s = "{...}";
    else
        s = ck_format_value(value);
    end
end

% Value equality for generated tests. Built on isequaln — NOT isequal or a
% string rendering — for three measured reasons:
%   * a JSON null renders as NA (NaN-flavoured), and isequal(NA, NA) is
%     false; isequaln treats missing-vs-missing as equal, which is what an
%     authored [60, null, 20] case needs;
%   * isequaln is type-blind across logical/int/double (isequal(1, true) and
%     isequal(int32(1), 1.0) are both true), which matches how Octave's own
%     `==` treats those values and what a student can observe;
%   * it recurses into cells and containers.Map by content.
% On top of isequaln, two Chickadee rules:
%   * both-empty is equal whatever the container class: the literal renderer
%     spells an empty JSON array `{}` (nothing says what it would have held),
%     while a student computing an empty result usually produces `[]` — and
%     `""` is the same absence in char form. isequal([], {}) is false, so
%     without this rule every empty-expected case would fail on container
%     kind, a distinction the assignment's JSON never drew.
%   * numeric/logical values with equal element counts compare shape-blind
%     (a(:) vs b(:)): the renderer emits JSON arrays as row vectors, while
%     student arithmetic freely produces columns. R's `==`-with-all() does
%     the same via recycling, so the two languages agree.
function r = ck_equal(actual, expected)
    if isempty(actual) && isempty(expected)
        r = true;
        return;
    end
    numeric_like = @(v) (isnumeric(v) || islogical(v)) && !isa(v, "containers.Map");
    if numeric_like(actual) && numeric_like(expected)
        r = numel(actual) == numel(expected) && isequaln(actual(:), expected(:));
        return;
    end
    if iscell(actual) && iscell(expected)
        if numel(actual) != numel(expected)
            r = false;
            return;
        end
        for i = 1:numel(actual)
            if !ck_equal(actual{i}, expected{i})
                r = false;
                return;
            end
        end
        r = true;
        return;
    end
    r = isequaln(actual, expected);
end

% Order-insensitive comparison for the unordered_equality kind: the two
% collections hold the same elements in any order. Defined by greedy pairwise
% ck_equal — so it can NEVER disagree with `equal`, because it IS `equal`
% applied pairwise (the F3 lesson from the Lua audit: a second, weaker notion
% of equality beside the real one disagreed with it in both directions).
% Numeric vectors and cell arrays are both accepted; each is viewed as a list
% of elements first.
function r = ck_unordered_equal(actual, expected)
    a = ck_as_element_list(actual);
    b = ck_as_element_list(expected);
    if isempty(a) || isempty(b)
        r = isempty(a) && isempty(b);
        return;
    end
    if numel(a) != numel(b)
        r = false;
        return;
    end
    used = false(1, numel(b));
    for i = 1:numel(a)
        matched = false;
        for j = 1:numel(b)
            if !used(j) && ck_equal(a{i}, b{j})
                used(j) = true;
                matched = true;
                break;
            end
        end
        if !matched
            r = false;
            return;
        end
    end
    r = true;
end

function list = ck_as_element_list(value)
    if iscell(value)
        list = value(:)';
    elseif isnumeric(value) || islogical(value)
        list = num2cell(value(:)');
    else
        list = {value};
    end
end

% --- Per-student personalization primitives ---------------------------------
% Mirror of OctavePersonalizationRuntime.chickadeeSeedOctaveSource in
% Sources/Core — the server-side expression driver composes the same body, so
% the seed it binds and the seed this reads are computed identically. Octave
% has no bignum, so the 256-bit hex seed is folded with Horner's method modulo
% 2^31-1 — the SAME reduction R and Lua use, so a student's seed is one number
% whatever language the assignment is in. Every intermediate stays below 2^35,
% safely inside a double.

function value = ck_seed()
    raw = getenv("CHICKADEE_ASSIGNMENT_SEED");
    hex = lower(raw(isstrprop(raw, "xdigit")));
    if isempty(hex)
        value = 0;
        return;
    end
    modulus = 2147483647;
    acc = 0;
    for i = 1:numel(hex)
        acc = mod(acc * 16 + hex2dec(hex(i)), modulus);
    end
    value = acc;
end

% The per-student grading inputs the worker materialized into _ck_inputs.m
% (two parallel cell arrays, names and values), as a containers.Map — or an
% empty Map when none were delivered. The file is EVALUATED from its text
% rather than run by name, so its leading-underscore filename never has to be
% resolvable as a function and the same read works in both runners.
function map = ck_inputs()
    map = containers.Map();
    if exist("_ck_inputs.m", "file") != 2
        return;
    end
    ck_input_names = {};
    ck_input_values = {};
    try
        eval(fileread("_ck_inputs.m"));
    catch
        return;
    end
    for i = 1:min(numel(ck_input_names), numel(ck_input_values))
        map(ck_input_names{i}) = ck_input_values{i};
    end
end

% --- Locating the student's submission --------------------------------------
% Filenames Chickadee itself writes into the grading workspace are never the
% student's submission.

function r = ck_is_reserved(name)
    r = any(strcmp(name, {"test_runtime.m", "_ck_inputs.m"}));
end

function r = ck_is_test_file(name)
    r = !isempty(regexp(name, "^(publictest|releasetest|secrettest|studenttest)", "once"));
end

% The student's submitted Octave file: solution.m during validation, the
% extracted notebook during grading. Prefers the runner's
% `.chickadee_student_module` hint when it names an .m file actually present,
% then falls back to scanning the working directory (readdir works in both
% runners, unlike Lua whose standard library cannot list a directory).
% Returns "" when nothing looks like a submission.
function file = ck_student_file()
    file = "";
    hinted = "";
    if exist(".chickadee_student_module", "file") == 2
        try
            hinted = strtrim(fileread(".chickadee_student_module"));
        catch
            hinted = "";
        end
        newline_at = find(hinted == sprintf("\n"), 1);
        if !isempty(newline_at)
            hinted = strtrim(hinted(1:newline_at - 1));
        end
    end
    if !isempty(hinted)
        [~, stem, ext] = fileparts(hinted);
        base = [stem ext];
        if strcmpi(ext, ".m") && !ck_is_reserved(base) && !ck_is_test_file(base) ...
            && !strcmp(base, ck_running_script()) && exist(base, "file") == 2
            file = base;
            return;
        end
    end
    entries = sort(cellstr(readdir(pwd())));
    candidates = {};
    for i = 1:numel(entries)
        name = entries{i};
        [~, ~, ext] = fileparts(name);
        if !strcmpi(ext, ".m")
            continue;
        end
        if ck_is_reserved(name) || ck_is_test_file(name) || strcmp(name, ck_running_script())
            continue;
        end
        candidates{end + 1} = name;
    end
    if isempty(candidates)
        return;
    end
    if any(strcmp(candidates, "solution.m"))
        file = "solution.m";
        return;
    end
    file = candidates{1};
end

% Load the submission. See "THE SUBMISSION CONTRACT" in the header: the text
% is evaluated with a `1;` prefix so every submission shape reads as a script,
% its function definitions register under their own names, and its variables
% land here — captured into the returned env struct. A runtime error mid-file
% keeps everything defined before it.
function env = ck_load_student()
    ck_file_ = ck_student_file();
    if isempty(ck_file_)
        ck_errored("No Octave submission file was found to grade.");
    end
    ck_text_ = fileread(ck_file_);
    env = struct("file", ck_file_, "vars", struct());
    try
        eval(["1;" sprintf("\n") ck_text_]);
    catch ck_err_
        % A parse error means nothing was defined; a runtime error partway is
        % the tolerated shape. Distinguishing them is not worth a parser: if
        % no function or variable materialised at all, report the message.
        ck_defined_ = setdiff(who(), ...
            {"ck_file_", "ck_text_", "ck_err_", "ck_defined_", "env"});
        if isempty(ck_defined_)
            ck_errored(["Your submission (" ck_file_ ") could not be run as Octave: " ...
                ck_err_.message]);
        end
    end
    ck_names_ = setdiff(who(), {"ck_file_", "ck_text_", "ck_err_", "ck_defined_", "env"});
    for ck_i_ = 1:numel(ck_names_)
        env.vars.(ck_names_{ck_i_}) = eval(ck_names_{ck_i_});
    end
end

% Fetch a function the student was asked to write; a clear error when it is
% missing or bound to something that is not callable. Checks the submission's
% own variables first (a handle assigned with `f = @(x) ...`), then the
% command-line functions its definitions registered.
function fn = ck_require_fn(env, name)
    if isfield(env.vars, name)
        candidate = env.vars.(name);
        if is_function_handle(candidate)
            fn = candidate;
            return;
        end
        ck_errored(sprintf( ...
            "Your submission must define a function called `%s()` (found a %s).", ...
            name, class(candidate)));
    end
    kind = exist(name);
    if any(kind == [2, 3, 5, 103])
        fn = str2func(name);
        return;
    end
    ck_errored(sprintf("Your submission must define a function called `%s()`.", name));
end

function r = ck_has_var(env, name)
    r = isfield(env.vars, name);
end

function value = ck_get_var(env, name)
    value = env.vars.(name);
end

% The submission split into notebook cells, for source-level checks.
% `extractOctave` writes an inert `% ---- chickadee:cell N ----` comment ahead
% of each cell — same design as R and Lua, only the comment leader differs. A
% submission that never came from a notebook has no markers, so the whole file
% comes back as one cell: file granularity, the honest answer for a file with
% no cells.
function cells = ck_student_cells()
    file = ck_student_file();
    if isempty(file)
        ck_errored("No Octave submission file was found to grade.");
    end
    text = fileread(file);
    lines = strsplit(text, sprintf("\n"), "CollapseDelimiters", false);
    cells = {};
    current = {};
    seen_marker = false;
    started = false;
    for i = 1:numel(lines)
        line = lines{i};
        if !isempty(regexp(line, "^% ---- chickadee:cell [0-9]+ ----$", "once"))
            if started
                cells{end + 1} = strjoin(current, sprintf("\n"));
            end
            current = {};
            started = true;
            seen_marker = true;
        elseif started
            current{end + 1} = line;
        end
    end
    if started
        cells{end + 1} = strjoin(current, sprintf("\n"));
    end
    if !seen_marker
        whole = text;
        if !isempty(whole) && whole(end) == sprintf("\n")
            whole = whole(1:end - 1);
        end
        cells = {whole};
        return;
    end
    for i = 1:numel(cells)
        cells{i} = regexprep(cells{i}, "\\s+$", "");
    end
end
