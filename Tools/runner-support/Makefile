IPYNB := $(wildcard *.ipynb)
PY    := $(IPYNB:.ipynb=.py)
R_OUT := $(IPYNB:.ipynb=.R)

.PHONY: all clean

all: nb_to_py.py nb_to_r.py $(PY) $(R_OUT)
	@test ! -f compile_fail

nb_to_py.py:
	@printf '%s\n' \
"import sys, json" \
"" \
"p = sys.argv[1]" \
"with open(p, 'r', encoding='utf-8') as f:" \
"    nb = json.load(f)" \
"" \
"out = p[:-6] + '.py'" \
"with open(out, 'w', encoding='utf-8') as w:" \
"    w.write(f'# Generated from {p}\\n\\n')" \
"    for cell in nb.get('cells', []):" \
"        if cell.get('cell_type') == 'code':" \
"            src = cell.get('source', '')" \
"            if isinstance(src, list):" \
"                src = ''.join(src)" \
"            src = src.rstrip()" \
"            if src:" \
"                w.write(src + '\\n\\n')" \
> $@

nb_to_r.py:
	@printf '%s\n' \
"import sys, json" \
"" \
"p = sys.argv[1]" \
"with open(p, 'r', encoding='utf-8') as f:" \
"    nb = json.load(f)" \
"" \
"out = p[:-6] + '.R'" \
"with open(out, 'w', encoding='utf-8') as w:" \
"    w.write(f'# Generated from {p}\\n\\n')" \
"    for cell in nb.get('cells', []):" \
"        if cell.get('cell_type') == 'code':" \
"            src = cell.get('source', '')" \
"            if isinstance(src, list):" \
"                src = ''.join(src)" \
"            src = src.rstrip()" \
"            if src:" \
"                w.write(src + '\\n\\n')" \
> $@

%.py: %.ipynb nb_to_py.py
	@python3 nb_to_py.py "$<" || touch compile_fail

%.R: %.ipynb nb_to_r.py
	@python3 nb_to_r.py "$<" || touch compile_fail

clean:
	@rm -f $(PY) $(R_OUT) nb_to_py.py nb_to_r.py compile_fail
