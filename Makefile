# Authors:
# - Fanchen Kong <fanchen.kong@kuleuven.be>
# - Yunhao Deng <yunhao.deng@kuleuven.be>
# The batch testing is done by the make all
# The single testing with gui is done by make sim_gui
VSIM          ?= vsim
BENDER        ?= bender
TB_DIR        ?= tb
TEST_DIR      ?= test
VSIM_BUILDDIR ?= work-vsim
TB            ?=
TBS           ?= find_first_one_idx

SIM_TARGETS := $(addsuffix .log,$(addprefix sim-,$(TBS)))

.PHONY: help all sim_all clean

help:
	@echo ""
	@echo "compile.log:  compile files using Questasim"
	@echo "sim-#TB#.log: simulates a given testbench, available TBs are:"
	@echo "$(addprefix ###############-#,$(TBS))" | sed -e 's/ /\n/g' | sed -e 's/#/ /g'
	@echo "sim_all:      simulates all available testbenches"
	@echo "sim_gui:      simulates the specified TB with gui"
	@echo ""
	@echo "clean:        cleans generated files"
	@echo ""

all: compile.log sim_all

sim_all: $(SIM_TARGETS)

build:
	mkdir -p $@
compile.log: Bender.yml | build
	export VSIM="$(VSIM)"; cd build && ../scripts/compile_vsim.sh | tee ../$@
	(! grep -n "Error:" $@)

sim-%.log: compile.log
	export VSIM="$(VSIM)"; cd build && ../scripts/run_vsim.sh --random-seed $* | tee ../$@
	(! grep -n "Error:" $@)
	(! grep -n "Fatal:" $@)

sim_gui: $(TB_DIR)/${TB}.vsim.gui
	$(TB_DIR)/${TB}.vsim.gui

VSIM_BENDER_TARGET = -t simulation
VSIM_BENDER_TARGET += -t test

VLOG_FLAGS += -svinputport=compat
VLOG_FLAGS += -timescale 1ns/1ps

VSIM_FLAGS += -t 1ps
VSIM_FLAGS += -voptargs=+acc
VSIM_FLAGS += -do "log -r /*; run -a"
VOPT_FLAGS = +acc
$(VSIM_BUILDDIR):
	mkdir -p $@
$(TB_DIR):
	mkdir -p $@

$(VSIM_BUILDDIR)/compile.vsim.tcl: $(VSIM_BUILDDIR)
	$(BENDER) script vsim $(VSIM_BENDER_TARGET) --vlog-arg="$(VLOG_FLAGS) -work $(dir $@) " > $@
	echo 'vlog -work $(dir $@) ' >> $@
	echo 'return 0' >> $@
$(TB_DIR)/${TB}.vsim.gui: $(VSIM_BUILDDIR)/compile.vsim.tcl |$(TB_DIR)
	touch $@
	vsim -c -do "source $<; quit" | tee $(VSIM_BUILDDIR)/vlog.log
	vopt $(VOPT_FLAGS) -work $(VSIM_BUILDDIR) tb_$(TB) -o tb_$(TB)_opt | tee $(VSIM_BUILDDIR)/vopt.log
	@! grep -P "Errors: [1-9]*," $(VSIM_BUILDDIR)/vlog.log
	@echo "#!/bin/bash" > $@
	@echo 'vsim +permissive $(VSIM_FLAGS) -work $(VSIM_BUILDDIR) \
					tb_${TB}_opt +permissive-off ' >> $@
	@chmod +x $@
clean:
	rm -rf build
	rm -f  *.log
	rm -rf *.wlf
	rm -rf $(VSIM_BUILDDIR)
	rm -rf $(TB_DIR)
	rm -rf transcript