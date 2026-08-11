// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
//
// Regression for the receiver demux's handling of an unmapped address.
//
// The demux sits directly behind the XDMA's AXI slave port. It used to drive both
// `oup_valid_o` and `inp_ready_o` low on a decode error, so the beat could never retire:
// the port stopped accepting AW/W and never emitted B, blocking the cfg, grant and finish
// traffic of every task behind one stray access. An unmapped beat must now be accepted and
// dropped instead.

module tb_xdma_write_demux_error;

  typedef logic [47:0] addr_t;
  typedef logic [63:0] data_t;

  localparam int unsigned NumOup = 3;
  localparam addr_t       ClusterEnd = 48'h1010_0000;
  localparam addr_t       WindowSize = 48'h1000;

  typedef struct packed {
    int unsigned idx;
    addr_t       start_addr;
    addr_t       end_addr;
  } rule_t;

  rule_t [NumOup-1:0] rules;
  addr_t addr;
  data_t data;
  logic  inp_valid, inp_ready;
  data_t [NumOup-1:0] oup_data;
  logic  [NumOup-1:0] oup_valid, oup_ready;
  int    errors = 0;

  xdma_write_demux #(
      .N_OUP (NumOup),
      .data_t(data_t),
      .addr_t(addr_t),
      .rule_t(rule_t)
  ) i_dut (
      .inp_addr_i (addr),
      .addr_map_i (rules),
      .inp_data_i (data),
      .inp_valid_i(inp_valid),
      .inp_ready_o(inp_ready),
      .oup_data_o (oup_data),
      .oup_valid_o(oup_valid),
      .oup_ready_i(oup_ready)
  );

  initial begin
    // finish / grant / cfg, stacked downwards from the cluster end address
    rules[0] = '{idx: 0, start_addr: ClusterEnd - 1 * WindowSize, end_addr: ClusterEnd};
    rules[1] = '{idx: 1, start_addr: ClusterEnd - 2 * WindowSize,
                 end_addr: ClusterEnd - 1 * WindowSize};
    rules[2] = '{idx: 2, start_addr: ClusterEnd - 3 * WindowSize,
                 end_addr: ClusterEnd - 2 * WindowSize};
    oup_ready = '1;
    data      = 64'hDEAD_BEEF_CAFE_F00D;
    inp_valid = 1'b1;

    // A mapped address still routes to exactly one output.
    addr = ClusterEnd - WindowSize + 8;
    #1;
    if (!inp_ready || oup_valid !== 3'b001) begin
      $error("mapped addr %h: inp_ready=%0b oup_valid=%b", addr, inp_ready, oup_valid);
      errors++;
    end else begin
      $display("[tb_xdma_write_demux_error] mapped addr routed to idx 0");
    end

    // An unmapped address must be accepted (so the port can retire it) and dropped.
    addr = 48'h1000_0000;
    #1;
    if (!inp_ready) begin
      $error("unmapped addr %h: inp_ready=0, the beat can never retire", addr);
      errors++;
    end
    if (oup_valid !== '0) begin
      $error("unmapped addr %h: oup_valid=%b, a stray beat leaked to an output",
             addr, oup_valid);
      errors++;
    end
    if (errors == 0) begin
      $display("[tb_xdma_write_demux_error] unmapped addr accepted and dropped");
    end

    // Back-pressure on the selected output must still be honoured for a mapped address.
    addr      = ClusterEnd - 3 * WindowSize;
    oup_ready = 3'b011;   // idx 2 (cfg) not ready
    #1;
    if (inp_ready) begin
      $error("mapped addr %h ignored back-pressure from its output", addr);
      errors++;
    end else begin
      $display("[tb_xdma_write_demux_error] back-pressure on a mapped output honoured");
    end

    if (errors != 0) $fatal(1, "[tb_xdma_write_demux_error] FAILED with %0d error(s)", errors);
    $display("[PASS] tb_xdma_write_demux_error");
    $finish;
  end

endmodule
