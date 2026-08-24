.PHONY: deps test fmt fmt-check

deps:
	@test -d .deps/plenary.nvim || git clone --depth 1 \
	  https://github.com/nvim-lua/plenary.nvim .deps/plenary.nvim

test: deps
	nvim --headless --noplugin -u tests/minimal_init.lua \
	  -c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua' }"

fmt:
	stylua lua tests plugin

fmt-check:
	stylua --check lua tests plugin
