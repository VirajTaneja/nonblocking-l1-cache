`timescale 1ns/1ps

module memory_model #(
    parameter int ADDR_W = 32,
    parameter int DATA_W = 32,
    parameter int LINE_BYTES = 64,
    parameter int MSHRS = 2,
    parameter int MEM_LINES = 1024,
    parameter int READ_LATENCY = 12
) (
    input  logic                      clk,
    input  logic                      rst_n,

    input  logic                      mem_req_valid,
    output logic                      mem_req_ready,
    input  logic                      mem_req_write,
    input  logic [ADDR_W-1:0]         mem_req_addr,
    input  logic [(LINE_BYTES*8)-1:0] mem_req_wdata,
    input  logic [((MSHRS <= 1) ? 1 : $clog2(MSHRS))-1:0] mem_req_mshr_id,

    output logic                      mem_resp_valid,
    input  logic                      mem_resp_ready,
    output logic [((MSHRS <= 1) ? 1 : $clog2(MSHRS))-1:0] mem_resp_mshr_id,
    output logic [(LINE_BYTES*8)-1:0] mem_resp_rdata
);

    localparam int DATA_BYTES = DATA_W / 8;
    localparam int LINE_W = LINE_BYTES * 8;
    localparam int OFFSET_W = $clog2(LINE_BYTES);
    localparam int MEM_INDEX_W = $clog2(MEM_LINES);
    localparam int MSHR_W = (MSHRS <= 1) ? 1 : $clog2(MSHRS);
    localparam int LAT_W = (READ_LATENCY <= 1) ? 1 : $clog2(READ_LATENCY + 1);
    localparam int WORDS_PER_LINE = LINE_BYTES / DATA_BYTES;

    // Public on purpose: the testbench peeks at backing memory after writeback.
    logic [LINE_W-1:0] mem [0:MEM_LINES-1];

    logic pending_valid [0:MSHRS-1];
    logic [LAT_W-1:0] pending_count [0:MSHRS-1];
    logic [MEM_INDEX_W-1:0] pending_index [0:MSHRS-1];

    wire [MEM_INDEX_W-1:0] req_line_index =
        mem_req_addr[OFFSET_W +: MEM_INDEX_W];

    integer i, w;
    initial begin
        // Deterministic pattern: each 32-bit word initially contains its
        // word-aligned byte address. This makes expected reads easy to compute.
        for (i = 0; i < MEM_LINES; i = i + 1) begin
            for (w = 0; w < WORDS_PER_LINE; w = w + 1) begin
                mem[i][w*DATA_W +: DATA_W] =
                    (i * LINE_BYTES) + (w * DATA_BYTES);
            end
        end
    end

    always_comb begin
        if (mem_req_write)
            mem_req_ready = 1'b1;
        else
            mem_req_ready = !pending_valid[mem_req_mshr_id];
    end

    integer p;
    integer chosen;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            mem_resp_valid   <= 1'b0;
            mem_resp_mshr_id <= '0;
            mem_resp_rdata   <= '0;

            for (p = 0; p < MSHRS; p = p + 1) begin
                pending_valid[p] <= 1'b0;
                pending_count[p] <= '0;
                pending_index[p] <= '0;
            end
        end else begin
            if (mem_resp_valid && mem_resp_ready)
                mem_resp_valid <= 1'b0;

            // Accept a line writeback immediately, or launch a tagged read.
            if (mem_req_valid && mem_req_ready) begin
                if (mem_req_write) begin
                    mem[req_line_index] <= mem_req_wdata;
                end else begin
                    pending_valid[mem_req_mshr_id] <= 1'b1;
                    pending_count[mem_req_mshr_id] <= READ_LATENCY;
                    pending_index[mem_req_mshr_id] <= req_line_index;
                end
            end

            // Count down outstanding reads. A count of 1 means "ready to return".
            for (p = 0; p < MSHRS; p = p + 1) begin
                if (pending_valid[p] && pending_count[p] > 1)
                    pending_count[p] <= pending_count[p] - 1'b1;
            end

            // One response channel: choose the lowest-index completed request.
            if (!mem_resp_valid || mem_resp_ready) begin
                chosen = -1;
                for (p = 0; p < MSHRS; p = p + 1) begin
                    if ((chosen == -1) &&
                        pending_valid[p] &&
                        (pending_count[p] == 1)) begin
                        chosen = p;
                    end
                end

                if (chosen != -1) begin
                    mem_resp_valid   <= 1'b1;
                    mem_resp_mshr_id <= chosen[MSHR_W-1:0];
                    mem_resp_rdata   <= mem[pending_index[chosen]];
                    pending_valid[chosen] <= 1'b0;
                    pending_count[chosen] <= '0;
                end
            end
        end
    end

endmodule
