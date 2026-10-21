`default_nettype none

module wrally_sprite_engine (
    input  wire        clk,
    input  wire        ce,
    input  wire        start,
    input  wire [8:0]  line,
    output reg         busy,
    output reg         done,

    output wire [10:0] spr_a,
    input  wire [15:0] spr_q,

    output wire [18:0] rom_a,
    input  wire [7:0]  d_i07, d_i09, d_i11, d_i13,
    input  wire        gfx_ok,

    input  wire [9:0]  lb_x,
    output wire [11:0] lb_q,

    output wire        lb_high,

    input  wire        wbank,
    input  wire        rbank
);
    localparam [3:0] IDLE=0, CLR=1, RDW0=2, RDW2=3, RDW3=4, TEST=5, PADDR=6, PWR=7, NEXT=8, DON=9;

    reg [3:0]  state;
    reg [10:0] spr_idx;
    reg [9:0]  clr_i;
    reg [8:0]  line_r;
    reg [15:0] w0_r, w2_r, w3_r;
    reg        flipx_r, flipy_r;
    reg [9:0]  sx_r;
    reg [3:0]  color_r, gpy_r, px;
    reg [13:0] code_r;

    // The two line buffers, {high, pixel} a word: one block RAM each, one
    // write port and one registered read port. jlrh read them
    // combinationally (the display's pixel, and the pixel under a shadow
    // being drawn), which Quartus can only build from registers. The bank
    // being drawn and the bank on show are never the same, so each RAM's
    // read port serves whichever its bank is: the display's address (hpos,
    // steady for a pixel's six clocks, so the word read on the clock before
    // ce_pix is the one jlrh's read gave on it), or the drawing's, issued a
    // clock ahead for the pixel drawn next (below).
    (* ramstyle = "no_rw_check" *) reg [12:0] lb0 [0:367];
    (* ramstyle = "no_rw_check" *) reg [12:0] lb1 [0:367];
    reg [12:0] lb0_q, lb1_q;
    reg       wbank_r;
    reg       high_r;
    reg       shad_r;
    assign lb_q    = rbank ? lb1_q[11:0] : lb0_q[11:0];
    assign lb_high = rbank ? lb1_q[12]   : lb0_q[12];

    assign spr_a = (state==CLR && clr_i==10'd367) ? 11'd3 :
                   (state==NEXT) ? (spr_idx + 11'd4) :
                   (state==RDW0) ? (spr_idx + 11'd2) :
                   (state==RDW2) ? (spr_idx + 11'd3) : 11'd0;

    wire [3:0] gpx = flipx_r ? (4'd15 - px) : px;
    assign rom_a = {code_r, 5'b00000} + {14'b0, gpx[3], gpy_r};

    wire [2:0] bsel = 3'd7 - gpx[2:0];
    wire [3:0] pen  = { d_i07[bsel], d_i09[bsel], d_i11[bsel], d_i13[bsel] };
    wire [9:0] sumx = (sx_r + {6'b0, px}) & 10'h3ff;
    wire [9:0] xpos = (sumx - 10'd15) & 10'h3ff;
    wire       xin  = (xpos >= 10'd8) && (xpos <= 10'd375);

    wire        spr_on = shad_r ? pen[3] : (pen != 4'd0);
    wire [11:0] lb_wd  = shad_r ? {1'b1, pen[2:0], 8'd0}
                                : {1'b0, 3'd0, color_r, pen};

    wire [9:0]  lb_wa    = (xpos - 10'd8);
    // The pixel under the one drawn now was read on the clock before: in
    // PWR the next pixel is px + 1, in PADDR (at least one clock before
    // every PWR run, with the sprite's x already loaded) it is px. A pixel's
    // write never lands on the address read for the next.
    wire [3:0]  px_n     = (state == PWR) ? px + 4'd1 : px;
    wire [9:0]  lb_ra    = ((((sx_r + {6'b0, px_n}) & 10'h3ff) - 10'd15) & 10'h3ff) - 10'd8;
    wire [12:0] lb_cur   = wbank_r ? lb1_q : lb0_q;
    // A shadow over a pixel already drawn (a sprite's or another shadow's)
    // keeps that pixel's pen and priority and ORs its level in, as MAME's
    // gaelco_wrally_sprites does (jlrh's replaced a shadow's level and
    // priority; no dump yet has one shadow over another to tell)
    wire        cur_any  = lb_cur[11] || (lb_cur[3:0] != 4'd0);
    wire [11:0] lb_mrg   = (shad_r && cur_any) ? {1'b1, lb_cur[10:8] | pen[2:0], lb_cur[7:0]} : lb_wd;
    wire        lb_keep  = shad_r && cur_any;

    wire        lb_we  = (state == CLR) || (state == PWR && spr_on && xin);
    wire [8:0]  lb_wa9 = (state == CLR) ? clr_i[8:0] : lb_wa[8:0];
    wire [12:0] lb_wd9 = (state == CLR) ? 13'd0 : {lb_keep ? lb_cur[12] : high_r, lb_mrg};

    // A sprite none of whose 16 pixels lands in x 8-375 is passed over
    // without its fetches: the game parks its unused slots (all ffff) at
    // x 1008, on lines 241-256, and fetching them for nothing left the
    // bottom lines' later sprites short of time.
    wire [9:0] xs_c   = (w2_r[9:0] - 10'd15) & 10'h3ff;
    wire       x_vis  = (xs_c <= 10'd375) || (xs_c >= 10'd1017);

    wire [7:0] sy_c   = 8'd240 - w0_r[7:0];
    wire [8:0] py_c   = (line_r - {1'b0, sy_c}) & 9'h1ff;
    wire       on_line= (py_c < 9'd16);

    wire [7:0] sy0    = 8'd240 - spr_q[7:0];
    wire [8:0] py0    = (line_r - {1'b0, sy0}) & 9'h1ff;
    wire       online0= (py0 < 9'd16);

    always @(posedge clk) begin
        if (ce && lb_we && !wbank_r) lb0[lb_wa9] <= lb_wd9;
        if (ce && lb_we &&  wbank_r) lb1[lb_wa9] <= lb_wd9;
        lb0_q <= lb0[!wbank_r ? lb_ra[8:0] : lb_x[8:0]];
        lb1_q <= lb1[ wbank_r ? lb_ra[8:0] : lb_x[8:0]];
    end

    always @(posedge clk) if (ce) begin
        done <= 1'b0;
        if (start) begin
            line_r <= line; clr_i <= 10'd0; busy <= 1'b1; wbank_r <= wbank; state <= CLR;
        end else case (state)
            IDLE: ;
            CLR:  begin clr_i <= clr_i + 1'b1; if (clr_i == 10'd367) begin spr_idx <= 11'd3; state <= RDW0; end end

            RDW0: begin w0_r <= spr_q; state <= online0 ? RDW2 : NEXT; end
            RDW2: begin w2_r <= spr_q; state <= RDW3; end
            RDW3: begin w3_r <= spr_q; state <= TEST; end
            TEST: begin
                flipx_r <= w0_r[14]; flipy_r <= w0_r[15];
                sx_r    <= w2_r[9:0]; color_r <= w2_r[13:10]; code_r <= w3_r[13:0];
                high_r  <= (w3_r[13:0] >= 14'h3700);
                shad_r  <= w2_r[14];
                if (on_line && x_vis) begin
                    gpy_r <= w0_r[15] ? (4'd15 - py_c[3:0]) : py_c[3:0];
                    px    <= 4'd0;
                    state <= PADDR;
                end else state <= NEXT;
            end

            PADDR: if (gfx_ok) state <= PWR;
            PWR:   begin
                if (px == 4'd15)            state <= NEXT;
                else if (px[2:0] == 3'd7) begin px <= px + 1'b1; state <= PADDR; end
                else                       begin px <= px + 1'b1; state <= PWR;   end
            end
            NEXT:  if (spr_idx < 11'd2041) begin spr_idx <= spr_idx + 11'd4; state <= RDW0; end
                   else state <= DON;
            DON:   begin done <= 1'b1; busy <= 1'b0; state <= IDLE; end
            default: state <= IDLE;
        endcase
    end

    // synthesis translate_off
    integer k;
    initial begin state=IDLE; busy=0; done=0; spr_idx=3; px=0; clr_i=0; wbank_r=0; high_r=0; shad_r=0;
        for (k=0;k<368;k=k+1) begin lb0[k]=0; lb1[k]=0; end lb0_q=0; lb1_q=0; end
    // synthesis translate_on
endmodule

`default_nettype wire
