// SPDX-License-Identifier: GPL-3.0-or-later
// World Rally (Pocket) — the board, Gaelco REF.930217 / 930705.
//
// Platform-neutral: no pins, no framework. The Pocket shell (pocket/) and
// the simulation harness (sim/wrally/) both host this module. It replaces
// jlrh's JTFRAME top (jtwrally_game.v) and keeps what is under it as jlrh
// wrote it, but where the bus trace and the frames against MAME, or the
// Pocket's memories, have changed it:
//
//   MC68000 @ 12 MHz      wrally_main: fx68k on board time (wrally_cpu_clk),
//                         the bus, the VRAM decryption, the shared RAM
//   DS5002FP @ 12 MHz     wrally_mcu (jt8051) inside wrally_main, with its
//                         32 KB SRAM filled from the ROM image
//   two TPC1020s          wrally_video_top: two tilemaps, the sprites, the
//                         priority mixer; wrally_vmem, the VRAM, palette and
//                         sprite RAM
//   OKI M6295 @ 1 MHz     wrally_oki (jt6295) and its bank, inside wrally_main
//
// SDRAM line ports (64-bit lines, in the layout tools/pocket/build_rom.py
// writes): 0 the 68000's program, 1 tilemap 0, 2 tilemap 1, 3 sprites, 4 the
// OKI's samples. A tile row – all four planes of all sixteen pixels – is one
// line.

`timescale 1ns/1ps
`default_nettype none

module wrally_board #(
    parameter int unsigned SDR_AW  = 25,
    parameter int unsigned NP      = 5,
    // Pixel clock = clk * PIX_NUM / PIX_DEN. 1/6 is jlrh's 8 MHz, a
    // 513 x 260 frame at 59.98 Hz (800,280 clocks). The harness sets
    // 6669/40000 to stretch the same frame to MAME's 60 Hz (800,000 clocks),
    // so its IRQs fall where MAME's do.
    parameter int unsigned PIX_NUM = 1,
    parameter int unsigned PIX_DEN = 6,
    // IRQ 6 every IRQ_DEN / IRQ_NUM 68000 clocks of board time, the first
    // IRQ_FIRST clocks after reset. 1/200070 is the video frame above;
    // MAME's 60 Hz is 1/200000.
    parameter int unsigned IRQ_NUM   = 1,
    parameter int unsigned IRQ_DEN   = 200070,
    parameter int unsigned IRQ_FIRST = 200070,
    // MCU_LAG: ticks the DS5002 sits out after reset (0 on the Pocket),
    // standing in for MAME's interleave, which runs the 68000 first in each
    // slice of one DS5002 machine cycle (12 ticks), so its DS5002 sees the
    // 68000's writes some ticks late.
    parameter int unsigned MCU_LAG  = 0
)(
    input  wire        clk,            // 48 MHz
    input  wire        rst,            // core reset; the board adds !rom_loaded

    // ROM read ports (SDRAM controller, slow side)
    output wire [NP-1:0]             rom_req,
    output wire [NP-1:0][SDR_AW:1]   rom_addr,
    input  wire [NP-1:0]             rom_ack,
    input  wire [NP-1:0][63:0]       rom_dout,

    // Loader snoop: the DS5002FP's SRAM image (bytes 0x100000-0x107fff).
    // dl_wr no more often than every other clock (each word is two byte
    // writes into the DS5002's RAM).
    input  wire        dl_wr,
    input  wire [24:1] dl_addr,
    input  wire [15:0] dl_data,
    input  wire        rom_loaded,

    // Video: 368 x 232 of a 513 x 260 frame
    output wire        ce_pix,
    output wire        hs, vs, hblank, vblank,
    output wire [7:0]  r, g, b,

    // Audio: the OKI, mono, 48 kHz strobes (jt6295's own)
    output wire signed [15:0] snd,
    output wire        snd_sample,

    // Inputs, active high. p1/p2 = {b2, b1, up, down, left, right}.
    input  wire [5:0]  p1, p2,
    input  wire [1:0]  coin, start,
    input  wire        service, test,
    // DSW as the 68000 reads it at 700000: SW1 high byte, SW2 low (MAME's)
    input  wire [15:0] dsw,

    // Freezes the game: board time stops (no credit, no ticks), so the
    // 68000, the DS5002, the OKI and IRQ 6 stand still. Video keeps running.
    input  wire        pause,

    // For the platform's diagnostics: board time behind wall time (ticks),
    // IRQ 6's tick.
    output wire [11:0] diag_owed,
    output wire        diag_irq
);

