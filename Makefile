# llmkit-pascal
#
#   make           build the library units and the llmkit CLI
#   make test      build and run the offline test suite
#   make leaks     run the suite with heap tracing
#   make examples  build the example programs
#   make clean

FPC      ?= fpc
MODE     := -Mobjfpc -Sh
WARN     := -vw -vn-
OPT      ?= -O2
UNITDIRS := -Fusrc -Fusrc/providers
BUILD    := build
BIN      := bin

SOURCES  := $(wildcard src/*.pas) $(wildcard src/providers/*.pas)

.PHONY: all lib cli test leaks examples clean

all: lib cli

lib: $(BUILD)/.lib.stamp

$(BUILD)/.lib.stamp: $(SOURCES)
	@mkdir -p $(BUILD)
	$(FPC) $(MODE) $(WARN) $(OPT) -FU$(BUILD) $(UNITDIRS) src/LLMKit.pas
	@touch $@

cli: lib
	@mkdir -p $(BUILD)/cmd $(BIN)
	$(FPC) $(MODE) $(WARN) $(OPT) -FU$(BUILD)/cmd $(UNITDIRS) -FE$(BIN) cmd/llmkit.pas

test: lib
	@mkdir -p $(BUILD)/tests $(BIN)
	$(FPC) $(MODE) $(WARN) $(OPT) -FU$(BUILD)/tests $(UNITDIRS) -Futests \
		-FE$(BIN) tests/llmkittests.pas
	$(BIN)/llmkittests --format=plain --all

leaks:
	@mkdir -p $(BUILD)/leaks $(BIN)
	$(FPC) $(MODE) $(WARN) -gh -gl -FU$(BUILD)/leaks $(UNITDIRS) -Futests \
		-FE$(BIN) -o$(BIN)/llmkittests-gh tests/llmkittests.pas
	$(BIN)/llmkittests-gh --format=plain --all

examples: lib
	@mkdir -p $(BUILD)/examples $(BIN)
	for f in examples/*.pas; do \
		$(FPC) $(MODE) $(WARN) $(OPT) -FU$(BUILD)/examples $(UNITDIRS) \
			-FE$(BIN) $$f || exit 1; \
	done

clean:
	rm -rf $(BUILD) $(BIN)
