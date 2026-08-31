`timescale 1ns/1ps

module l1_dcache #(
    parameter int ADDR_W = 32,
    parameter int DATA_W = 32,
    parameter int ID_W = 4,
    parameter int SETS = 64,
    parameter int LINE_BYTES = 64,
    parameter int MSHRS = 2,
    parameter bit ALLOW_HIT_UNDER_MISS = 1'b1
) (
    input  logic                      clk,
    input  logic                      rst_n,

    // CPU request channel
    input  logic                      cpu_req_valid,
    output logic                      cpu_req_ready,
    input  logic [ID_W-1:0]           cpu_req_id,
    input  logic [ADDR_W-1:0]         cpu_req_addr,
    input  logic                      cpu_req_write,
    input  logic [DATA_W-1:0]         cpu_req_wdata,
    input  logic [(DATA_W/8)-1:0]     cpu_req_wstrb,

    // CPU response channel
    output logic                      cpu_resp_valid,
    input  logic                      cpu_resp_ready,
    output logic [ID_W-1:0]           cpu_resp_id,
    output logic [DATA_W-1:0]         cpu_resp_rdata,

    // Abstract lower-memory line request channel
    output logic                      mem_req_valid,
    input  logic                      mem_req_ready,
    output logic                      mem_req_write,
    output logic [ADDR_W-1:0]         mem_req_addr,
    output logic [(LINE_BYTES*8)-1:0] mem_req_wdata,
    output logic [((MSHRS <= 1) ? 1 : $clog2(MSHRS))-1:0]
                                        mem_req_mshr_id,

    // Tagged lower-memory refill response channel
    input  logic                      mem_resp_valid,
    output logic                      mem_resp_ready,
    input  logic [((MSHRS <= 1) ? 1 : $clog2(MSHRS))-1:0]
                                        mem_resp_mshr_id,
    input  logic [(LINE_BYTES*8)-1:0] mem_resp_rdata,

    // Performance counters
    output logic [31:0]               perf_accesses,
    output logic [31:0]               perf_hits,
    output logic [31:0]               perf_misses,
    output logic [31:0]               perf_writebacks,
    output logic [31:0]               perf_mshr_stall_cycles,
    output logic [31:0]               perf_set_conflict_stalls
);

    localparam int WAYS           = 2;
    localparam int DATA_BYTES     = DATA_W / 8;
    localparam int LINE_W         = LINE_BYTES * 8;
    localparam int SET_W          = $clog2(SETS);
    localparam int OFFSET_W       = $clog2(LINE_BYTES);
    localparam int BYTE_OFF_W     = $clog2(DATA_BYTES);
    localparam int WORDS_PER_LINE = LINE_BYTES / DATA_BYTES;
    localparam int WORD_SEL_W     = $clog2(WORDS_PER_LINE);
    localparam int TAG_W          = ADDR_W - SET_W - OFFSET_W;
    localparam int RAM_DEPTH      = SETS * WORDS_PER_LINE;
    localparam int RAM_ADDR_W     = $clog2(RAM_DEPTH);
    localparam int MSHR_W         = (MSHRS <= 1) ? 1 : $clog2(MSHRS);

    // This implementation is intentionally specialized to two ways.
    initial begin
        if (WAYS != 2)
            $fatal(1, "This version expects exactly two ways.");
        if (DATA_W != 32)
            $fatal(1, "This BRAM version currently expects DATA_W=32.");
        if (WORDS_PER_LINE != 16)
            $fatal(1, "This BRAM version currently expects 64-byte lines.");
    end

    // ---------------------------------------------------------------------
    // Metadata arrays
    // ---------------------------------------------------------------------
    // Tags/valid/dirty/LRU are small and stay as registers/LUTRAM.
    logic [TAG_W-1:0] tag_array   [0:WAYS-1][0:SETS-1];
    logic             valid_array [0:WAYS-1][0:SETS-1];
    logic             dirty_array [0:WAYS-1][0:SETS-1];

    // lru[set] names the way to evict next.
    logic             lru         [0:SETS-1];

    // ---------------------------------------------------------------------
    // Data RAMs: one 4-KiB BRAM-backed word array per way
    // ---------------------------------------------------------------------
    logic [RAM_ADDR_W-1:0] way_a_addr;
    logic [DATA_W-1:0]     way0_a_rdata, way1_a_rdata;
    logic [DATA_BYTES-1:0] way0_a_we, way1_a_we;
    logic [DATA_W-1:0]     way_a_wdata;

    logic [RAM_ADDR_W-1:0] way_b_addr;
    logic [DATA_W-1:0]     way0_b_rdata, way1_b_rdata;
    logic [DATA_BYTES-1:0] way0_b_we, way1_b_we;
    logic [DATA_W-1:0]     way_b_wdata;

    cache_data_ram #(
        .DEPTH (RAM_DEPTH),
        .DATA_W(DATA_W)
    ) u_data_way0 (
        .clk    (clk),
        .a_addr (way_a_addr),
        .a_rdata(way0_a_rdata),
        .a_we   (way0_a_we),
        .a_wdata(way_a_wdata),
        .b_addr (way_b_addr),
        .b_rdata(way0_b_rdata),
        .b_we   (way0_b_we),
        .b_wdata(way_b_wdata)
    );

    cache_data_ram #(
        .DEPTH (RAM_DEPTH),
        .DATA_W(DATA_W)
    ) u_data_way1 (
        .clk    (clk),
        .a_addr (way_a_addr),
        .a_rdata(way1_a_rdata),
        .a_we   (way1_a_we),
        .a_wdata(way_a_wdata),
        .b_addr (way_b_addr),
        .b_rdata(way1_b_rdata),
        .b_we   (way1_b_we),
        .b_wdata(way_b_wdata)
    );

    // ---------------------------------------------------------------------
    // Utility function: apply CPU byte strobes to one 32-bit word.
    // ---------------------------------------------------------------------
    function automatic logic [DATA_W-1:0] merge_word(
        input logic [DATA_W-1:0] old_word,
        input logic [DATA_W-1:0] new_word,
        input logic [DATA_BYTES-1:0] wstrb
    );
        logic [DATA_W-1:0] tmp;
        integer b;
        begin
            tmp = old_word;
            for (b = 0; b < DATA_BYTES; b = b + 1) begin
                if (wstrb[b])
                    tmp[b*8 +: 8] = new_word[b*8 +: 8];
            end
            merge_word = tmp;
        end
    endfunction

    // ---------------------------------------------------------------------
    // MSHRs
    // ---------------------------------------------------------------------
    typedef enum logic [2:0] {
        MS_NEED_WB_CAPTURE,
        MS_WAIT_WB_SEND,
        MS_NEED_REFILL_REQ,
        MS_WAIT_REFILL,
        MS_REFILL_READY
    } mshr_state_t;

    typedef struct packed {
        logic                    valid;
        logic [ID_W-1:0]         req_id;
        logic [TAG_W-1:0]        req_tag;
        logic [SET_W-1:0]        set_idx;
        logic [WORD_SEL_W-1:0]   word_idx;
        logic                    is_write;
        logic [DATA_W-1:0]       wdata;
        logic [DATA_BYTES-1:0]   wstrb;

        logic                    victim_way;
        logic [TAG_W-1:0]        victim_tag;
        logic                    victim_dirty;

        mshr_state_t             state;
    } mshr_t;

    mshr_t mshr [0:MSHRS-1];

    // A refill may return before the BRAM maintenance engine is free.
    logic [LINE_W-1:0] refill_buffer [0:MSHRS-1];

    // ---------------------------------------------------------------------
    // One-cycle hit pipeline.
    //
    // Tags are checked combinationally when the request is accepted.
    // Data comes from synchronous BRAM on the following cycle.
    // ---------------------------------------------------------------------
    logic                 hit_pipe_valid;
    logic [ID_W-1:0]      hit_pipe_id;
    logic                 hit_pipe_way;
    logic                 hit_pipe_write;

    // ---------------------------------------------------------------------
    // Current request decode / lookup
    // ---------------------------------------------------------------------
    logic [SET_W-1:0]      req_set;
    logic [TAG_W-1:0]      req_tag;
    logic [WORD_SEL_W-1:0] req_word;

    logic way0_hit, way1_hit, cache_hit;
    logic hit_way;

    logic any_mshr;
    logic set_locked;
    logic free_found;
    logic [MSHR_W-1:0] free_mshr_idx;

    logic victim_way_comb;
    logic victim_valid_comb;
    logic victim_dirty_comb;
    logic [TAG_W-1:0] victim_tag_comb;

    // ---------------------------------------------------------------------
    // Maintenance engine
    // ---------------------------------------------------------------------
    typedef enum logic [1:0] {
        ENG_IDLE,
        ENG_WB_READ,
        ENG_REFILL_WRITE
    } eng_state_t;

    eng_state_t eng_state;
    logic [MSHR_W-1:0] eng_mshr;

    // WB read pipeline counters. Range 0..16.
    logic [4:0] wb_reads_issued;
    logic [4:0] wb_reads_captured;

    // Refill word being written, 0..15.
    logic [3:0] refill_word;

    // Only one full writeback buffer is needed because only one WB capture
    // engine operates at a time.
    logic              wb_pending;
    logic [MSHR_W-1:0] wb_mshr;
    logic [LINE_W-1:0] wb_buffer;

    logic engine_pick_found;
    logic [MSHR_W-1:0] engine_pick_mshr;
    logic engine_pick_refill;

    logic resp_slot_available;
    logic pipe_can_advance;
    logic refill_finishing_soon;
    logic refill_can_finish;

    // ---------------------------------------------------------------------
    // Request decode and policy
    // ---------------------------------------------------------------------
    integer i;
    always_comb begin
        req_set  = cpu_req_addr[OFFSET_W +: SET_W];
        req_tag  = cpu_req_addr[ADDR_W-1 -: TAG_W];
        req_word = cpu_req_addr[BYTE_OFF_W +: WORD_SEL_W];

        way0_hit = valid_array[0][req_set] &&
                   (tag_array[0][req_set] == req_tag);
        way1_hit = valid_array[1][req_set] &&
                   (tag_array[1][req_set] == req_tag);
        cache_hit = way0_hit || way1_hit;
        hit_way = way1_hit;

        any_mshr = 1'b0;
        set_locked = 1'b0;
        free_found = 1'b0;
        free_mshr_idx = '0;

        for (i = 0; i < MSHRS; i = i + 1) begin
            if (mshr[i].valid) begin
                any_mshr = 1'b1;
                if (mshr[i].set_idx == req_set)
                    set_locked = 1'b1;
            end

            if (!mshr[i].valid && !free_found) begin
                free_found = 1'b1;
                free_mshr_idx = i[MSHR_W-1:0];
            end
        end

        if (!valid_array[0][req_set])
            victim_way_comb = 1'b0;
        else if (!valid_array[1][req_set])
            victim_way_comb = 1'b1;
        else
            victim_way_comb = lru[req_set];

        victim_valid_comb = valid_array[victim_way_comb][req_set];
        victim_dirty_comb = dirty_array[victim_way_comb][req_set];
        victim_tag_comb   = tag_array[victim_way_comb][req_set];

        resp_slot_available = !cpu_resp_valid || cpu_resp_ready;

        // An old synchronous hit result may stay in the pipeline while the
        // response channel is backpressured. Do not issue another BRAM access
        // until that result can advance.
        pipe_can_advance = !hit_pipe_valid || resp_slot_available;

        // Prevent a newly accepted hit from reaching the response stage in the
        // same cycle that a refill is completing.
        refill_finishing_soon =
            (eng_state == ENG_REFILL_WRITE) && (refill_word >= 4'd14);

        cpu_req_ready = 1'b0;
        if (rst_n &&
            pipe_can_advance &&
            !set_locked &&
            !refill_finishing_soon &&
            !((!ALLOW_HIT_UNDER_MISS) && any_mshr)) begin

            if (cache_hit)
                cpu_req_ready = 1'b1;
            else
                cpu_req_ready = free_found;
        end
    end

    // CPU BRAM port A is driven by the currently presented request.
    assign way_a_addr  = {req_set, req_word};
    assign way_a_wdata = cpu_req_wdata;

    always_comb begin
        way0_a_we = '0;
        way1_a_we = '0;

        if (cpu_req_valid &&
            cpu_req_ready &&
            cache_hit &&
            cpu_req_write) begin

            if (hit_way == 1'b0)
                way0_a_we = cpu_req_wstrb;
            else
                way1_a_we = cpu_req_wstrb;
        end
    end

    // ---------------------------------------------------------------------
    // Select work for the single BRAM maintenance engine.
    // Refill completion is prioritized to free an MSHR quickly.
    // ---------------------------------------------------------------------
    integer e;
    always_comb begin
        engine_pick_found  = 1'b0;
        engine_pick_mshr   = '0;
        engine_pick_refill = 1'b0;

        for (e = 0; e < MSHRS; e = e + 1) begin
            if (!engine_pick_found &&
                mshr[e].valid &&
                (mshr[e].state == MS_REFILL_READY)) begin
                engine_pick_found  = 1'b1;
                engine_pick_mshr   = e[MSHR_W-1:0];
                engine_pick_refill = 1'b1;
            end
        end

        // Do not start a second WB capture while the previous full-line
        // writeback is still waiting for the lower-memory request port.
        if (!engine_pick_found && !wb_pending) begin
            for (e = 0; e < MSHRS; e = e + 1) begin
                if (!engine_pick_found &&
                    mshr[e].valid &&
                    (mshr[e].state == MS_NEED_WB_CAPTURE)) begin
                    engine_pick_found  = 1'b1;
                    engine_pick_mshr   = e[MSHR_W-1:0];
                    engine_pick_refill = 1'b0;
                end
            end
        end
    end

    // ---------------------------------------------------------------------
    // BRAM maintenance port B
    // ---------------------------------------------------------------------
    logic [WORD_SEL_W-1:0] wb_issue_word;
    logic [DATA_W-1:0] selected_b_rdata;
    logic [DATA_W-1:0] refill_raw_word;
    logic [DATA_W-1:0] refill_write_word;
    logic refill_word_is_store_target;
    logic refill_write_enable;

    always_comb begin
        way_b_addr  = '0;
        way0_b_we   = '0;
        way1_b_we   = '0;
        way_b_wdata = '0;

        wb_issue_word =
            (wb_reads_issued < WORDS_PER_LINE) ?
                wb_reads_issued[WORD_SEL_W-1:0] :
                (WORDS_PER_LINE-1);

        selected_b_rdata =
            mshr[eng_mshr].victim_way ? way1_b_rdata : way0_b_rdata;

        refill_raw_word =
            refill_buffer[eng_mshr][refill_word*DATA_W +: DATA_W];

        refill_word_is_store_target =
            mshr[eng_mshr].is_write &&
            (refill_word == mshr[eng_mshr].word_idx);

        if (refill_word_is_store_target) begin
            refill_write_word = merge_word(
                refill_raw_word,
                mshr[eng_mshr].wdata,
                mshr[eng_mshr].wstrb
            );
        end else begin
            refill_write_word = refill_raw_word;
        end

        // A final refill word is written only when its CPU response can also
        // retire. Earlier words can always be written.
        refill_can_finish =
            resp_slot_available && !hit_pipe_valid;

        refill_write_enable =
            (refill_word != (WORDS_PER_LINE-1)) || refill_can_finish;

        if (eng_state == ENG_WB_READ) begin
            way_b_addr = {
                mshr[eng_mshr].set_idx,
                wb_issue_word
            };
        end else if (eng_state == ENG_REFILL_WRITE) begin
            way_b_addr = {
                mshr[eng_mshr].set_idx,
                refill_word
            };
            way_b_wdata = refill_write_word;

            if (refill_write_enable) begin
                if (mshr[eng_mshr].victim_way == 1'b0)
                    way0_b_we = {DATA_BYTES{1'b1}};
                else
                    way1_b_we = {DATA_BYTES{1'b1}};
            end
        end
    end

    // ---------------------------------------------------------------------
    // Lower-memory request arbitration
    // A captured dirty victim is sent first; otherwise issue a refill read
    // for the first MSHR that needs one.
    // ---------------------------------------------------------------------
    logic mem_arb_found;
    integer a;
    always_comb begin
        mem_req_valid   = 1'b0;
        mem_req_write   = 1'b0;
        mem_req_addr    = '0;
        mem_req_wdata   = '0;
        mem_req_mshr_id = '0;
        mem_arb_found   = 1'b0;

        if (wb_pending) begin
            mem_req_valid   = 1'b1;
            mem_req_write   = 1'b1;
            mem_req_mshr_id = wb_mshr;
            mem_req_addr    = {
                mshr[wb_mshr].victim_tag,
                mshr[wb_mshr].set_idx,
                {OFFSET_W{1'b0}}
            };
            mem_req_wdata = wb_buffer;
            mem_arb_found = 1'b1;
        end

        for (a = 0; a < MSHRS; a = a + 1) begin
            if (!mem_arb_found &&
                mshr[a].valid &&
                (mshr[a].state == MS_NEED_REFILL_REQ)) begin

                mem_req_valid   = 1'b1;
                mem_req_write   = 1'b0;
                mem_req_mshr_id = a[MSHR_W-1:0];
                mem_req_addr    = {
                    mshr[a].req_tag,
                    mshr[a].set_idx,
                    {OFFSET_W{1'b0}}
                };
                mem_req_wdata   = '0;
                mem_arb_found   = 1'b1;
            end
        end
    end

    // Only accept a refill for an MSHR that is actually waiting for it.
    always_comb begin
        mem_resp_ready = 1'b0;
        if (mem_resp_valid) begin
            if (mshr[mem_resp_mshr_id].valid &&
                (mshr[mem_resp_mshr_id].state == MS_WAIT_REFILL))
                mem_resp_ready = 1'b1;
        end
    end

    // ---------------------------------------------------------------------
    // Sequential control
    // ---------------------------------------------------------------------
    integer s, w, m;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            cpu_resp_valid <= 1'b0;
            cpu_resp_id    <= '0;
            cpu_resp_rdata <= '0;

            hit_pipe_valid <= 1'b0;
            hit_pipe_id    <= '0;
            hit_pipe_way   <= 1'b0;
            hit_pipe_write <= 1'b0;

            perf_accesses            <= 32'd0;
            perf_hits                <= 32'd0;
            perf_misses              <= 32'd0;
            perf_writebacks          <= 32'd0;
            perf_mshr_stall_cycles   <= 32'd0;
            perf_set_conflict_stalls <= 32'd0;

            eng_state          <= ENG_IDLE;
            eng_mshr           <= '0;
            wb_reads_issued    <= '0;
            wb_reads_captured  <= '0;
            refill_word        <= '0;

            wb_pending <= 1'b0;
            wb_mshr    <= '0;
            wb_buffer  <= '0;

            for (s = 0; s < SETS; s = s + 1) begin
                lru[s] <= 1'b0;
                for (w = 0; w < WAYS; w = w + 1) begin
                    valid_array[w][s] <= 1'b0;
                    dirty_array[w][s] <= 1'b0;
                    tag_array[w][s]   <= '0;
                end
            end

            for (m = 0; m < MSHRS; m = m + 1) begin
                mshr[m]          <= '0;
                refill_buffer[m] <= '0;
            end
        end else begin
            // -------------------------------------------------------------
            // Response-channel consumption
            // -------------------------------------------------------------
            if (cpu_resp_valid && cpu_resp_ready)
                cpu_resp_valid <= 1'b0;

            // -------------------------------------------------------------
            // Retire a synchronous cache hit from the prior cycle.
            // Store hits already modified BRAM on their acceptance edge.
            // -------------------------------------------------------------
            if (hit_pipe_valid && resp_slot_available) begin
                cpu_resp_valid <= 1'b1;
                cpu_resp_id    <= hit_pipe_id;

                if (hit_pipe_write)
                    cpu_resp_rdata <= '0;
                else if (hit_pipe_way == 1'b0)
                    cpu_resp_rdata <= way0_a_rdata;
                else
                    cpu_resp_rdata <= way1_a_rdata;

                hit_pipe_valid <= 1'b0;
            end

            // -------------------------------------------------------------
            // Performance stall counters
            // -------------------------------------------------------------
            if (cpu_req_valid && set_locked)
                perf_set_conflict_stalls <= perf_set_conflict_stalls + 1'b1;

            if (cpu_req_valid &&
                !cpu_req_ready &&
                !set_locked &&
                !cache_hit &&
                !free_found)
                perf_mshr_stall_cycles <= perf_mshr_stall_cycles + 1'b1;

            // -------------------------------------------------------------
            // Accept a CPU request.
            // A hit is pipelined for one cycle. A miss allocates an MSHR.
            // -------------------------------------------------------------
            if (cpu_req_valid && cpu_req_ready) begin
                perf_accesses <= perf_accesses + 1'b1;

                if (cache_hit) begin
                    perf_hits <= perf_hits + 1'b1;

                    hit_pipe_valid <= 1'b1;
                    hit_pipe_id    <= cpu_req_id;
                    hit_pipe_way   <= hit_way;
                    hit_pipe_write <= cpu_req_write;

                    // The accepted way becomes MRU.
                    lru[req_set] <= ~hit_way;

                    if (cpu_req_write)
                        dirty_array[hit_way][req_set] <= 1'b1;
                end else begin
                    perf_misses <= perf_misses + 1'b1;

                    mshr[free_mshr_idx].valid        <= 1'b1;
                    mshr[free_mshr_idx].req_id       <= cpu_req_id;
                    mshr[free_mshr_idx].req_tag      <= req_tag;
                    mshr[free_mshr_idx].set_idx      <= req_set;
                    mshr[free_mshr_idx].word_idx     <= req_word;
                    mshr[free_mshr_idx].is_write     <= cpu_req_write;
                    mshr[free_mshr_idx].wdata        <= cpu_req_wdata;
                    mshr[free_mshr_idx].wstrb        <= cpu_req_wstrb;
                    mshr[free_mshr_idx].victim_way   <= victim_way_comb;
                    mshr[free_mshr_idx].victim_tag   <= victim_tag_comb;
                    mshr[free_mshr_idx].victim_dirty <=
                        victim_valid_comb && victim_dirty_comb;

                    if (victim_valid_comb && victim_dirty_comb)
                        mshr[free_mshr_idx].state <= MS_NEED_WB_CAPTURE;
                    else
                        mshr[free_mshr_idx].state <= MS_NEED_REFILL_REQ;
                end
            end

            // -------------------------------------------------------------
            // Lower-memory request completion
            // -------------------------------------------------------------
            if (mem_req_valid && mem_req_ready) begin
                if (mem_req_write) begin
                    // Full dirty victim line was accepted by lower memory.
                    wb_pending <= 1'b0;
                    mshr[mem_req_mshr_id].state <= MS_NEED_REFILL_REQ;
                    perf_writebacks <= perf_writebacks + 1'b1;
                end else begin
                    mshr[mem_req_mshr_id].state <= MS_WAIT_REFILL;
                end
            end

            // -------------------------------------------------------------
            // Tagged refill response capture.
            // The full line is buffered until the BRAM maintenance engine can
            // serialize it into sixteen 32-bit writes.
            // -------------------------------------------------------------
            if (mem_resp_valid && mem_resp_ready) begin
                refill_buffer[mem_resp_mshr_id] <= mem_resp_rdata;
                mshr[mem_resp_mshr_id].state    <= MS_REFILL_READY;
            end

            // -------------------------------------------------------------
            // Maintenance engine
            // -------------------------------------------------------------
            case (eng_state)

                ENG_IDLE: begin
                    wb_reads_issued   <= '0;
                    wb_reads_captured <= '0;
                    refill_word       <= '0;

                    if (engine_pick_found) begin
                        eng_mshr <= engine_pick_mshr;

                        if (engine_pick_refill) begin
                            eng_state   <= ENG_REFILL_WRITE;
                            refill_word <= 4'd0;
                        end else begin
                            eng_state          <= ENG_WB_READ;
                            wb_reads_issued    <= 5'd0;
                            wb_reads_captured  <= 5'd0;
                            wb_buffer          <= '0;
                        end
                    end
                end

                ENG_WB_READ: begin
                    // Issue one synchronous BRAM read address each cycle.
                    if (wb_reads_issued < WORDS_PER_LINE)
                        wb_reads_issued <= wb_reads_issued + 1'b1;

                    // Starting on the second cycle, capture the previous
                    // cycle's synchronous BRAM read result.
                    if ((wb_reads_issued > 0) &&
                        (wb_reads_captured < WORDS_PER_LINE)) begin

                        wb_buffer[
                            wb_reads_captured*DATA_W +: DATA_W
                        ] <= selected_b_rdata;

                        if (wb_reads_captured == (WORDS_PER_LINE-1)) begin
                            wb_pending <= 1'b1;
                            wb_mshr    <= eng_mshr;

                            mshr[eng_mshr].state <= MS_WAIT_WB_SEND;

                            wb_reads_issued   <= '0;
                            wb_reads_captured <= '0;
                            eng_state         <= ENG_IDLE;
                        end else begin
                            wb_reads_captured <= wb_reads_captured + 1'b1;
                        end
                    end
                end

                ENG_REFILL_WRITE: begin
                    if (refill_write_enable) begin
                        if (refill_word == (WORDS_PER_LINE-1)) begin
                            // Final BRAM word is written at this edge.
                            // Commit metadata and retire the original request.
                            tag_array[
                                mshr[eng_mshr].victim_way
                            ][
                                mshr[eng_mshr].set_idx
                            ] <= mshr[eng_mshr].req_tag;

                            valid_array[
                                mshr[eng_mshr].victim_way
                            ][
                                mshr[eng_mshr].set_idx
                            ] <= 1'b1;

                            dirty_array[
                                mshr[eng_mshr].victim_way
                            ][
                                mshr[eng_mshr].set_idx
                            ] <= mshr[eng_mshr].is_write;

                            lru[mshr[eng_mshr].set_idx]
                                <= ~mshr[eng_mshr].victim_way;

                            cpu_resp_valid <= 1'b1;
                            cpu_resp_id    <= mshr[eng_mshr].req_id;

                            if (mshr[eng_mshr].is_write) begin
                                cpu_resp_rdata <= '0;
                            end else begin
                                cpu_resp_rdata <= refill_buffer[eng_mshr][
                                    mshr[eng_mshr].word_idx*DATA_W +: DATA_W
                                ];
                            end

                            mshr[eng_mshr].valid <= 1'b0;
                            refill_word <= '0;
                            eng_state   <= ENG_IDLE;
                        end else begin
                            refill_word <= refill_word + 1'b1;
                        end
                    end
                end

                default: eng_state <= ENG_IDLE;
            endcase
        end
    end

    // ---------------------------------------------------------------------
    // Simulation-only invariants
    // ---------------------------------------------------------------------
    // synthesis translate_off
    always @(posedge clk) begin
        if (rst_n && cpu_req_valid && cpu_req_ready) begin
            assert (cpu_req_addr[1:0] == 2'b00)
                else $fatal(1, "CPU request must be 32-bit aligned.");

            assert (!(way0_hit && way1_hit))
                else $fatal(1, "Both ways hit for the same request.");
        end

        if (rst_n && mem_resp_valid && mem_resp_ready) begin
            assert (mshr[mem_resp_mshr_id].valid)
                else $fatal(1, "Refill response references an invalid MSHR.");

            assert (mshr[mem_resp_mshr_id].state == MS_WAIT_REFILL)
                else $fatal(1,
                    "Refill response arrived for an MSHR not waiting for refill.");
        end
    end

    generate
        if (MSHRS >= 2) begin : gen_same_set_assert
            always @(posedge clk) begin
                if (rst_n && mshr[0].valid && mshr[1].valid) begin
                    assert (mshr[0].set_idx != mshr[1].set_idx)
                        else $fatal(1,
                            "Two MSHRs must never lock the same set.");
                end
            end
        end
    endgenerate
    // synthesis translate_on

endmodule
