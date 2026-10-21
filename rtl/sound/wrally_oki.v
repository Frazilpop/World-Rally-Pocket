`default_nettype none

module wrally_oki (
    input  wire        clk,
    input  wire        rst,
    input  wire        cen,

    input  wire        cs_oki,
    input  wire        rwn,
    input  wire [7:0]  din,
    output wire [7:0]  dout,

    input  wire [3:0]  okibank,

    output wire [19:0] sample_addr,
    input  wire [7:0]  sample_data,
    input  wire        sample_ok,

    output wire signed [13:0] sound,
    output wire        sample_tick
);

    reg  cs_d;
    always @(posedge clk) cs_d <= cs_oki & ~rwn;
    wire wr_pulse = (cs_oki & ~rwn) & ~cs_d;

`ifdef SIMULATION

    integer n_oki=0;
    always @(posedge clk) if (wr_pulse) begin
        if (n_oki<24) $display("OKIDBG #%0d din=%h (cmd OKI)", n_oki, din);
        n_oki <= n_oki+1;
    end
`endif

    // MAME's OKI acts on a write at once: a stop silences its channels, a
    // start sets a channel playing from the start of its phrase, and a start
    // on a channel still playing is ignored. jt6295 acts at each channel's
    // slot, once a sample (132 us): a stop is taken there, and a start's
    // first byte clears any stop not yet taken – the game stops a channel and
    // starts it again 54 us later, and jt6295 went on decoding the new phrase
    // from the old one's ADPCM state. And it starts a busy channel again.
    //
    // So the 68000's writes – and the bank's changes, so a stopping channel's
    // last reads keep their bank – go through a queue, handed on to jt6295 in
    // order: after a stop, once its channels have stopped and 40 us more;
    // after a start, once the phrase lookup has had 40 us. A start's second
    // byte loses the channels MAME has playing. At most four writes come
    // within 500 us (MAME, the race and 24,000 frames of attract), and none
    // waits much over a sample. The status the 68000 reads is MAME's:
    // `mbusy`, set by a start and cleared by a stop as they are written, and
    // following jt6295 when a phrase ends. Against MAME's voices
    // (tools/pocket/oki_model.py, match_oki_channels.py) every value of every
    // phrase is the same; a channel stopped and started in the same sample
    // changes one sample late.
    wire [7:0] jt_dout;
    wire [3:0] jt_busy = jt_dout[3:0];

    reg  [8:0] q [0:7];             // {bank, data}
    reg  [2:0] q_rd = 3'd0, q_wr = 3'd0;
    reg  [3:0] q_n  = 4'd0;
    reg        cmd2 = 1'b0;         // MAME's side: a start's second byte next
    reg        jcmd2 = 1'b0;        // jt6295's side
    reg  [3:0] mbusy = 4'd0;
    reg  [3:0] stq = 4'd0;          // a start written, not yet seen in jt6295
    reg  [3:0] lq  = 4'd0;          // ... and handed on
    reg  [3:0] spq = 4'd0;          // a stop written, not yet handed on
    reg  [3:0] jstop = 4'd0;        // a stop handed on, the channel not yet stopped
    reg  [5:0] gap = 6'd0;          // OKI clocks before the next hand-on
    reg  [3:0] bank_d = 4'd0;
    reg  [3:0] jt_bank = 4'd0;
    reg        jt_wr = 1'b0;
    reg  [7:0] jt_din = 8'd0;

    // The bank and the OKI are written in bus cycles of their own, never
    // together; were they, the bank would go in a clock later.
    wire       bank_chg = okibank != bank_d && !wr_pulse;
    wire [3:0] start_ch = din[7:4] & ~mbusy;
    wire [8:0] q_in = wr_pulse ? {1'b0, cmd2 ? {start_ch, din[3:0]} : din}
                               : {1'b1, 4'd0, okibank};
    wire       push = bank_chg | wr_pulse;
    wire [8:0] q_out = q[q_rd];
    wire       pop = q_n != 4'd0 && gap == 6'd0 && jstop == 4'd0 && !jt_wr;
    wire       pop_wr = pop && !q_out[8];

    reg  [3:0] n_mbusy, n_stq, n_lq, n_spq, n_jstop;
    always @(*) begin
        // a start seen in jt6295, a stop taken, a phrase's end
        n_stq   = stq & ~(lq & jt_busy);
        n_lq    = lq  & ~(lq & jt_busy);
        n_spq   = spq;
        n_jstop = jstop & jt_busy;
        n_mbusy = mbusy & (jt_busy | stq | spq | jstop);
        if (wr_pulse && cmd2) begin
            n_mbusy = n_mbusy | start_ch;
            n_stq   = n_stq | start_ch;
        end else if (wr_pulse && !din[7]) begin
            n_mbusy = n_mbusy & ~din[6:3];
            n_stq   = n_stq & ~din[6:3];
            n_lq    = n_lq & ~din[6:3];
            n_spq   = n_spq | din[6:3];
        end
        if (pop_wr && jcmd2)
            n_lq = n_lq | (q_out[7:4] & n_stq);
        else if (pop_wr && !q_out[7]) begin
            n_spq   = n_spq & ~q_out[6:3];
            n_jstop = n_jstop | q_out[6:3];
        end
    end

    always @(posedge clk) begin
        jt_wr <= 1'b0;
        if (rst) begin
            q_rd <= 3'd0; q_wr <= 3'd0; q_n <= 4'd0;
            cmd2 <= 1'b0; jcmd2 <= 1'b0; mbusy <= 4'd0;
            stq <= 4'd0; lq <= 4'd0; spq <= 4'd0; jstop <= 4'd0; gap <= 6'd0;
            bank_d <= okibank; jt_bank <= okibank;
        end else begin
            mbusy <= n_mbusy; stq <= n_stq; lq <= n_lq; spq <= n_spq; jstop <= n_jstop;
            if (push) begin
                q[q_wr] <= q_in;
                q_wr <= q_wr + 3'd1;
            end
            q_n <= q_n + {3'd0, push} - {3'd0, pop};
            if (bank_chg) bank_d <= okibank;
            if (wr_pulse) cmd2 <= !cmd2 && din[7];
            // jt6295 shows a stop as its channel's slot begins and keeps it
            // at the slot's end: the next write waits the slot (32 us) out
            if ((jstop & ~jt_busy) != 4'd0) gap <= 6'd40;
            else if (cen && gap != 6'd0) gap <= gap - 6'd1;
            if (pop) begin
                q_rd <= q_rd + 3'd1;
                if (q_out[8]) jt_bank <= q_out[3:0];
                else begin
                    jt_wr  <= 1'b1;
                    jt_din <= q_out[7:0];
                    jcmd2  <= !jcmd2 && q_out[7];
                    gap    <= jcmd2 ? 6'd40 : 6'd2;
                end
            end
        end
    end
    assign dout = {4'hf, mbusy};

    wire wrn = ~jt_wr;

    wire [17:0] core_addr;
    assign sample_addr = (core_addr < 18'h30000)
                         ? {2'b00, core_addr}
                         : {jt_bank, core_addr[15:0]};

    jt6295 #(.INTERPOL(0), .SAMPLE(0)) u_oki (
        .rst      ( rst         ),
        .clk      ( clk         ),
        .cen      ( cen         ),
        .ss       ( 1'b1        ),
        .wrn      ( wrn         ),
        .din      ( jt_din      ),
        .dout     ( jt_dout     ),
        .rom_addr ( core_addr   ),
        .rom_data ( sample_data ),
        .rom_ok   ( sample_ok   ),
        .sound    ( sound       ),
        .sample   ( sample_tick )
    );
endmodule

`default_nettype wire
