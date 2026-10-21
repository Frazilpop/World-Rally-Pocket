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
    wire wrn = ~wr_pulse;

    wire [17:0] core_addr;
    assign sample_addr = (core_addr < 18'h30000)
                         ? {2'b00, core_addr}
                         : {okibank, core_addr[15:0]};

`ifdef SIMULATION

    integer n_oki=0;
    always @(posedge clk) if (wr_pulse) begin
        if (n_oki<24) $display("OKIDBG #%0d din=%h (cmd OKI)", n_oki, din);
        n_oki <= n_oki+1;
    end
`endif

    // A stop command silences its channels at once in MAME (the status read
    // straight after shows them stopped); jt6295 stops a channel at its next
    // slot, so for a few microseconds its status still shows it playing.
    // `stopping` masks those channels until jt6295 has stopped them. A start's
    // second byte names channels too: they are not masked.
    wire [7:0] jt_dout;
    reg        cmd2 = 1'b0;
    reg  [3:0] stopping = 4'd0;
    always @(posedge clk) begin
        if (rst) begin
            cmd2 <= 1'b0; stopping <= 4'd0;
        end else if (wr_pulse) begin
            if (cmd2)        begin cmd2 <= 1'b0; stopping <= stopping & ~din[7:4]; end
            else if (din[7]) cmd2 <= 1'b1;
            else             stopping <= stopping | din[6:3];
        end else stopping <= stopping & jt_dout[3:0];
    end
    assign dout = {jt_dout[7:4], jt_dout[3:0] & ~stopping};

    jt6295 #(.INTERPOL(0), .SAMPLE(0)) u_oki (
        .rst      ( rst         ),
        .clk      ( clk         ),
        .cen      ( cen         ),
        .ss       ( 1'b1        ),
        .wrn      ( wrn         ),
        .din      ( din         ),
        .dout     ( jt_dout     ),
        .rom_addr ( core_addr   ),
        .rom_data ( sample_data ),
        .rom_ok   ( sample_ok   ),
        .sound    ( sound       ),
        .sample   ( sample_tick )
    );
endmodule

`default_nettype wire
