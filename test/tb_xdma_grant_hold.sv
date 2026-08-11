// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
//
// Regression for the grant path's VALID stability and illegal-state recovery.
//
// `to_remote_grant_valid_o` used to be driven from `grant_valid`, i.e. straight from
// `from_remote_data_accompany_cfg_i.ready_to_transfer` -- a live external level. It could
// therefore retract after the narrow req_manager had already arbitrated the grant, which
// violates AXI-stream VALID stability, loses the grant, and leaves both this FSM and the
// req_manager unable to make progress (the latter exits BUSY only on a beat count that can
// no longer be reached), taking the shared narrow port down with them.

module tb_xdma_grant_hold;

  localparam time  ClkPeriod = 10ns;
  localparam int unsigned MaxWait = 200;

  typedef logic [ 3:0] id_t;
  typedef logic [47:0] addr_t;
  typedef logic [18:0] len_t;

  typedef struct packed {
    id_t   dma_id;
    logic  dma_type;
    addr_t src_addr;
    addr_t dst_addr;
    len_t  dma_length;
    logic  ready_to_transfer;
    logic  is_first_cw;
    logic  is_last_cw;
  } accompany_cfg_t;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #(ClkPeriod / 2) clk = ~clk;

  accompany_cfg_t from_cfg;
  logic from_remote_grant, grant_valid, grant_ready;
  int   errors = 0;

  xdma_grant_manager #(
      .xdma_from_remote_data_accompany_cfg_t(accompany_cfg_t)
  ) i_dut (
      .clk_i                           (clk),
      .rst_ni                          (rst_n),
      .from_remote_grant_i             (from_remote_grant),
      .from_remote_data_accompany_cfg_i(from_cfg),
      .to_remote_grant_valid_o         (grant_valid),
      .to_remote_grant_ready_i         (grant_ready)
  );

  // Drive a last-hop write so the FSM walks IDLE -> WRITE_LAST -> SEND_GRANT_TO_PREV_HOP.
  task automatic arm_last_hop_write();
    from_cfg                   = '0;
    from_cfg.dma_type          = 1'b1;
    from_cfg.is_first_cw       = 1'b0;
    from_cfg.is_last_cw        = 1'b1;
    from_cfg.ready_to_transfer = 1'b1;
  endtask

  int cyc;
  initial begin
    from_cfg = '0;
    from_remote_grant = 1'b0;
    grant_ready = 1'b0;
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    //--------------------------------------------------------------------
    // 1. VALID must survive `ready_to_transfer` dropping mid-transaction.
    //--------------------------------------------------------------------
    arm_last_hop_write();
    repeat (4) @(posedge clk);
    if (!grant_valid) begin
      $error("[tb_xdma_grant_hold] setup: no grant asserted");
      errors++;
    end

    // The sink is still back-pressuring when the accompany cfg moves on.
    from_cfg.ready_to_transfer = 1'b0;
    repeat (3) @(posedge clk);
    if (!grant_valid) begin
      $error("[tb_xdma_grant_hold] VALID retracted with no handshake");
      errors++;
    end else begin
      $display("[tb_xdma_grant_hold] VALID held across ready_to_transfer drop");
    end

    // Release the sink: the grant must still be delivered.
    grant_ready = 1'b1;
    cyc = 0;
    while (!(grant_valid && grant_ready) && cyc < MaxWait) begin
      @(posedge clk);
      cyc++;
    end
    if (cyc >= MaxWait) begin
      $error("[tb_xdma_grant_hold] grant never handshaked (%0d cycles)", MaxWait);
      errors++;
    end else begin
      $display("[tb_xdma_grant_hold] grant delivered after %0d cycles", cyc);
    end
    @(posedge clk);
    grant_ready = 1'b0;
    from_cfg = '0;
    repeat (4) @(posedge clk);

    //--------------------------------------------------------------------
    // 2. An illegal state encoding must not be absorbing.
    //--------------------------------------------------------------------
    force i_dut.cur_state = 3'd6;
    @(posedge clk);
    release i_dut.cur_state;
    grant_ready = 1'b1;
    arm_last_hop_write();

    cyc = 0;
    while (!(grant_valid && grant_ready) && cyc < MaxWait) begin
      @(posedge clk);
      cyc++;
    end
    if (cyc >= MaxWait) begin
      $error("[tb_xdma_grant_hold] stuck in an illegal state, grants dead");
      errors++;
    end else begin
      $display("[tb_xdma_grant_hold] recovered from an illegal state after %0d cycles", cyc);
    end

    if (errors != 0) $fatal(1, "[tb_xdma_grant_hold] FAILED with %0d error(s)", errors);
    $display("[PASS] tb_xdma_grant_hold");
    $finish;
  end

endmodule
