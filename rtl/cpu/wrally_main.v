`default_nettype none

module wrally_main (
    input  wire        clk,
    input  wire        rst,
    input  wire        game_run,
    input  wire        oki_cen,

    input  wire        vblank_irq,

    output wire [19:1] prog_addr,
    output wire        prog_cs,
    input  wire [15:0] prog_data,
    input  wire        prog_data_ok,

    output wire [19:0] oki_rom_addr,
    input  wire [7:0]  oki_rom_data,
    input  wire        oki_rom_ok,

    input  wire [15:0] in_dsw,
    input  wire [15:0] in_p1p2,
    input  wire [15:0] in_wheel,
    input  wire [15:0] in_system,

    output wire        flip_screen,
    output wire [13:0] vmem_addr,
    output wire        vmem_uds, vmem_lds,
    output wire        vmem_we,
    output wire        vmem_cs_vram, vmem_cs_pal, vmem_cs_spr,
    output wire [15:0] vmem_vram_wdata,
    output wire [15:0] vmem_io_wdata,
    input  wire [15:0] vmem_vram_rdata,
    input  wire [15:0] vmem_pal_rdata,
    input  wire [15:0] vmem_spr_rdata,
    output wire [15:0] vreg0, vreg1, vreg2, vreg3,

    output wire signed [13:0] sound,
    output wire        snd_sample,

    // Board time (wrally_cpu_clk): one tick per 68000 clock, 12 MHz on average
    output wire        cpu_tick,
    input  wire        cpu_hold,       // board time stands still
    input  wire        mcu_cen,        // the DS5002's clock: the tick, less MCU_LAG
    output wire [11:0] cpu_owed,       // board time behind wall time, in ticks
    output wire        cpu_lost,       // a tick dropped with the credit full

    // The DS5002FP's 32 KB SRAM, filled from the ROM image while the CPUs are
    // held in reset
    input  wire [14:0] mcu_dl_addr,
    input  wire [ 7:0] mcu_dl_data,
    input  wire        mcu_dl_we
);

    wire [23:1] eab;
    wire        ASn, LDSn, UDSn, eRWn;
    wire [15:0] oEdb;
    reg  [15:0] iEdb;
    wire        DTACKn;
    reg         VPAn;
    wire        FC0, FC1, FC2;
    reg         IPL2n;
    wire [2:0]  fc = {FC2, FC1, FC0};
    wire        cpu_cen, cpu_cenb, cpu_mid;

    fx68k u_cpu (
        .clk(clk), .HALTn(1'b1),
        .extReset(rst), .pwrUp(rst),
        .enPhi1(cpu_cen), .enPhi2(cpu_cenb),
        .eRWn(eRWn), .ASn(ASn), .LDSn(LDSn), .UDSn(UDSn),
        .E(), .VMAn(), .FC0(FC0), .FC1(FC1), .FC2(FC2),
        .BGn(), .oRESETn(), .oHALTEDn(),
        .DTACKn(DTACKn), .VPAn(VPAn), .BERRn(1'b1),
        .BRn(1'b1), .BGACKn(1'b1),

        .IPL0n(1'b1), .IPL1n(IPL2n), .IPL2n(IPL2n),
        .iEdb(iEdb), .oEdb(oEdb), .eab(eab)
    );

    wire [23:0] addr = {eab, 1'b0};
    wire        uds  = ~UDSn;
    wire        lds  = ~LDSn;
    wire        rw_rd = eRWn;

    wire cs_rom, cs_vram, cs_vregs, cs_clrint, cs_pal, cs_spr,
         cs_dsw, cs_p1p2, cs_wheel, cs_system, cs_outlatch, cs_okibank, cs_oki, cs_wram;
    wrally_addr_decode u_dec (
        .addr(addr), .as(~ASn),
        .cs_rom(cs_rom), .cs_vram(cs_vram), .cs_vregs(cs_vregs), .cs_clrint(cs_clrint),
        .cs_pal(cs_pal), .cs_spr(cs_spr), .cs_dsw(cs_dsw), .cs_p1p2(cs_p1p2),
        .cs_wheel(cs_wheel), .cs_system(cs_system), .cs_outlatch(cs_outlatch),
        .cs_okibank(cs_okibank), .cs_oki(cs_oki), .cs_wram(cs_wram)
    );

    reg [15:0] vregs[0:3];

    wire [15:0] wram_cpu_q;
    wire [15:0] wram_mcu_q16;
    wire [15:0] wram_cpu_q_raw;
    wire [15:0] wram_mcu_q16_raw;

    assign prog_addr = eab[19:1];
    assign prog_cs   = cs_rom & rw_rd;
    wire [15:0] rom_word = prog_data;

    // Board time in place of jtframe's cen/DTACK (wrally_68kdtack): the CPU is
    // not clocked while a program read waits for its SDRAM line, so it never
    // sees a wait state.
    wire bus_busy  = cs_rom & rw_rd & ~prog_data_ok;
    wire dtack_raw;
    wrally_cpu_clk u_clk (
        .rst(rst), .clk(clk), .run(game_run),
        .ASn(ASn), .rom_wait(bus_busy), .hold(cpu_hold),
        .cpu_cen(cpu_cen), .cpu_cenb(cpu_cenb), .tick(cpu_tick), .mid(cpu_mid),
        .DTACKn(dtack_raw), .owed(cpu_owed), .lost(cpu_lost)
    );

    assign DTACKn = (fc == 3'd7) ? 1'b1 : dtack_raw;

    assign vreg0 = vregs[0]; assign vreg1 = vregs[1];
    assign vreg2 = vregs[2]; assign vreg3 = vregs[3];

    assign vmem_addr       = addr[13:0];
    assign vmem_uds        = uds;
    assign vmem_lds        = lds;
    assign vmem_cs_vram    = cs_vram;
    assign vmem_cs_pal     = cs_pal;
    assign vmem_cs_spr     = cs_spr;
    assign vmem_we         = wr_ack & ~rw_rd & (cs_vram | cs_pal | cs_spr);
    assign vmem_vram_wdata = dec_word;
    assign vmem_io_wdata   = oEdb;

    wire [15:0] dec_word;
    reg  [15:0] vdec_last_enc, vdec_last_dec;
    reg  [12:0] vdec_prev_woff;
    reg         vdec_prev_wr;

    reg  [12:0] pend_woff;
    reg  [15:0] pend_enc, pend_dec;
    reg         pend_is2nd, pend_vramwr;
    wire [12:0] cur_woff = addr[13:1];
    wire        is2nd = vdec_prev_wr & (vdec_prev_woff == (cur_woff - 13'd1));

    reg         is2nd_lat = 1'b0;
    wrally_vram_decrypt u_decrypt (
        .enc_prev(is2nd ? vdec_last_enc : 16'd0),
        .dec_prev(is2nd ? vdec_last_dec : 16'd0),
        .enc(oEdb),
        .dec(dec_word)
    );

    always @(*) begin
        iEdb = 16'hFFFF;
        case (1'b1)
            cs_rom:   iEdb = rom_word;
            cs_vram:  iEdb = vmem_vram_rdata;
            cs_pal:   iEdb = vmem_pal_rdata;
            cs_spr:   iEdb = vmem_spr_rdata;
            cs_vregs: iEdb = vregs[addr[2:1]];
            cs_wram:  iEdb = wram_cpu_q;
            cs_dsw:   iEdb = in_dsw;
            cs_p1p2:  iEdb = in_p1p2 | {8'h00, ~outlatch[1:0], 6'h00};
            cs_wheel: iEdb = in_wheel;
            cs_system:iEdb = in_system;
            cs_oki:   iEdb = {8'hFF, oki_dout};
            default:  iEdb = 16'hFFFF;
        endcase
    end

    reg asn_d, asn_dd;
    wire as_falling = (~ASn) & asn_d;
    wire as_rising  = ASn & (~asn_d);

    wire wr_ack = (~ASn) & (~asn_d);

    // The I/O writes take the data when the data strobes come out (a write's
    // come a phase after AS, with the data valid): on board time that phase
    // can be many clocks long, and a strobe taken with AS would latch the bus
    // before the 68000 drives it.
    reg  ds_d;
    wire io_wr = ~ASn & ~rw_rd & (uds | lds) & ~ds_d & (fc != 3'd7);

    reg irq_pending;

    reg outlatch_stb, okibank_stb, oki_wr_stb;
    reg [7:0] bus_lo;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            asn_d         <= 1'b1;
            asn_dd        <= 1'b1;
            ds_d          <= 1'b0;
            is2nd_lat     <= 1'b0;
            VPAn          <= 1'b1;
            irq_pending   <= 1'b0;
            IPL2n         <= 1'b1;
            vdec_prev_wr  <= 1'b0;
            vdec_prev_woff<= 13'd0;
            vdec_last_enc <= 16'd0;
            vdec_last_dec <= 16'd0;
            pend_woff     <= 13'd0;
            pend_enc      <= 16'd0;
            pend_dec      <= 16'd0;
            pend_is2nd    <= 1'b0;
            pend_vramwr   <= 1'b0;
            outlatch_stb  <= 1'b0;
            okibank_stb   <= 1'b0;
            oki_wr_stb    <= 1'b0;
        end else begin
            asn_d        <= ASn;
            asn_dd       <= asn_d;
            ds_d         <= ~ASn & (uds | lds);
            if (as_falling) is2nd_lat <= is2nd;
            outlatch_stb <= 1'b0;
            okibank_stb  <= 1'b0;
            oki_wr_stb   <= 1'b0;

            if (vblank_irq) irq_pending <= 1'b1;
            // IPL moves with phi2's clock or after it, never between phi1 and
            // phi2: where it lands against the phases decides which instruction
            // takes the IRQ, and a hold of board time can come between them
            if (!cpu_mid) IPL2n <= ~irq_pending;

            if (~ASn) begin
                if (fc == 3'd7) VPAn <= 1'b0;
                else            VPAn <= 1'b1;
            end else begin
                VPAn <= 1'b1;
            end

            if (wr_ack) begin
                if (fc == 3'd7) begin
                    irq_pending <= 1'b0;
                end else if (~rw_rd) begin
                    if (cs_vregs) begin
                        if (uds) vregs[addr[2:1]][15:8] <= oEdb[15:8];
                        if (lds) vregs[addr[2:1]][7:0]  <= oEdb[7:0];
                    end
                    if (cs_clrint) irq_pending <= 1'b0;
                end
            end
            if (io_wr) begin
                if (cs_outlatch) outlatch_stb <= 1'b1;
                if (cs_okibank)  okibank_stb  <= 1'b1;
                if (cs_oki)      oki_wr_stb   <= 1'b1;
                bus_lo <= oEdb[7:0];
            end

            if (~ASn) begin
                pend_woff   <= cur_woff;
                pend_enc    <= oEdb;
                pend_dec    <= dec_word;
                pend_is2nd  <= is2nd;
                pend_vramwr <= (~rw_rd) & cs_vram;
            end
            if (as_rising) begin
                if (pend_vramwr) begin

                    vdec_prev_wr   <= 1'b1;
                    vdec_prev_woff <= pend_woff;
                    vdec_last_enc  <= pend_enc;
                    vdec_last_dec  <= pend_dec;
                end else begin
                    vdec_prev_wr <= 1'b0;
                end
            end
        end
    end

    // Q0 and Q1 low lock the coin mechanisms out: a coin is turned back and
    // its switch never closes. MAME (coin_lockout, on by default) reads the
    // coin as not pressed then, and so does this.
    wire [3:0] okibank;
    wire [7:0] outlatch;
    wrally_iolatch u_iolatch (
        .clk(clk), .reset(rst),
        .cs_outlatch(outlatch_stb), .outlatch_a(addr[6:4]), .outlatch_d0(bus_lo[0]),
        .outlatch(outlatch),
        .cs_okibank(okibank_stb), .okibank_in(bus_lo[3:0]), .okibank(okibank),
        .flip_screen(flip_screen)
    );

    wire [7:0] oki_dout;
    wrally_oki u_oki (
        .clk(clk), .rst(rst), .cen(oki_cen),
        .cs_oki(oki_wr_stb), .rwn(1'b0), .din(bus_lo), .dout(oki_dout),
        .okibank(okibank),
        .sample_addr(oki_rom_addr), .sample_data(oki_rom_data), .sample_ok(oki_rom_ok),
        .sound(sound), .sample_tick(snd_sample)
    );

    // ---------------------------------------------------------------- DS5002FP
    // jt8051 (wrally_mcu) in place of mc8051. Its program is the 32 KB SRAM,
    // one copy: written by the loader while both CPUs are in reset, read by
    // the program fetch (on cen only) after. Every MOVX goes to the shared RAM
    // (wrally_mcu): the DS5002's 0x0000-0xffff, 16 KB mirrored.
    wire        mcu_xrd, mcu_xwr;
    wire [15:0] mcu_xaddr;
    wire [7:0]  mcu_xdout;
    wire [15:0] mcu_rom_addr;
    wire        mcu_rom_en;
    reg  [7:0]  mcurom_q;
    wire [7:0]  wram_mcu_q;

    (* ramstyle = "no_rw_check" *) reg [7:0] dsram [0:32767];
    always @(posedge clk) begin
        if (mcu_dl_we) dsram[mcu_dl_addr] <= mcu_dl_data;
        else if (mcu_rom_en) mcurom_q <= dsram[mcu_rom_addr[14:0]];
    end

    wrally_mcu u_mcu (
        .clk(clk), .rst(rst), .cen(mcu_cen),
        .rom_addr(mcu_rom_addr), .rom_en(mcu_rom_en), .rom_byte(mcurom_q),
        .xdata_rd(mcu_xrd), .xdata_wr(mcu_xwr), .xdata_addr(mcu_xaddr),
        .xdata_dout(mcu_xdout), .xdata_din(wram_mcu_q)
    );

    reg        mcu_rd_addr0_q;
    always @(posedge clk) mcu_rd_addr0_q <= mcu_xaddr[0];

    assign wram_mcu_q = mcu_rd_addr0_q ? wram_mcu_q16[7:0]
                                       : wram_mcu_q16[15:8];

    wire        wr68_wram = wr_ack & ~rw_rd & cs_wram & (fc != 3'd7);

    wire        mcu_src_we  = mcu_xwr;
    wire [12:0] mcu_src_adr = mcu_xaddr[13:1];
    wire [15:0] mcu_src_dat = {mcu_xdout, mcu_xdout};
    wire        mcu_src_whi = ~mcu_xaddr[0];
    wire        mcu_src_wlo =  mcu_xaddr[0];

    jtframe_dual_ram16 #(.AW(13)) u_wram (
        .clk0 ( clk ),
        .data0( oEdb ),
        .addr0( addr[13:1] ),
        .we0  ( {uds, lds} & {2{wr68_wram}} ),
        .q0   ( wram_cpu_q_raw ),
        .clk1 ( clk ),
        .data1( mcu_src_dat ),
        .addr1( mcu_src_adr ),
        .we1  ( {mcu_src_whi, mcu_src_wlo} & {2{mcu_src_we}} ),
        .q1   ( wram_mcu_q16_raw )
    );

    reg  [12:0] fwd_w68_adr, fwd_mcuw_adr, fwd_cpurd_adr, fwd_mcurd_adr;
    reg  [15:0] fwd_w68_dat, fwd_mcuw_dat;
    reg  [ 1:0] fwd_w68_we,  fwd_mcuw_we;
    reg         fwd_cpu_rd,  fwd_mcu_rd;
    wire [ 1:0] w68_we_now  = {uds, lds} & {2{wr68_wram}};
    wire [ 1:0] mcuw_we_now = {mcu_src_whi, mcu_src_wlo} & {2{mcu_src_we}};
    always @(posedge clk) begin
        fwd_w68_adr   <= addr[13:1];        fwd_w68_dat <= oEdb;        fwd_w68_we  <= w68_we_now;
        fwd_mcuw_adr  <= mcu_src_adr;       fwd_mcuw_dat<= mcu_src_dat; fwd_mcuw_we <= mcuw_we_now;
        fwd_cpurd_adr <= addr[13:1];        fwd_cpu_rd  <= ~(|w68_we_now);
        fwd_mcurd_adr <= mcu_xaddr[13:1];   fwd_mcu_rd  <= ~mcu_src_we;
    end

    wire mcu_fwd_hit = fwd_mcu_rd & (fwd_w68_adr == fwd_mcurd_adr);
    assign wram_mcu_q16 = {
        (mcu_fwd_hit & fwd_w68_we[1]) ? fwd_w68_dat[15:8] : wram_mcu_q16_raw[15:8],
        (mcu_fwd_hit & fwd_w68_we[0]) ? fwd_w68_dat[ 7:0] : wram_mcu_q16_raw[ 7:0] };

    wire cpu_fwd_hit = fwd_cpu_rd & (fwd_mcuw_adr == fwd_cpurd_adr);
    assign wram_cpu_q = {
        (cpu_fwd_hit & fwd_mcuw_we[1]) ? fwd_mcuw_dat[15:8] : wram_cpu_q_raw[15:8],
        (cpu_fwd_hit & fwd_mcuw_we[0]) ? fwd_mcuw_dat[ 7:0] : wram_cpu_q_raw[ 7:0] };

endmodule

`default_nettype wire
