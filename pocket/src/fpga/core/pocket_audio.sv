// SPDX-License-Identifier: GPL-3.0-or-later
// World Rally for Analogue Pocket — the OKI's samples, evened out to wall
// time.
//
// WHY A FIFO AND NOT A REGISTER
//
// The board makes one sample on each of jt6295's 48 kHz strobes, and those
// are counted in board time (the OKI's 1 MHz is every twelfth tick), which
// keeps 12 MHz only on average: it stands still for each ROM line the 68000
// waits on, then catches up at 24 MHz. Held in a plain register and sampled
// at 48 kHz, two samples made during a catch-up could land inside one 48 kHz
// period and one would never be heard. So they go into a FIFO and come out
// at exactly 48 kHz of wall time, one every 1,000 clocks at 48 MHz, which is
// the same rate exactly (board time's credit is 12/48 of the 48 MHz clock),
// so the FIFO neither fills nor empties in the long run.
//
// PRIMING. Reading starts once PRIME samples are in, so the FIFO carries
// about PRIME x 21 us of slack against board time running late (the
// harness, through the shell's SDRAM controller: never more than a few
// microseconds owed once the game runs). If it runs dry, the last sample is
// held and reading waits for PRIME again; that is what happens under the
// Pocket's menu, when board time stops (`paused`): the sound holds one
// level, silent, and starts again cleanly after.

`default_nettype none

module pocket_audio #(
    parameter int unsigned PERIOD = 1000,   // 48 MHz / 48 kHz
    parameter int unsigned PRIME  = 8,
    parameter int unsigned DEPTH  = 16      // a power of two
)(
    input  wire               clk,          // 48 MHz
    input  wire               rst,
    input  wire               sample,       // din valid, one clock
    input  wire signed [15:0] din,
    input  wire               paused,       // board time stopped: running dry is expected
    output reg  signed [15:0] dout,
    output reg                under,        // one clock: ran dry while the game ran
    output reg                over          // one clock: a sample arrived with the FIFO full
);

    localparam int unsigned AW = $clog2(DEPTH);

    reg signed [15:0] mem [DEPTH];
    reg [AW:0]        wp, rp;
    reg [12:0]        div;
    reg               priming;
    wire [AW:0]       count = wp - rp;

    always @(posedge clk) begin
        under <= 1'b0;
        over  <= 1'b0;
        if (rst) begin
            wp <= '0; rp <= '0; div <= '0; priming <= 1'b1; dout <= 16'sd0;
        end else begin
            if (sample) begin
                if (count == DEPTH[AW:0]) over <= 1'b1;
                else begin
                    mem[wp[AW-1:0]] <= din;
                    wp <= wp + 1'b1;
                end
            end
            div <= (div == PERIOD[12:0] - 13'd1) ? 13'd0 : div + 13'd1;
            if (priming) begin
                if (count >= PRIME[AW:0]) priming <= 1'b0;
            end else if (div == 13'd0) begin
                if (count != '0) begin
                    dout <= mem[rp[AW-1:0]];
                    rp   <= rp + 1'b1;
                end else begin
                    priming <= 1'b1;
                    under   <= ~paused;
                end
            end
        end
    end

endmodule

`default_nettype wire
