// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
//
// The other face of the single-remote-context bug: the destination is not idle when the
// broadcast arrives, because it is taking delivery of a remote READ of its own. The write's
// receive window opens on the same `from_remote_data_accompany_cfg` port behind the read's,
// with `ready_to_transfer` never falling in between.
//
// This is the arm whose system-level signature is `i_read_stall_watchdog` on the receiving
// clusters, and it wedges `xdma_finish_manager`'s READ FSM rather than its write FSM. It is
// the same defect -- a context retiring on a shared busy LEVEL instead of on the identity
// of the transfer it holds -- which is why one fix covers both.
module tb_xdma_multisource_read_collision ();
  xdma_multisource_2to1_body #(
      .SerialiseWindows(1'b0),
      .ReadFirst       (1'b1)
  ) i_body ();
endmodule
