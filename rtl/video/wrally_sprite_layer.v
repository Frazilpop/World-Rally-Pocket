`default_nettype none

module wrally_sprite_layer #(
    parameter VVIS   = 232,
    parameter VTOTAL = 264
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        ce_pix,
    input  wire [8:0]  vpos,
    input  wire [9:0]  hpos,

    output wire [10:0] spr_a,
    input  wire [15:0] spr_q,

    output wire [18:0] rom_a,
    input  wire [63:0] gfx_line,
    input  wire        gfx_ok,

    output wire [11:0] lb_q,
    output wire        lb_high,
    output wire        busy,
    output wire        cut          // a line began with the last unfinished
);

    reg [8:0] vpos_d;
    always @(posedge clk) vpos_d <= vpos;
    wire line_change = (vpos != vpos_d);

    wire [8:0] next_vpos = (vpos == VTOTAL-1) ? 9'd0 : (vpos + 9'd1);

    wire       rbank = vpos[0];
    wire       wbank = next_vpos[0];

    reg        start;
    always @(posedge clk or posedge rst) begin
        if (rst) start <= 1'b0;
        else     start <= line_change;
    end

    assign cut = start & busy;

    wrally_sprite_engine u_spr (
        .clk(clk), .gfx_ok(gfx_ok),
        .start(start), .line(next_vpos + 9'd16),
        .busy(busy),
        .spr_a(spr_a), .spr_q(spr_q),
        .rom_a(rom_a), .gfx_line(gfx_line),
        .lb_x(hpos), .lb_clr(ce_pix && hpos < 10'd368), .lb_q(lb_q), .lb_high(lb_high),
        .wbank(wbank), .rbank(rbank)
    );
endmodule

`default_nettype wire
