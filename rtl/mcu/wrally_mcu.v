// SPDX-License-Identifier: GPL-3.0-or-later
// World Rally (Pocket) — the DS5002FP as jt8051.
//
// From World Rally 2 Pocket's wrally2_mcu (its jt8051 variant), in place of
// jlrh's wrally_mcu (Oregano's mc8051 through GHDL), which ran at 73 % of the
// DS5002's pace there. jt8051 (jotego): cen is the oscillator period, twelve
// to a machine cycle, so it takes the board's 12 MHz tick as it is, never on
// adjacent clocks. Laid out as jtframe_8751mcu: the core's buses registered on
// the next clock, the program read only on cen (rom_en), the MOVX data passed
// straight in. The internal RAM is the 8051's 128 bytes, zero at power-on as
// MAME's fresh NVRAM has it.
//
// MOVX: with MCON 0x88 and RPCTL 0x00 (MAME's settings for this board) the
// partition, 0x8000, lies above the 32 KB range, so every MOVX goes to the
// expanded bus – the shared RAM – and none to the DS5002's own SRAM (MAME,
// 2,400 frames of a race: 4,116,599 MOVX, all to the shared RAM). jt8051 has
// no MCON; the board decodes nothing.

`default_nettype none

module wrally_mcu (
    input  wire        clk,
    input  wire        rst,
    input  wire        cen,

    output wire [15:0] rom_addr,
    output wire        rom_en,
    input  wire [ 7:0] rom_byte,

    output wire        xdata_rd,
    output wire        xdata_wr,
    output wire [15:0] xdata_addr,
    output wire [ 7:0] xdata_dout,
    input  wire [ 7:0] xdata_din
);

    wire [15:0] core_rom_adr;
    wire [ 7:0] core_ram_q, core_ram_d;
    wire [ 6:0] core_ram_adr;
    wire        core_ram_wr;
    wire [ 7:0] core_datax_o;
    wire [15:0] core_adrx;
    wire        core_memx, core_wrx;

    reg [15:0] rom_addr_r = 16'd0;
    always @(posedge clk) rom_addr_r <= core_rom_adr;
    assign rom_addr = rom_addr_r;
    assign rom_en   = cen;

    jtframe_ram_rst #(.AW(7),.CEN_RD(1)) u_iram (
        .rst(rst), .clk(clk), .cen(cen),
        .addr(core_ram_adr), .data(core_ram_d), .we(core_ram_wr), .q(core_ram_q)
    );

    reg [15:0] x_addr_r = 16'd0;
    reg [ 7:0] x_dout_r = 8'd0;
    reg        x_wr_r = 1'b0, x_acc_r = 1'b0;
    always @(posedge clk) begin
        x_addr_r <= core_adrx;
        x_dout_r <= core_datax_o;
        x_wr_r   <= core_wrx;
        x_acc_r  <= core_memx;
    end
    assign xdata_addr = x_addr_r;
    assign xdata_dout = x_dout_r;
    assign xdata_rd   = x_acc_r & ~x_wr_r;
    assign xdata_wr   = x_acc_r &  x_wr_r;

`ifdef VERILATOR
    // jt8051's own check, behind SIMULATION there (which would also have the
    // jtframe RAMs load their SIMFILEs here)
    reg cen_l = 1'b0;
    always @(posedge clk) begin
        if (!rst && cen && cen_l) $fatal(1, "wrally_mcu: jt8051's cen on adjacent clocks");
        cen_l <= cen & ~rst;
    end
`endif

    jt8051 u_core (
        .rst(rst), .clk(clk), .cen(cen),
        .int0n(1'b1), .int1n(1'b1),
        .p0_i(8'hFF), .p1_i(8'hFF), .p2_i(8'hFF), .p3_i(8'hFF),
        .p0_o(), .p1_o(), .p2_o(), .p3_o(),
        .rom_data(rom_byte), .rom_addr(core_rom_adr),
        .ram_din(core_ram_q), .ram_dout(core_ram_d), .ram_addr(core_ram_adr), .ram_we(core_ram_wr),
        .x_din(xdata_din), .x_dout(core_datax_o), .x_addr(core_adrx),
        .x_wr(core_wrx), .x_acc(core_memx)
    );
endmodule

`default_nettype wire
