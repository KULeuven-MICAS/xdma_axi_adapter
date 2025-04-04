// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
// - Yunhao Deng <yunhao.deng@kuleuven.be>
module find_first_one_idx #(
    parameter int N = 4,
    /// Dependent parameters, DO NOT OVERRIDE!
    parameter integer LOG_N_INP = $clog2(N)
) (
    input  logic [N-1:0]         in_i,
    output logic [LOG_N_INP-1:0] idx_o, 
    output logic                 valid_o 
);

    logic found;
    always_comb begin : find_idx
        idx_o = '0;
        valid_o = |in_i;
        found = 1'b0;
        for (int i = 0; i < N; i++) begin
            if (!found && in_i[i]) begin
                idx_o = LOG_N_INP'(i);
                found = 1'b1; 
            end
        end
    end
endmodule