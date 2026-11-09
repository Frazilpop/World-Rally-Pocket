`default_nettype none

// One line of sprites into a line buffer, in the sprite RAM's order, as
// MAME's gaelco_wrally_sprites draws them.
//
// jlrh's engine fetched each sprite's graphics and waited for them before
// drawing, and cleared the bank (368 clocks) before the first: a line was
// 368 + 2 a slot passed over + 23 and an SDRAM wait for each sprite drawn.
// The attract puts 41 sprites on a line, so an average wait over 20 clocks
// cut it short. Here three parts overlap:
//
//   the scanner reads the sprite RAM: a slot off the line costs one clock,
//     one on the line but off the picture two, one to draw three, and its
//     description waits in `nx` while the drawer is busy;
//   the port fetches nx's graphics line (64 bits: both 8-pixel halves of
//     the sprite's row) as soon as it is there, while the drawer draws the
//     sprite before;
//   the drawer copies the line and draws its 16 pixels, a clock each.
//
// A drawn sprite then costs the longer of 17 clocks and its SDRAM wait, and
// no clock goes to clearing: the bank on show is cleared behind the
// display's read (lb_clr), ready for the line after.
module wrally_sprite_engine (
    input  wire        clk,
    input  wire        start,
    input  wire [8:0]  line,
    output wire        busy,

    output wire [10:0] spr_a,
    input  wire [15:0] spr_q,

    output wire [18:0] rom_a,
    input  wire [63:0] gfx_line,     // the line rom_a lies in, when gfx_ok
    input  wire        gfx_ok,

    input  wire [9:0]  lb_x,
    input  wire        lb_clr,       // clear the bank on show at lb_x
    output wire [11:0] lb_q,

    output wire        lb_high,

    input  wire        wbank,
    input  wire        rbank
);
    // ------------------------------------------------------------ scanner
    localparam [1:0] S_IDLE=0, S_W0=1, S_W2=2, S_W3=3;

    reg [1:0]  ss = S_IDLE;
    reg        hold = 1'b0;          // S_W3's sprite waiting for nx
    reg [10:0] spr_idx = 11'd3;
    reg [8:0]  line_r = 9'd0;
    reg [15:0] w0_r = 16'd0, w2_r = 16'd0, w3_r = 16'd0;

    wire       last   = (spr_idx[10:2] == 9'd510);      // slot 510, word 2043

    // on the line: its 16 rows from 240 - y
    wire [7:0] sy0    = 8'd240 - spr_q[7:0];
    wire [8:0] py0    = (line_r - {1'b0, sy0}) & 9'h1ff;
    wire       online0= (py0 < 9'd16);
    // A sprite none of whose 16 pixels lands in x 8-375 is passed over
    // without its fetch: the game parks its unused slots (all ffff) at
    // x 1008, on lines 241-256.
    wire [9:0] xs0    = (spr_q[9:0] - 10'd15) & 10'h3ff;
    wire       xvis0  = (xs0 <= 10'd375) || (xs0 >= 10'd1017);

    // ------------------------------------------------------------ nx
    reg        nx_v = 1'b0;
    reg [13:0] nx_code = 14'd0;
    reg [9:0]  nx_sx = 10'd0;
    reg [3:0]  nx_color = 4'd0;
    reg        nx_flipx = 1'b0, nx_shad = 1'b0, nx_high = 1'b0;
    reg [18:0] fa = 19'd0;           // the line the port holds or fetches

    // ------------------------------------------------------------ drawer
    localparam [1:0] D_IDLE=0, D_PRE=1, D_PWR=2;
    reg [1:0]  ds = D_IDLE;
    reg [3:0]  px = 4'd0;
    reg [63:0] dl = 64'd0;
    reg [9:0]  sx_r = 10'd0;
    reg [3:0]  color_r = 4'd0;
    reg        flipx_r = 1'b0, high_r = 1'b0, shad_r = 1'b0;
    reg        wbank_r = 1'b0;

    wire take = nx_v && gfx_ok && (ds == D_IDLE || (ds == D_PWR && px == 4'd15));
    wire in_w3 = (ss == S_W3);
    wire push = in_w3 && (!nx_v || take);

    assign busy = (ss != S_IDLE) || nx_v || (ds != D_IDLE);

    assign spr_a = start           ? 11'd3 :
                   (ss == S_W0)    ? (online0 ? spr_idx + 11'd2 : spr_idx + 11'd4) :
                   (ss == S_W2)    ? (xvis0   ? spr_idx + 11'd3 : spr_idx + 11'd4) :
                                     spr_idx + 11'd4;

    // the sprite in S_W3: its last word is spr_q on the first clock, w3_r
    // while it waits for nx
    wire [15:0] w3     = hold ? w3_r : spr_q;
    wire [7:0]  sy_c   = 8'd240 - w0_r[7:0];
    wire [8:0]  py_c   = (line_r - {1'b0, sy_c}) & 9'h1ff;
    wire [3:0]  gpy_c  = w0_r[15] ? (4'd15 - py_c[3:0]) : py_c[3:0];

    always @(posedge clk) begin
        if (start) begin
            line_r <= line; spr_idx <= 11'd3; ss <= S_W0; hold <= 1'b0;
        end else case (ss)
            S_W0: begin
                w0_r <= spr_q;
                if (online0)   ss <= S_W2;
                else if (last) ss <= S_IDLE;
                else           spr_idx <= spr_idx + 11'd4;
            end
            S_W2: begin
                w2_r <= spr_q;
                if (xvis0)     ss <= S_W3;
                else if (last) ss <= S_IDLE;
                else begin     spr_idx <= spr_idx + 11'd4; ss <= S_W0; end
            end
            S_W3: begin
                if (!hold) w3_r <= spr_q;
                if (push) begin
                    hold <= 1'b0;
                    if (last) ss <= S_IDLE;
                    else begin spr_idx <= spr_idx + 11'd4; ss <= S_W0; end
                end else hold <= 1'b1;
            end
            default: ;
        endcase
    end

    always @(posedge clk) begin
        if (start) nx_v <= 1'b0;
        else if (push) begin
            nx_v     <= 1'b1;
            nx_code  <= w3[13:0];
            nx_sx    <= w2_r[9:0];
            nx_color <= w2_r[13:10];
            nx_flipx <= w0_r[14];
            nx_shad  <= w2_r[14];
            nx_high  <= (w3[13:0] >= 14'h3700);
            fa       <= {w3[13:0], 1'b0, gpy_c};
        end else if (take) nx_v <= 1'b0;
    end

    assign rom_a = fa;

    always @(posedge clk) begin
        if (start) begin
            ds <= D_IDLE; wbank_r <= wbank;
        end else if (take) begin
            ds <= D_PRE; px <= 4'd0; dl <= gfx_line;
            sx_r <= nx_sx; color_r <= nx_color; flipx_r <= nx_flipx;
            shad_r <= nx_shad; high_r <= nx_high;
        end else case (ds)
            D_PRE: ds <= D_PWR;
            D_PWR: if (px == 4'd15) ds <= D_IDLE; else px <= px + 4'd1;
            default: ;
        endcase
    end

    // ------------------------------------------------------------ line buffers
    // {high, pixel} a word: one block RAM each, one write port and one
    // registered read port. jlrh read them combinationally (the display's
    // pixel, and the pixel under a shadow being drawn), which Quartus can
    // only build from registers. The bank being drawn and the bank on show
    // are never the same, so each RAM's read port serves whichever its bank
    // is: the display's address (hpos, steady for a pixel's six clocks, so
    // the word read on the clock before ce_pix is the one jlrh's read gave
    // on it), or the drawing's, issued a clock ahead for the pixel drawn
    // next (below). The write port of the bank on show clears each word on
    // the clock its pixel is taken (lb_clr): that clock's read is never used.
    (* ramstyle = "no_rw_check" *) reg [12:0] lb0 [0:367];
    (* ramstyle = "no_rw_check" *) reg [12:0] lb1 [0:367];
    reg [12:0] lb0_q = 13'd0, lb1_q = 13'd0;
    assign lb_q    = rbank ? lb1_q[11:0] : lb0_q[11:0];
    assign lb_high = rbank ? lb1_q[12]   : lb0_q[12];

    wire [3:0] gpx  = flipx_r ? (4'd15 - px) : px;
    wire [31:0] half = gpx[3] ? dl[63:32] : dl[31:0];   // {p3, p2, p1, p0}
    wire [2:0] bsel = 3'd7 - gpx[2:0];
    wire [3:0] pen  = { half[24 + bsel], half[16 + bsel], half[8 + bsel], half[bsel] };
    wire [9:0] sumx = (sx_r + {6'b0, px}) & 10'h3ff;
    wire [9:0] xpos = (sumx - 10'd15) & 10'h3ff;
    wire       xin  = (xpos >= 10'd8) && (xpos <= 10'd375);

    wire        spr_on = shad_r ? pen[3] : (pen != 4'd0);
    wire [11:0] lb_wd  = shad_r ? {1'b1, pen[2:0], 8'd0}
                                : {1'b0, 3'd0, color_r, pen};

    wire [9:0]  lb_wa    = (xpos - 10'd8);
    // The pixel under the one drawn now was read on the clock before: in
    // D_PWR the next pixel is px + 1, in D_PRE (one clock before every
    // sprite's 16, with its x already loaded) it is px. A pixel's write
    // never lands on the address read for the next.
    wire [3:0]  px_n     = (ds == D_PWR) ? px + 4'd1 : px;
    wire [9:0]  lb_ra    = ((((sx_r + {6'b0, px_n}) & 10'h3ff) - 10'd15) & 10'h3ff) - 10'd8;
    wire [12:0] lb_cur   = wbank_r ? lb1_q : lb0_q;
    // A shadow over a pixel already drawn (a sprite's or another shadow's)
    // keeps that pixel's pen and priority and ORs its level in, as MAME's
    // gaelco_wrally_sprites does (jlrh's replaced a shadow's level and
    // priority; no dump yet has one shadow over another to tell)
    wire        cur_any  = lb_cur[11] || (lb_cur[3:0] != 4'd0);
    wire [11:0] lb_mrg   = (shad_r && cur_any) ? {1'b1, lb_cur[10:8] | pen[2:0], lb_cur[7:0]} : lb_wd;
    wire        lb_keep  = shad_r && cur_any;

    wire        lb_we  = (ds == D_PWR) && spr_on && xin;
    wire [12:0] lb_wd9 = {lb_keep ? lb_cur[12] : high_r, lb_mrg};
    // the bank on show, never the one being drawn (wbank_r is the other
    // from the line's second clock, long before its first pixel)
    wire        clr0   = lb_clr && !rbank &&  wbank_r;
    wire        clr1   = lb_clr &&  rbank && !wbank_r;
    wire        we0    = (lb_we && !wbank_r) || clr0;
    wire        we1    = (lb_we &&  wbank_r) || clr1;
    wire [8:0]  wa0    = clr0 ? lb_x[8:0] : lb_wa[8:0];
    wire [8:0]  wa1    = clr1 ? lb_x[8:0] : lb_wa[8:0];
    wire [12:0] wd0    = clr0 ? 13'd0 : lb_wd9;
    wire [12:0] wd1    = clr1 ? 13'd0 : lb_wd9;

    always @(posedge clk) begin
        if (we0) lb0[wa0] <= wd0;
        if (we1) lb1[wa1] <= wd1;
        lb0_q <= lb0[!wbank_r ? lb_ra[8:0] : lb_x[8:0]];
        lb1_q <= lb1[ wbank_r ? lb_ra[8:0] : lb_x[8:0]];
    end

    // synthesis translate_off
    integer k;
    initial for (k = 0; k < 368; k = k + 1) begin lb0[k] = 0; lb1[k] = 0; end
    // synthesis translate_on
endmodule

`default_nettype wire