// SDRAM regions, word addresses
localparam [SDR_AW:1] W_MAINCPU = SDR_AW'(25'h0000000);
localparam [24:1]     W_DS5002  = 24'h080000;              // byte 0x0100000
localparam [SDR_AW:1] W_OKI     = SDR_AW'(25'h0100000);    // byte 0x0200000
localparam [SDR_AW:1] W_GFX     = SDR_AW'(25'h0180000);    // byte 0x0300000

// ================================================================ resets
wire cpu_rst = rst | ~rom_loaded;

// ================================================================ clocks
reg [31:0] pix_acc = 32'd0;
reg        ce_pix_r = 1'b0;
always @(posedge clk) begin
    if (pix_acc + PIX_NUM >= PIX_DEN) begin
        pix_acc  <= pix_acc + PIX_NUM - PIX_DEN;
        ce_pix_r <= 1'b1;
    end else begin
        pix_acc  <= pix_acc + PIX_NUM;
        ce_pix_r <= 1'b0;
    end
end
assign ce_pix = ce_pix_r;

// Board time: one tick per 68000 clock (wrally_cpu_clk), 12 MHz on average.
// The DS5002FP shares the 68000's 12 MHz (24 MHz / 2), so it takes one clock
// a tick (twelve to its machine cycle: jt8051 counts them itself); the OKI's
// 1 MHz is every twelfth tick; IRQ 6 is counted in ticks. The CPUs, the OKI
// and the interrupt keep MAME's lockstep whatever the SDRAM does. (jlrh: 12
// MHz and 1 MHz from the 48 MHz clock, the IRQ from the video timing.)
wire cpu_tick, cpu_lost;

