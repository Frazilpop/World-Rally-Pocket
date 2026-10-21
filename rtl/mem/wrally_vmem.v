`default_nettype none

module wrally_vmem (
    input  wire        clk,
    input  wire        ce_pix,

    input  wire [13:0] cpu_addr,
    input  wire        cpu_uds, cpu_lds,
    input  wire        cpu_we,
    input  wire        cs_vram, cs_pal, cs_spr,
    input  wire [15:0] vram_wdata,
    input  wire [15:0] io_wdata,
    output wire [15:0] cpu_vram_rdata,
    output reg  [15:0] cpu_pal_rdata,
    output reg  [15:0] cpu_spr_rdata,

    input  wire [13:0] vram_a0, vram_a1,
    output reg  [31:0] vram_q0, vram_q1,
    input  wire [9:0]  pal_a,
    input  wire [12:0] palb_a,
    output reg  [15:0] pal_q, palb_q,
    input  wire [10:0] spr_a,
    output reg  [15:0] spr_q
);

`ifdef VERILATOR
    // The harness's scene mode (tb_wrally --scene) writes a MAME dump in
    // here, a word a clock: sc_sel 0 the VRAM (8K words, decrypted), 1 the
    // palette (8K), 2 the sprite RAM (2K).
    reg        sc_we   /*verilator public_flat_rw*/ = 1'b0;
    reg [1:0]  sc_sel  /*verilator public_flat_rw*/ = 2'd0;
    reg [12:0] sc_addr /*verilator public_flat_rw*/ = 13'd0;
    reg [15:0] sc_data /*verilator public_flat_rw*/ = 16'd0;
