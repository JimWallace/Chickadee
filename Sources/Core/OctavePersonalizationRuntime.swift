// Core/OctavePersonalizationRuntime.swift
//
// Octave source snippets shared by the two places that need Octave
// personalization primitives: the injected grading runtime (test_runtime.m,
// via the worker's TestRuntimeSources) and the server-side Octave expression
// driver (PersonalizationEvaluator). One source of truth means the seed the
// driver binds and the seed a grading script reads are computed identically.
//
// The Octave counterpart of RPersonalizationRuntime and
// LuaPersonalizationRuntime. Core Octave only: the runner image installs the
// stock `octave` package and the chickadee-octave kernel env is bare
// xeus-octave, so nothing beyond the base function set is available in either
// place this is used.

public enum OctavePersonalizationRuntime {

    /// `chickadee_seed()` — a deterministic integer derived from the
    /// per-student `CHICKADEE_ASSIGNMENT_SEED` (a 64-hex-char / 256-bit value).
    ///
    /// Octave's numbers are doubles (no bignum), so the hex cannot be
    /// converted directly. The digits are folded with Horner's method modulo
    /// `2^31 - 1` — the SAME reduction R and Lua use, deliberately, so a
    /// student's seed is one number whichever non-Python language the
    /// assignment is in. Every intermediate stays below `2^35`, safely inside
    /// a double's exact-integer range.
    ///
    /// Emitted as a plain function definition (valid in a driver script after
    /// its leading `1;` guard), because the driver's temp directory has no
    /// `test_runtime.m` beside it to call. `test_runtime.m` wraps the
    /// identical body as `ck_seed`; `LanguagePipelineWalkTests` proves the two
    /// compute the same number by executing both.
    public static let chickadeeSeedOctaveSource = #"""
        function value = chickadee_seed()
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
        """#

    /// An Octave value rendered back as Octave source, for the driver's output
    /// stage. The counterpart of R's `deparse`; the server parses nothing here
    /// — it takes the emitted text and writes it verbatim into `_ck_inputs.m`,
    /// so this has to produce an Octave LITERAL rather than a display form.
    ///
    /// Load-bearing details:
    ///   * `%.17g` round-trips an IEEE double exactly, with an integer check
    ///     first so `3` stays `3`;
    ///   * strings re-encode through the same escaping the JSON stage uses,
    ///     wrapped in double quotes (Octave's C-escape string form);
    ///   * numeric row vectors serialise as `[...]`, anything mixed as a cell
    ///     `{...}` — matching `JSONValue.octaveLiteral`'s concatenation-trap
    ///     rule so a driver-computed value and an authored one render alike;
    ///   * anything with no literal form (a struct, a handle) renders `NA`,
    ///     which surfaces as a missing personalization input rather than as
    ///     unparseable source.
    public static let chickadeeSerializeOctaveSource = #"""
        function s = chickadee_serialize(value)
            if ischar(value)
                s = chickadee_escape_string(value);
            elseif islogical(value) && isscalar(value)
                if value
                    s = "true";
                else
                    s = "false";
                end
            elseif isnumeric(value) && isscalar(value)
                if isnan(value)
                    s = "NaN";
                elseif isinf(value)
                    if value < 0
                        s = "-Inf";
                    else
                        s = "Inf";
                    end
                elseif value == fix(value) && abs(value) < 2^53
                    s = sprintf("%d", value);
                else
                    s = sprintf("%.17g", value);
                end
            elseif isnumeric(value) || islogical(value)
                parts = cell(1, numel(value));
                flat = value(:)';
                for i = 1:numel(flat)
                    parts{i} = chickadee_serialize(flat(i));
                end
                s = ["[" strjoin(parts, ", ") "]"];
            elseif iscell(value)
                parts = cell(1, numel(value));
                flat = value(:)';
                for i = 1:numel(flat)
                    parts{i} = chickadee_serialize(flat{i});
                end
                s = ["{" strjoin(parts, ", ") "}"];
            else
                s = "NA";
            end
        end
        """#

    /// String escaping for both the serializer and the driver's JSON output
    /// stage. Behaviour-identical to `ck_json_str` in `test_runtime.m` for the
    /// characters it handles; standalone because the runtime's copy is a
    /// subfunction of that file and the driver needs its own.
    public static let chickadeeEscapeStringOctaveSource = #"""
        function s = chickadee_escape_string(value)
            s = value;
            s = strrep(s, "\\", "\\\\");
            s = strrep(s, "\"", "\\\"");
            s = strrep(s, sprintf("\n"), "\\n");
            s = strrep(s, sprintf("\r"), "\\r");
            s = strrep(s, sprintf("\t"), "\\t");
            s = ["\"" s "\""];
        end
        """#
}