reg  [7:0]  mcu_lag = 8'd0;
always @(posedge clk) begin
    if (cpu_rst)                           mcu_lag <= MCU_LAG[7:0];
    else if (cpu_tick && mcu_lag != 8'd0)  mcu_lag <= mcu_lag - 8'd1;
end
wire mcu_cen = cpu_tick & mcu_lag == 8'd0;

reg  [3:0]  oki_div = 4'd0;
always @(posedge clk) begin
    if (cpu_rst)       oki_div <= 4'd0;
    else if (cpu_tick) oki_div <= oki_div == 4'd11 ? 4'd0 : oki_div + 4'd1;
end
wire oki_cen = cpu_tick & oki_div == 4'd0;

// board_irq is the tick's own clock, not a register after it: wrally_main
// takes it to IPL in two clocks, so IPL always changes after this tick's phi2
// and before the next phi1, whether the CPU is running at 12 MHz or catching
// up at 24. A clock later and that would depend on the SDRAM.
//
// Ticks board time had to drop (cpu_lost: the SDRAM's waits ran the credit
// out) are counted too, one with each tick given until none is left, so
// IRQ 6 stays on the picture's vblank (World Rally 2: uncounted, the power-on
// ROM test left it at line 75, where the game's writes tore the picture).
// Nothing is dropped while the SDRAM keeps up.
reg  [31:0] irq_acc, irq_first;
reg         irq_run;
reg  [15:0] irq_lost;
wire        irq_two   = irq_lost != 16'd0;     // this tick counts a lost one too
wire [31:0] irq_step  = irq_two ? 2 * IRQ_NUM : IRQ_NUM;
wire [31:0] irq_fstep = irq_two ? 32'd2 : 32'd1;
wire        irq_wrap  = irq_acc + irq_step >= IRQ_DEN;
wire        irq_fwrap = irq_first <= irq_fstep;
wire        board_irq = cpu_tick && (irq_run ? irq_wrap : irq_fwrap);
always @(posedge clk) begin
    if (cpu_rst) begin
        irq_first <= IRQ_FIRST; irq_run <= 1'b0; irq_acc <= 32'd0; irq_lost <= 16'd0;
    end else begin
        if (cpu_tick) begin
            if (!irq_run) begin
                irq_first <= irq_first - irq_fstep;
                if (irq_fwrap) begin
                    irq_run <= 1'b1;
                    // a lost tick taken past the first IRQ starts the count
                    irq_acc <= irq_fstep - irq_first;
                end
            end else irq_acc <= irq_wrap ? irq_acc + irq_step - IRQ_DEN : irq_acc + irq_step;
        end
        if (cpu_lost && !(cpu_tick && irq_two)) begin
            if (irq_lost != 16'hffff) irq_lost <= irq_lost + 16'd1;
        end else if (!cpu_lost && cpu_tick && irq_two) irq_lost <= irq_lost - 16'd1;
    end
end

// ================================================================ inputs
wire [15:0] in_dsw, in_p1p2, in_wheel, in_system;
wrally_inputs u_inputs (
    .dsw(dsw),
    .p1_up(p1[3]), .p1_down(p1[2]), .p1_left(p1[1]), .p1_right(p1[0]),
    .p1_btn1(p1[4]), .p1_gear(p1[5]),
    .p2_up(p2[3]), .p2_down(p2[2]), .p2_left(p2[1]), .p2_right(p2[0]),
    .p2_btn1(p2[4]), .p2_gear(p2[5]),
    .coin1(coin[0]), .coin2(coin[1]), .start1(start[0]), .start2(start[1]),
    .service(service), .test(test),
    .port_dsw(in_dsw), .port_p1p2(in_p1p2), .port_wheel(in_wheel), .port_system(in_system)
);

// ================================================================ ROM ports
wire        main_cs, main_ok;
wire [19:1] main_addr;
wire [63:0] main_line;
wrally_romport #(.AW(SDR_AW)) u_rp_main (
    .clk(clk), .rst(cpu_rst),
    .cs(main_cs), .line(W_MAINCPU + {main_addr[19:3], 2'b00}),
    .ok(main_ok), .data(main_line),
    .rom_req(rom_req[0]), .rom_addr(rom_addr[0]), .rom_ack(rom_ack[0]), .rom_dout(rom_dout[0])
);
// SDRAM words are {byte 2w+1, byte 2w}; the 68000's are big-endian
wire [15:0] main_sw   = main_line[16*main_addr[2:1] +: 16];
wire [15:0] main_data = {main_sw[7:0], main_sw[15:8]};

// jlrh's graphics address is a byte of one of the four 512 KB chips (i13,
// i11, i09, i07 = planes 0-3): {tile, half, row}. The line is {tile, row};
// byte 4h + p of it is plane p of half h.
function automatic [SDR_AW:1] gfx_line(input [18:0] a);
    gfx_line = W_GFX + {a[18:5], a[3:0], 2'b00};
endfunction

wire [18:0] tm0_a, tm1_a, spr_ra;
wire        tm0_ok, tm1_ok, spr_ok;
wire [63:0] tm0_line, tm1_line, spr_line;
wire [19:0] oki_ra;
wire        oki_ok;
wire [63:0] oki_line;

wrally_romport #(.AW(SDR_AW)) u_rp_tm0 (
    .clk(clk), .rst(cpu_rst),
    .cs(1'b1), .line(gfx_line(tm0_a)), .ok(tm0_ok), .data(tm0_line),
    .rom_req(rom_req[1]), .rom_addr(rom_addr[1]), .rom_ack(rom_ack[1]), .rom_dout(rom_dout[1])
);
wrally_romport #(.AW(SDR_AW)) u_rp_tm1 (
    .clk(clk), .rst(cpu_rst),
    .cs(1'b1), .line(gfx_line(tm1_a)), .ok(tm1_ok), .data(tm1_line),
    .rom_req(rom_req[2]), .rom_addr(rom_addr[2]), .rom_ack(rom_ack[2]), .rom_dout(rom_dout[2])
);
wrally_romport #(.AW(SDR_AW)) u_rp_spr (
    .clk(clk), .rst(cpu_rst),
    .cs(1'b1), .line(gfx_line(spr_ra)), .ok(spr_ok), .data(spr_line),
    .rom_req(rom_req[3]), .rom_addr(rom_addr[3]), .rom_ack(rom_ack[3]), .rom_dout(rom_dout[3])
);
wrally_romport #(.AW(SDR_AW)) u_rp_oki (
    .clk(clk), .rst(cpu_rst),
    .cs(1'b1), .line(W_OKI + {oki_ra[19:3], 2'b00}), .ok(oki_ok), .data(oki_line),
    .rom_req(rom_req[4]), .rom_addr(rom_addr[4]), .rom_ack(rom_ack[4]), .rom_dout(rom_dout[4])
);
wire [7:0] oki_byte = oki_line[8*oki_ra[2:0] +: 8];

// the four planes of the half the address names
function automatic [31:0] gfx_planes(input [63:0] line, input h);
    gfx_planes = h ? line[63:32] : line[31:0];      // {p3, p2, p1, p0}
endfunction
wire [31:0] tm0_p = gfx_planes(tm0_line, tm0_a[4]);
wire [31:0] tm1_p = gfx_planes(tm1_line, tm1_a[4]);
wire [31:0] spr_p = gfx_planes(spr_line, spr_ra[4]);

// ================================================================ DS5002FP SRAM
// Filled from the image's ds5002 slot as the loader passes, a byte a clock:
// the low byte on the snoop's clock, the high byte on the next.
wire        dl_mcu = dl_wr && dl_addr >= W_DS5002 && dl_addr < W_DS5002 + 24'h4000;
wire [13:0] dl_mcu_w = dl_addr[14:1];
reg        dsr_hi_pend = 1'b0;
reg [13:0] dsr_hi_w;
reg [7:0]  dsr_hi_d;
always @(posedge clk) begin
    dsr_hi_pend <= dl_mcu;
    dsr_hi_w    <= dl_mcu_w;
    dsr_hi_d    <= dl_data[15:8];
end
wire        dsr_dl_we   = dl_mcu | dsr_hi_pend;
wire [14:0] dsr_dl_addr = dl_mcu ? {dl_mcu_w, 1'b0} : {dsr_hi_w, 1'b1};
wire [7:0]  dsr_dl_data = dl_mcu ? dl_data[7:0] : dsr_hi_d;

// ================================================================ main board
wire [13:0] vmem_addr; wire vmem_uds, vmem_lds, vmem_we;
wire        vmem_cs_vram, vmem_cs_pal, vmem_cs_spr;
wire [15:0] vmem_vram_wdata, vmem_io_wdata;
wire [15:0] cpu_vram_rd, cpu_pal_rd, cpu_spr_rd;
wire [15:0] vreg0, vreg1, vreg2, vreg3;
wire signed [13:0] snd14;

wrally_main u_main (
    .clk(clk), .rst(cpu_rst), .game_run(~pause), .oki_cen(oki_cen),
    .vblank_irq(board_irq),
    .prog_addr(main_addr), .prog_cs(main_cs), .prog_data(main_data), .prog_data_ok(main_ok),
    .oki_rom_addr(oki_ra), .oki_rom_data(oki_byte), .oki_rom_ok(oki_ok),
    .in_dsw(in_dsw), .in_p1p2(in_p1p2), .in_wheel(in_wheel), .in_system(in_system),
    .flip_screen(),
    .vmem_addr(vmem_addr), .vmem_uds(vmem_uds), .vmem_lds(vmem_lds), .vmem_we(vmem_we),
    .vmem_cs_vram(vmem_cs_vram), .vmem_cs_pal(vmem_cs_pal), .vmem_cs_spr(vmem_cs_spr),
    .vmem_vram_wdata(vmem_vram_wdata), .vmem_io_wdata(vmem_io_wdata),
    .vmem_vram_rdata(cpu_vram_rd), .vmem_pal_rdata(cpu_pal_rd), .vmem_spr_rdata(cpu_spr_rd),
    .vreg0(vreg0), .vreg1(vreg1), .vreg2(vreg2), .vreg3(vreg3),
    .sound(snd14), .snd_sample(snd_sample),
    .cpu_tick(cpu_tick), .cpu_hold(1'b0), .mcu_cen(mcu_cen), .cpu_owed(diag_owed), .cpu_lost(cpu_lost),
    .mcu_dl_addr(dsr_dl_addr), .mcu_dl_data(dsr_dl_data), .mcu_dl_we(dsr_dl_we)
);

// jlrh's level: jt6295's 14 bits times 12, clamped (the sound step checks it
// against MAME's)
wire signed [17:0] snd_g = $signed(snd14) * 18'sd12;
assign snd = snd_g >  18'sd32767 ?  16'sd32767 :
             snd_g < -18'sd32768 ? -16'sd32768 : snd_g[15:0];

// ================================================================ video
wire [13:0] vram_a0, vram_a1;
wire [31:0] vram_q0, vram_q1;
wire [9:0]  pal_a;
wire [12:0] palb_a;
wire [15:0] pal_q, palb_q;
wire [10:0] spr_a;
wire [15:0] spr_q;

wrally_vmem u_vmem (
    .clk(clk), .ce_pix(ce_pix),
    .cpu_addr(vmem_addr), .cpu_uds(vmem_uds), .cpu_lds(vmem_lds), .cpu_we(vmem_we),
    .cs_vram(vmem_cs_vram), .cs_pal(vmem_cs_pal), .cs_spr(vmem_cs_spr),
    .vram_wdata(vmem_vram_wdata), .io_wdata(vmem_io_wdata),
    .cpu_vram_rdata(cpu_vram_rd), .cpu_pal_rdata(cpu_pal_rd), .cpu_spr_rdata(cpu_spr_rd),
    .vram_a0(vram_a0), .vram_a1(vram_a1), .vram_q0(vram_q0), .vram_q1(vram_q1),
    .pal_a(pal_a), .palb_a(palb_a), .pal_q(pal_q), .palb_q(palb_q),
    .spr_a(spr_a), .spr_q(spr_q)
);

// The video's own vblank IRQ is left unused: IRQ 6 is board time's (above).
wire vblank_irq;
wrally_video_top u_video (
    .clk(clk), .clk96(clk), .rst(rst), .ce_pix(ce_pix),
    .vreg_l0y(vreg0), .vreg_l0x(vreg1), .vreg_l1y(vreg2), .vreg_l1x(vreg3),
    .vram_a0(vram_a0), .vram_q0(vram_q0), .rom_a0(tm0_a),
    .d0_i07(tm0_p[31:24]), .d0_i09(tm0_p[23:16]), .d0_i11(tm0_p[15:8]), .d0_i13(tm0_p[7:0]),
    .vram_a1(vram_a1), .vram_q1(vram_q1), .rom_a1(tm1_a),
    .d1_i07(tm1_p[31:24]), .d1_i09(tm1_p[23:16]), .d1_i11(tm1_p[15:8]), .d1_i13(tm1_p[7:0]),
    .gfx0_ok(tm0_ok), .gfx1_ok(tm1_ok),
    .pal_a(pal_a), .pal_q(pal_q), .palb_a(palb_a), .palb_q(palb_q),
    .spr_a(spr_a), .spr_q(spr_q), .srom_a(spr_ra),
    .sd_i07(spr_p[31:24]), .sd_i09(spr_p[23:16]), .sd_i11(spr_p[15:8]), .sd_i13(spr_p[7:0]),
    .spr_gfx_ok(spr_ok), .spr_en(1'b1),
    .vga_r(r), .vga_g(g), .vga_b(b),
    .hsync(hs), .vsync(vs), .hblank(hblank), .vblank(vblank), .de(),
    .ce_pix_o(), .vblank_irq(vblank_irq)
);
assign diag_irq = board_irq;

// ================================================================ harness probes
// Read by sim/wrally/tb_wrally.cpp for the bus traces; nothing uses them.
// Hierarchical, so Verilator only.
`ifdef VERILATOR
wire        dbg_as     /*verilator public_flat_rd*/ = ~u_main.ASn & ~(u_main.fc == 3'd7);
wire        dbg_rw     /*verilator public_flat_rd*/ = u_main.eRWn;
wire [23:1] dbg_eab    /*verilator public_flat_rd*/ = u_main.eab;
wire [15:0] dbg_dout   /*verilator public_flat_rd*/ = u_main.oEdb;
wire [15:0] dbg_din    /*verilator public_flat_rd*/ = u_main.iEdb;
wire [15:0] dbg_vdec   /*verilator public_flat_rd*/ = u_main.dec_word;
wire [1:0]  dbg_ds     /*verilator public_flat_rd*/ = {~u_main.UDSn, ~u_main.LDSn};
wire        dbg_irq    /*verilator public_flat_rd*/ = board_irq;
wire        dbg_vbirq  /*verilator public_flat_rd*/ = vblank_irq;
wire        dbg_x_rd   /*verilator public_flat_rd*/ = u_main.mcu_xrd;
wire        dbg_x_wr   /*verilator public_flat_rd*/ = u_main.mcu_xwr;
wire [15:0] dbg_x_addr /*verilator public_flat_rd*/ = u_main.mcu_xaddr;
wire [7:0]  dbg_x_dout /*verilator public_flat_rd*/ = u_main.mcu_xdout;
wire [7:0]  dbg_x_din  /*verilator public_flat_rd*/ = u_main.wram_mcu_q;
// jt8051 takes a MOVX read's byte on the cen of the micro-step that selects
// it (X_SRC, 22 in jt8051_param.vh), which may come after the access
wire        dbg_x_take /*verilator public_flat_rd*/ = u_main.mcu_cen && u_main.u_mcu.u_core.u_regs.src_sel == 5'd22;
wire [15:0] dbg_x_pc   /*verilator public_flat_rd*/ = u_main.u_mcu.core_rom_adr;
wire        dbg_cen    /*verilator public_flat_rd*/ = cpu_tick;
wire        dbg_lost   /*verilator public_flat_rd*/ = cpu_lost;
wire [9:0]  dbg_hcnt   /*verilator public_flat_rd*/ = u_video.u_timing.hcnt;
wire [8:0]  dbg_vcnt   /*verilator public_flat_rd*/ = u_video.u_timing.vcnt;
`endif

endmodule

`default_nettype wire
