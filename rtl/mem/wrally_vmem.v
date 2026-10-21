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
    output reg  [15:0] cpu_vram_rdata,
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

    reg [7:0] v0_b0[0:4095], v0_b1[0:4095], v0_b2[0:4095], v0_b3[0:4095];
    reg [7:0] v1_b0[0:4095], v1_b1[0:4095], v1_b2[0:4095], v1_b3[0:4095];
    reg [7:0] vc_b0[0:4095], vc_b1[0:4095], vc_b2[0:4095], vc_b3[0:4095];
    wire [11:0] vwidx = cpu_addr[13:2];

    wire vw_b0 = cpu_we & cs_vram & ~cpu_addr[1] & cpu_uds;
    wire vw_b1 = cpu_we & cs_vram & ~cpu_addr[1] & cpu_lds;
    wire vw_b2 = cpu_we & cs_vram &  cpu_addr[1] & cpu_uds;
    wire vw_b3 = cpu_we & cs_vram &  cpu_addr[1] & cpu_lds;
    always @(posedge clk) begin
        if (vw_b0) begin v0_b0[vwidx]<=vram_wdata[15:8]; v1_b0[vwidx]<=vram_wdata[15:8]; vc_b0[vwidx]<=vram_wdata[15:8]; end
        if (vw_b1) begin v0_b1[vwidx]<=vram_wdata[7:0];  v1_b1[vwidx]<=vram_wdata[7:0];  vc_b1[vwidx]<=vram_wdata[7:0];  end
        if (vw_b2) begin v0_b2[vwidx]<=vram_wdata[15:8]; v1_b2[vwidx]<=vram_wdata[15:8]; vc_b2[vwidx]<=vram_wdata[15:8]; end
        if (vw_b3) begin v0_b3[vwidx]<=vram_wdata[7:0];  v1_b3[vwidx]<=vram_wdata[7:0];  vc_b3[vwidx]<=vram_wdata[7:0];  end
        if (sc_vram && !sc_addr[0]) begin
            v0_b0[sc_addr[12:1]]<=sc_data[15:8]; v1_b0[sc_addr[12:1]]<=sc_data[15:8]; vc_b0[sc_addr[12:1]]<=sc_data[15:8];
            v0_b1[sc_addr[12:1]]<=sc_data[7:0];  v1_b1[sc_addr[12:1]]<=sc_data[7:0];  vc_b1[sc_addr[12:1]]<=sc_data[7:0];
        end
        if (sc_vram && sc_addr[0]) begin
            v0_b2[sc_addr[12:1]]<=sc_data[15:8]; v1_b2[sc_addr[12:1]]<=sc_data[15:8]; vc_b2[sc_addr[12:1]]<=sc_data[15:8];
            v0_b3[sc_addr[12:1]]<=sc_data[7:0];  v1_b3[sc_addr[12:1]]<=sc_data[7:0];  vc_b3[sc_addr[12:1]]<=sc_data[7:0];
        end
    end

    always @(posedge clk) if (ce_pix) begin
        vram_q0 <= {v0_b0[vram_a0[13:2]], v0_b1[vram_a0[13:2]], v0_b2[vram_a0[13:2]], v0_b3[vram_a0[13:2]]};
        vram_q1 <= {v1_b0[vram_a1[13:2]], v1_b1[vram_a1[13:2]], v1_b2[vram_a1[13:2]], v1_b3[vram_a1[13:2]]};
    end

    always @(posedge clk)
        cpu_vram_rdata <= cpu_addr[1] ? {vc_b2[vwidx], vc_b3[vwidx]} : {vc_b0[vwidx], vc_b1[vwidx]};

    reg [7:0] pa_hi[0:8191], pa_lo[0:8191];
    reg [7:0] pb_hi[0:8191], pb_lo[0:8191];
    reg [7:0] pc_hi[0:8191], pc_lo[0:8191];
    wire [12:0] pwidx = cpu_addr[13:1];
    wire pw_hi = cpu_we & cs_pal & cpu_uds;
    wire pw_lo = cpu_we & cs_pal & cpu_lds;
    always @(posedge clk) begin
        if (pw_hi) begin pa_hi[pwidx]<=io_wdata[15:8]; pb_hi[pwidx]<=io_wdata[15:8]; pc_hi[pwidx]<=io_wdata[15:8]; end
        if (pw_lo) begin pa_lo[pwidx]<=io_wdata[7:0];  pb_lo[pwidx]<=io_wdata[7:0];  pc_lo[pwidx]<=io_wdata[7:0];  end
        if (sc_pal) begin
            pa_hi[sc_addr]<=sc_data[15:8]; pb_hi[sc_addr]<=sc_data[15:8]; pc_hi[sc_addr]<=sc_data[15:8];
            pa_lo[sc_addr]<=sc_data[7:0];  pb_lo[sc_addr]<=sc_data[7:0];  pc_lo[sc_addr]<=sc_data[7:0];
        end
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
    always @(posedge clk) begin
        if (sw_e) begin sv_e[swidx] <= io_wdata[15:8]; sc_e[swidx] <= io_wdata[15:8]; end
        if (sw_o) begin sv_o[swidx] <= io_wdata[7:0];  sc_o[swidx] <= io_wdata[7:0];  end
        if (sc_spr) begin
            sv_e[sc_addr[10:0]] <= sc_data[15:8]; sc_e[sc_addr[10:0]] <= sc_data[15:8];
            sv_o[sc_addr[10:0]] <= sc_data[7:0];  sc_o[sc_addr[10:0]] <= sc_data[7:0];
        end
    end
    always @(posedge clk) spr_q         <= {sv_e[spr_a],          sv_o[spr_a]};
    always @(posedge clk) cpu_spr_rdata <= {sc_e[cpu_addr[11:1]], sc_o[cpu_addr[11:1]]};
endmodule

`default_nettype wire
