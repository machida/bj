SPINEL_DIR   = spinel
SPINEL       = $(SPINEL_DIR)/spinel
SRC_RB       = src/blackjack.rb
GEN_C        = generated/blackjack.c
WEB_JS       = docs/blackjack.js
WEB_WASM     = docs/blackjack.wasm

# Python 3.10+ required by emscripten; override if `python3` on PATH is too old:
#   EMSDK_PYTHON=/opt/homebrew/opt/python@3.13/bin/python3.13 make
EMSDK_PYTHON ?= python3
EMCC         = EMSDK_PYTHON=$(EMSDK_PYTHON) emcc

EMCC_FLAGS   = -O2 \
               -I$(SPINEL_DIR)/lib \
               -Dmalloc_trim\(x\)=\(\(void\)\(x\)\) \
               -sMODULARIZE=1 \
               -sEXPORT_NAME=createBlackjack \
               -sEXIT_RUNTIME=1 \
               -sFORCE_FILESYSTEM=1 \
               -sINVOKE_RUN=0 \
               "-sEXPORTED_RUNTIME_METHODS=['callMain','FS']" \
               -lm

.PHONY: all clean serve check test

all: $(WEB_JS)

# ── 1. Clone & build Spinel ──────────────────────────────────────────────────
$(SPINEL_DIR)/Makefile:
	git clone https://github.com/matz/spinel $(SPINEL_DIR)

$(SPINEL): $(SPINEL_DIR)/Makefile
	cd $(SPINEL_DIR) && make deps && make

# ── 2. Ruby → C (Spinel AOT) ────────────────────────────────────────────────
$(GEN_C): $(SRC_RB) $(SPINEL)
	mkdir -p generated
	@echo "→ Compiling Ruby to C via Spinel..."
	$(SPINEL) $(SRC_RB) -S > $(GEN_C)
	@echo "  Generated $(GEN_C) ($$(wc -l < $(GEN_C)) lines)"

# ── 3. C → WASM (Emscripten) ────────────────────────────────────────────────
$(WEB_JS): $(GEN_C)
	@which emcc >/dev/null 2>&1 || (echo "emcc not found. Run: brew install emscripten"; exit 1)
	@echo "→ Compiling C to WASM via Emscripten..."
	$(EMCC) $(GEN_C) $(EMCC_FLAGS) -o $(WEB_JS)
	@echo "  Generated $(WEB_JS) and $(WEB_WASM)"

# ── Dev server ───────────────────────────────────────────────────────────────
serve:
	@echo "Open http://localhost:8080"
	python3 -m http.server 8080 --directory docs

# ── Sanity check ─────────────────────────────────────────────────────────────
check:
	@which ruby  >/dev/null 2>&1 && echo "✓ ruby  $$(ruby --version)"  || echo "✗ ruby not found"
	@which emcc  >/dev/null 2>&1 && (EMSDK_PYTHON=$(EMSDK_PYTHON) emcc --version 2>&1 | head -1 | sed 's/^/✓ /') || echo "✗ emcc not found (brew install emscripten)"
	@which node  >/dev/null 2>&1 && echo "✓ node  $$(node --version)" || echo "✗ node not found"
	@test -f $(WEB_WASM) && echo "✓ WASM  $(WEB_WASM)" || echo "✗ WASM not built yet — run: make"

test:
	ruby test/blackjack_test.rb

clean:
	rm -rf generated $(WEB_JS) $(WEB_WASM)

clean-all: clean
	rm -rf $(SPINEL_DIR)
