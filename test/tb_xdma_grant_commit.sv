// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
//
// A grant that `xdma_grant_manager` has COMMITTED to must be delivered, and must name the
// transfer the FSM armed on -- whatever the shared receive port does in the meantime.
//
// The port can move while a grant is still queued. Grants share the narrow bus with cfg and
// finish, and `find_first_one_idx` ranks cfg above grant, so a node that is also an issuer
// queues the grants it owes behind its own cfg frames. `docs/xdma_multi_issuer_multicast_hang.md`
// reports a grant manager as the first thing to wedge in a four-issuer FlashAttention decode,
// with the sending cluster then spinning forever on a completion that never arrives.
//
// Qualifying the grant's VALID with a live-port match turns that into a permanent park: AXI
// VALID may not be retracted before its handshake, and this FSM leaves SEND_GRANT_TO_PREV_HOP
// only on that handshake, so the grant is never issued to anyone -- not to the transfer it
// armed on, and not to the one now named. The correctness that the qualification bought is
// instead provided by `armed_cfg_o`, which is what the packet is built from.
//
// The stimulus here is the minimum that exercises it: arm on A, hold the narrow bus busy,
// move the port to B, then free the bus. Both transfers must end up granted, each addressed
// to its own source.

`timescale 1ns / 1ps

module tb_xdma_grant_commit;

  localparam time CyclTime = 10ns;

  typedef logic [ 3:0] tb_id_t;
  typedef logic [47:0] tb_addr_t;
  typedef logic [18:0] tb_len_t;

  typedef struct packed {
    tb_id_t   dma_id;
    logic     dma_type;
    tb_addr_t src_addr;
    tb_addr_t dst_addr;
    tb_len_t  dma_length;
    logic     ready_to_transfer;
    logic     is_first_cw;
    logic     is_last_cw;
    logic     is_initiator;
  } tb_xdma_accompany_cfg_t;

  localparam tb_addr_t SrcA = 48'h1000_0000;
  localparam tb_addr_t SrcB = 48'h1010_0000;
  localparam tb_id_t   IdA  = 4'd1;
  localparam tb_id_t   IdB  = 4'd2;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #(CyclTime / 2) clk = ~clk;

  tb_xdma_accompany_cfg_t cfg, armed;
  logic from_remote_grant, grant_valid, grant_ready, stall_error;
  int   errors = 0;

  xdma_grant_manager #(
      .xdma_from_remote_data_accompany_cfg_t(tb_xdma_accompany_cfg_t),
      .StallTimeout                         (32'd2000)
  ) i_dut (
      .clk_i                           (clk),
      .rst_ni                          (rst_n),
      .from_remote_grant_i             (from_remote_grant),
      .from_remote_data_accompany_cfg_i(cfg),
      .to_remote_grant_valid_o         (grant_valid),
      .to_remote_grant_ready_i         (grant_ready),
      .armed_cfg_o                     (armed),
      .stall_error_o                   (stall_error)
  );

  // Every grant the FSM actually hands to the narrow path, and who it names.
  tb_addr_t granted_src[$];
  tb_id_t   granted_id[$];
  always @(posedge clk) begin
    if (rst_n && grant_valid && grant_ready) begin
      granted_src.push_back(armed.src_addr);
      granted_id.push_back(armed.dma_id);
    end
  end

  // Point the single receive context at a plain remote write from `src`: this node is the
  // last hop, which is what arms the grant manager.
  task automatic point_at(input tb_id_t id, input tb_addr_t src);
    cfg.dma_id            = id;
    cfg.dma_type          = 1'b1;
    cfg.src_addr          = src;
    cfg.dst_addr          = 48'h1020_0000;
    cfg.dma_length        = 19'd8;
    cfg.ready_to_transfer = 1'b1;
    cfg.is_first_cw       = 1'b0;
    cfg.is_last_cw        = 1'b1;
    cfg.is_initiator      = 1'b0;
  endtask

  task automatic check_addr(input int unsigned idx, input tb_addr_t expected,
                            input string what);
    if (granted_src.size() <= idx) begin
      errors++;
      $error("%s: no grant was issued at all (only %0d issued)", what, granted_src.size());
    end else if (granted_src[idx] !== expected) begin
      errors++;
      $error("%s: grant addressed to %h, expected %h", what, granted_src[idx], expected);
    end
  endtask

  int i;
  initial begin
    cfg               = '0;
    from_remote_grant = 1'b0;
    grant_ready       = 1'b0;   // the narrow bus is busy with this node's own cfg
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    //---- A's window opens; the FSM commits to granting it ----
    point_at(IdA, SrcA);
    repeat (4) @(posedge clk);
    #1;
    if (i_dut.cur_state.name() != "SEND_GRANT_TO_PREV_HOP") begin
      $fatal(1, "setup: expected SEND_GRANT_TO_PREV_HOP, got %s", i_dut.cur_state.name());
    end
    if (!grant_valid) begin
      errors++;
      $error("the FSM committed to a grant but is not driving VALID");
    end

    //---- The port moves to B while A's grant is still queued ----
    point_at(IdB, SrcB);
    repeat (3) @(posedge clk);
    #1;
    // VALID must NOT have been retracted: AXI forbids it, and retracting it here is what
    // parks the FSM for good.
    if (!grant_valid) begin
      errors++;
      // A concatenation is a value, not a format string, so this stays one literal.
      $error("VALID retracted after the port moved on: the committed grant is lost and this FSM can never leave %s",
             i_dut.cur_state.name());
    end

    //---- The narrow bus frees up ----
    grant_ready = 1'b1;
    for (i = 0; i < 200; i++) begin
      @(posedge clk);
      #1;
      if (granted_src.size() >= 2) break;
    end
    @(posedge clk);

    //---- Both transfers must have been granted, each named correctly ----
    if (granted_src.size() != 2) begin
      errors++;
      $error("expected 2 grants (one per source), got %0d -- FSM parked in %s",
             granted_src.size(), i_dut.cur_state.name());
    end
    check_addr(0, SrcA, "A's grant (committed before the port moved)");
    check_addr(1, SrcB, "B's grant (armed after the port moved)");
    if (granted_id.size() >= 2 && (granted_id[0] !== IdA || granted_id[1] !== IdB)) begin
      errors++;
      $error("grant ids out of order: got %0d then %0d, expected %0d then %0d",
             granted_id[0], granted_id[1], IdA, IdB);
    end
    if (stall_error) begin
      errors++;
      $error("the stall watchdog latched");
    end

    if (errors != 0) $fatal(1, "[TB] tb_xdma_grant_commit FAILED with %0d error(s)", errors);
    $display("[TB] both grants delivered: A -> %h, B -> %h", granted_src[0], granted_src[1]);
    $display("[PASS] tb_xdma_grant_commit");
    $finish;
  end

endmodule