`else
    wire        sc_we   = 1'b0;
    wire [1:0]  sc_sel  = 2'd0;
    wire [12:0] sc_addr = 13'd0;
    wire [15:0] sc_data = 16'd0;
`endif
    wire sc_vram = sc_we && sc_sel == 2'd0;
    wire sc_pal  = sc_we && sc_sel == 2'd1;
    wire sc_spr  = sc_we && sc_sel == 2'd2;

    // Every memory below has one write port: the 68000's write, or the
    // scene's in its place. Written by two statements, even with the scene's
    // held off, Quartus builds a memory from registers (137,000 of them).

    reg [7:0] v0_b0[0:4095], v0_b1[0:4095], v0_b2[0:4095], v0_b3[0:4095];
    reg [7:0] v1_b0[0:4095], v1_b1[0:4095], v1_b2[0:4095], v1_b3[0:4095];
    reg [7:0] vc_b0[0:4095], vc_b1[0:4095], vc_b2[0:4095], vc_b3[0:4095];
    wire [11:0] vwidx = cpu_addr[13:2];

    wire vw_b0 = cpu_we & cs_vram & ~cpu_addr[1] & cpu_uds;
    wire vw_b1 = cpu_we & cs_vram & ~cpu_addr[1] & cpu_lds;
    wire vw_b2 = cpu_we & cs_vram &  cpu_addr[1] & cpu_uds;
    wire vw_b3 = cpu_we & cs_vram &  cpu_addr[1] & cpu_lds;
    wire [11:0] v_wa = sc_vram ? sc_addr[12:1] : vwidx;
    wire [7:0]  v_hi = sc_vram ? sc_data[15:8] : vram_wdata[15:8];
    wire [7:0]  v_lo = sc_vram ? sc_data[7:0]  : vram_wdata[7:0];
    wire v_we0 = vw_b0 | (sc_vram & ~sc_addr[0]);
    wire v_we1 = vw_b1 | (sc_vram & ~sc_addr[0]);
    wire v_we2 = vw_b2 | (sc_vram &  sc_addr[0]);
    wire v_we3 = vw_b3 | (sc_vram &  sc_addr[0]);
    always @(posedge clk) begin
        if (v_we0) begin v0_b0[v_wa]<=v_hi; v1_b0[v_wa]<=v_hi; vc_b0[v_wa]<=v_hi; end
        if (v_we1) begin v0_b1[v_wa]<=v_lo; v1_b1[v_wa]<=v_lo; vc_b1[v_wa]<=v_lo; end
        if (v_we2) begin v0_b2[v_wa]<=v_hi; v1_b2[v_wa]<=v_hi; vc_b2[v_wa]<=v_hi; end
        if (v_we3) begin v0_b3[v_wa]<=v_lo; v1_b3[v_wa]<=v_lo; vc_b3[v_wa]<=v_lo; end
    end

    always @(posedge clk) if (ce_pix) begin
        vram_q0 <= {v0_b0[vram_a0[13:2]], v0_b1[vram_a0[13:2]], v0_b2[vram_a0[13:2]], v0_b3[vram_a0[13:2]]};
        vram_q1 <= {v1_b0[vram_a1[13:2]], v1_b1[vram_a1[13:2]], v1_b2[vram_a1[13:2]], v1_b3[vram_a1[13:2]]};
    end

    // each pair read into a register of its own, the word picked after them
    // (a pick before the register makes the read asynchronous to Quartus)
    reg [15:0] vc_q01, vc_q23;
    reg        vc_sel;
    always @(posedge clk) begin
        vc_q01 <= {vc_b0[vwidx], vc_b1[vwidx]};
        vc_q23 <= {vc_b2[vwidx], vc_b3[vwidx]};
        vc_sel <= cpu_addr[1];
    end
    assign cpu_vram_rdata = vc_sel ? vc_q23 : vc_q01;

    reg [7:0] pa_hi[0:8191], pa_lo[0:8191];
    reg [7:0] pb_hi[0:8191], pb_lo[0:8191];
    reg [7:0] pc_hi[0:8191], pc_lo[0:8191];
    wire [12:0] pwidx = cpu_addr[13:1];
    wire pw_hi = cpu_we & cs_pal & cpu_uds;
    wire pw_lo = cpu_we & cs_pal & cpu_lds;
    wire [12:0] p_wa = sc_pal ? sc_addr : pwidx;
    wire [15:0] p_wd = sc_pal ? sc_data : io_wdata;
    wire p_wehi = pw_hi | sc_pal;
    wire p_welo = pw_lo | sc_pal;
    always @(posedge clk) begin
        if (p_wehi) begin pa_hi[p_wa]<=p_wd[15:8]; pb_hi[p_wa]<=p_wd[15:8]; pc_hi[p_wa]<=p_wd[15:8]; end
        if (p_welo) begin pa_lo[p_wa]<=p_wd[7:0];  pb_lo[p_wa]<=p_wd[7:0];  pc_lo[p_wa]<=p_wd[7:0];  end
    end
    always @(posedge clk) if (ce_pix) begin
        pal_q  <= {pa_hi[{3'd0,pal_a}],  pa_lo[{3'd0,pal_a}]};
        palb_q <= {pb_hi[palb_a],        pb_lo[palb_a]};
    end
    always @(posedge clk) cpu_pal_rdata <= {pc_hi[pwidx], pc_lo[pwidx]};

    reg [7:0] sv_e[0:2047], sv_o[0:2047];
    reg [7:0] sc_e[0:2047], sc_o[0:2047];
    wire [10:0] swidx = cpu_addr[11:1];
    wire sw_e = cpu_we & cs_spr & cpu_uds;
    wire sw_o = cpu_we & cs_spr & cpu_lds;
    wire [10:0] s_wa = sc_spr ? sc_addr[10:0] : swidx;
    wire [15:0] s_wd = sc_spr ? sc_data : io_wdata;
    wire s_wee = sw_e | sc_spr;
    wire s_weo = sw_o | sc_spr;
    always @(posedge clk) begin
        if (s_wee) begin sv_e[s_wa] <= s_wd[15:8]; sc_e[s_wa] <= s_wd[15:8]; end
        if (s_weo) begin sv_o[s_wa] <= s_wd[7:0];  sc_o[s_wa] <= s_wd[7:0];  end
    end
    always @(posedge clk) spr_q         <= {sv_e[spr_a],          sv_o[spr_a]};
    always @(posedge clk) cpu_spr_rdata <= {sc_e[cpu_addr[11:1]], sc_o[cpu_addr[11:1]]};
endmodule

`default_nettype wire
