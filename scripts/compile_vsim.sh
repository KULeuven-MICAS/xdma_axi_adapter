#!/bin/bash
set -e

[ ! -z "$VSIM" ] || VSIM=vsim

# `-t xdma_axi_adapter_test` is the bender target carrying this repo's own testbenches;
# `-t test -t rtl` covers the dependencies. See Bender.yml.
bender script vsim -t test -t rtl -t xdma_axi_adapter_test \
    --vlog-arg="-svinputport=compat" \
    --vlog-arg="-override_timescale 1ns/1ps" \
    --vlog-arg="-suppress 2583" \
    > compile.tcl
echo 'return 0' >> compile.tcl

$VSIM -c -do 'exit -code [source compile.tcl]'