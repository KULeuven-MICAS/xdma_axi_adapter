// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
//
// Every node is an issuer AND a destination at the same time.
//
//        C0 ──── write A ────►┐
//                              ├──► C2 ──── write C ────► C0
//        C1 ──── write B ────►┘
//
// This is the two-issuer bisect that `docs/xdma_multi_issuer_multicast_hang.md` §5 asks for.
// That report has four clusters each issuing a star multicast while receiving three others,
// and the first thing to wedge is a grant manager -- not the finish manager the earlier
// write-ups blamed. The question it poses is whether the fault needs four concurrent
// issuers or reproduces with two; this arm answers it at the adapter boundary.
//
// What it adds over `tb_xdma_multisource_collision`: node 2 is no longer a pure sink. It
// owes grants to nodes 0 and 1 while its own cfg and payload are in flight, and cfg outranks
// grant in `find_first_one_idx`, so its grant is issued against a busy narrow bus. Node 0 is
// likewise a sender whose own grant manager is in use before its wide send has drained.
module tb_xdma_multisource_send_while_receiving ();
  xdma_multisource_2to1_body #(
      .SerialiseWindows(1'b0),
      .DestAlsoIssues  (1'b1)
  ) i_body ();
endmodule
