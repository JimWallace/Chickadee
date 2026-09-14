% Test: io
% Generated from pattern family "Family" [fam] spec_hash=eb00ef813bc014b0 — edit the family, not this file.
chickadee = test_runtime();

stdin_text = "3\n4\n";
expected = "7";

ck_file = chickadee.student_file();
if isempty(ck_file)
    chickadee.errored("No Octave submission file was found to run.");
end

function out = ck_normalize(text)
    lines = strsplit(text, sprintf("\n"), "CollapseDelimiters", false);
    for i = 1:numel(lines)
        lines{i} = regexprep(lines{i}, '\s+$', "");
    end
    while !isempty(lines) && isempty(lines{end})
        lines(end) = [];
    end
    out = strjoin(lines, sprintf("\n"));
end

global ck_stdin_lines ck_stdin_pos ck_program_running ck_prev_exit ck_prev_quit
ck_stdin_lines = strsplit(stdin_text, sprintf("\n"), "CollapseDelimiters", false);
if !isempty(ck_stdin_lines) && isempty(ck_stdin_lines{end})
    ck_stdin_lines(end) = [];
end
ck_stdin_pos = 1;
ck_program_running = false;
ck_prev_exit = @exit;
ck_prev_quit = @quit;

function r = input(prompt, varargin)
    global ck_stdin_lines ck_stdin_pos
    printf("%s", prompt);
    if ck_stdin_pos > numel(ck_stdin_lines)
        error("chickadee:eof", "end of input");
    end
    line = ck_stdin_lines{ck_stdin_pos};
    ck_stdin_pos = ck_stdin_pos + 1;
    if nargin > 1
        r = line;
    else
        r = str2num(line);
        if isempty(r)
            r = line;
        end
    end
end
function exit(varargin)
    global ck_program_running ck_prev_exit
    if ck_program_running
        error("chickadee:exit", "exit");
    end
    ck_prev_exit(varargin{:});
end
function quit(varargin)
    global ck_program_running ck_prev_quit
    if ck_program_running
        error("chickadee:exit", "exit");
    end
    ck_prev_quit(varargin{:});
end

ck_text = fileread(ck_file);
ck_error = "";
ck_program_running = true;
try
    captured = evalc("eval([\"1;\" sprintf(\"\\n\") ck_text]);");
catch err
    captured = "";
    if !strcmp(err.identifier, "chickadee:exit")
        ck_error = err.message;
    end
end
ck_program_running = false;

if !isempty(ck_error)
    chickadee.failed(["unexpected exception\n" ...
        "  input:    " chickadee.format(stdin_text) "\n" ...
        "  got:      " chickadee.format(ck_normalize(captured)) "\n" ...
        "  error:    " ck_error]);
end

ok = strcmp(ck_normalize(captured), ck_normalize(expected));
if !ok
    chickadee.failed(["wrong output\n" ...
        "  input:    " chickadee.format(stdin_text) "\n" ...
        "  expected: " chickadee.format(expected) "\n" ...
        "  got:      " chickadee.format(ck_normalize(captured))]);
end

chickadee.passed("Printed the expected output");