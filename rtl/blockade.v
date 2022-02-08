`timescale 1 ps / 1 ps

module blockade (
	input clk,
	input reset,

	output ce_pix,
	output r,
	output g,
	output b,
	output vsync,
	output hsync,
	output vblank,
	output hblank,

	output signed [15:0] audio_l,
	output signed [15:0] audio_r,

	input [7:0] in0,
	input [7:0] in1,
	input [7:0] in2,

	input [13:0] dn_addr,
	input 		 dn_wr,
	input [7:0]  dn_data
);

// Generate video and CPU enables
// - Replaces U31, U17, U8, U18 section of circuit
reg [3:0] phi_count;
reg [1:0] vid_count;
always @(posedge clk) begin
	// Phi counter is 0-9, generates PHI_1 and PHI_2 enable signals for CPU
	phi_count <= (phi_count == 4'd9) ? 4'b0 : phi_count + 1'b1;

	// Video counter is 0-3, generates ce_vid and ce_pix signals for video circuit
	vid_count <= vid_count + 2'b1;
end
wire ce_vid = (vid_count == 2'd0);
assign ce_pix = (vid_count == 2'd3);
wire PHI_1 = phi_count[3:1] == 3'b000;
wire PHI_2 = phi_count >= 4'd3 && phi_count <= 4'd8;

// U21 - Video RAM address select
wire a12_n_a15 = ADDR[15] && ~ADDR[12];

// U9 D flip-flop - Disables CPU using READY signal when attempting to write VRAM during vblank
reg u9_q;
reg PHI_2_last;
always @(posedge clk) begin
	if(reset)
	begin
	 	u9_q <= 1'b1;
	end
	else
	begin
		PHI_2_last <= PHI_2;
		if(PHI_2 && !PHI_2_last)
		begin
			if(VBLANK_N && a12_n_a15)
				u9_q <= 1'b0;
			else
				u9_q <= 1'b1;
		end
	end
end

// Address decode
wire rom_cs = (!ADDR[15] && !ADDR[11] && !ADDR[10]);

// Input data selector
wire [7:0] inp_data_out =	(ADDR[1:0] == 2'd0) ? in0 : // IN0 - Not connected in Blockade
							(ADDR[1:0] == 2'd1) ? in1 : // IN1
							(ADDR[1:0] == 2'd2) ? in2 : // IN2
							8'h00;

// CPU data selector
wire [7:0] cpu_data_in = INP ? inp_data_out :
						 rom_cs ? rom_data_out :
						 vram_cs ? vram_data_out_cpu :
						 sram_cs ? sram_data_out :
						 8'h00;

wire [15:0] ADDR;
wire [7:0] DATA;
wire DBIN;
wire WR_N;
wire SYNC /*verilator public_flat*/;
vm80a cpu
(
	.pin_clk(clk),
	.pin_f1(PHI_1),
	.pin_f2(PHI_2),
	.pin_reset(reset),
	.pin_a(ADDR),
	.pin_d(DATA),
	.pin_hold(1'b0),
	.pin_hlda(),
	.pin_ready(u9_q),
	.pin_wait(),
	.pin_int(1'b0),
	.pin_inte(),
	.pin_sync(SYNC),
	.pin_dbin(DBIN),
	.pin_wr_n(WR_N)
);
assign DATA = DBIN ? cpu_data_in: 8'hZZ;
reg [7:0] cpu_data_out;
always @(posedge clk) begin
	if(!WR_N)
	begin
		cpu_data_out <= DATA;
	end
end


// Video timing circuit

// - Constants
localparam HBLANK_START = 9'd255;
localparam HSYNC_START = 9'd272;
localparam HSYNC_END = 9'd300;
localparam HRESET_LINE = 9'd329;
localparam VSYNC_START = 9'd256;
localparam VSYNC_END = 9'd258;
localparam VBLANK_START = 9'd224;
localparam VBLANK_END = 9'd261;
localparam VRESET_LINE = 9'd261;

// Counters
reg [8:0] hcnt;
//wire s_1H = hcnt[0];
//wire s_2H = hcnt[1];
//wire s_4H = hcnt[2];
//wire s_8H = hcnt[3];
//wire s_16H = hcnt[4];
//wire s_32H = hcnt[5];
//wire s_64H = hcnt[6];
//wire s_128H = hcnt[7];
//wire s_256H = hcnt[8];
reg [8:0] vcnt;
wire s_1V = vcnt[0];
wire s_2V = vcnt[1];
wire s_4V = vcnt[2];
//wire s_8V = vcnt[3];
//wire s_16V = vcnt[4];
//wire s_32V = vcnt[5];
//wire s_64V = vcnt[6];
//wire s_128V = vcnt[7];
//wire s_256V = vcnt[8];

// Signals
reg HBLANK_N = 1'b1;
reg HSYNC_N = 1'b1;
reg HSYNC_N_last = 1'b1;
wire VBLANK_N = ~(vcnt >= VBLANK_START);
wire VSYNC_N = ~(vcnt >= VSYNC_START && vcnt <= VSYNC_END);

// Video read addresses
reg [2:0] prom_col;
wire [9:0] vram_read_addr = { vcnt[7:3], hcnt[7:3] }; // Generate VRAM read address from h/v counters { s_128V, s_64V, s_32V, s_16V, s_8V, s_128H, s_64H, s_32H, s_16H, s_8H };

always @(posedge clk)
begin
	if(ce_vid)
	begin
		HSYNC_N_last <= HSYNC_N; // Track last cycle hsync value

		if (hcnt == HRESET_LINE) // Horizontal reset point reached
		begin
			hcnt <= 9'b0000;   // Reset horizontal counter
			prom_col = 3'b111; // Set prom column to zero
			HBLANK_N <= 1'b1;  // Leave hblank
		end
		else
		begin
			hcnt <= hcnt + 9'b1;                       // Increment horizontal counter
			if(hcnt == HBLANK_START) HBLANK_N <= 1'b0; // Enter hblank when HBLANK_START reached
			if(hcnt == HSYNC_START) HSYNC_N <= 1'b0;   // Enter hsync when HSYNC_START reached
			if(hcnt == HSYNC_END) HSYNC_N <= 1'b1;     // Leave hsync when HSYNC_END reached
			prom_col = 3'b111 - { hcnt[2:0] + 3'b1};   // Set prom column to reverse of {H1,H2,H4} + 1
		end

		if(HSYNC_N && !HSYNC_N_last) // Leaving hysnc
		begin
			if (vcnt == VRESET_LINE) // Vertical reset point reached
			begin
				vcnt <= 9'b0;        // Reset vertical counter
			end
			else
			begin
				vcnt <= vcnt + 9'b1; // Increment vertical counter
			end
		end
	end
end

// Set video output signals
assign r = 1'b0;
assign g = prom_data_out[prom_col];
assign b = 1'b0;
assign hsync = ~HSYNC_N;
assign hblank = ~HBLANK_N;
assign vblank = ~VBLANK_N;
assign vsync = ~VSYNC_N;

// U45 AND - Enable for U51 latch
wire u45 = PHI_1 && SYNC;

reg [31:0] timer;

// U51 latch
reg l_D7;
reg l_D6;
reg l_D4;
reg l_D3;
always @(posedge clk) begin
	timer <= timer + 32'b1;
	if(u45)
	begin
		l_D7 <= DATA[7];
		l_D6 <= DATA[6];
		l_D4 <= DATA[4];
		l_D3 <= DATA[3];
	end
end

// U45_1
wire OUTP = l_D4 && ~WR_N;
// U44_1
wire MEMW = (l_D3 && ~WR_N);
// U45_2
wire INP = (l_D6 && DBIN);
// U44_2
wire MEMR = (l_D7 && DBIN);

// U1 - 7442 BCD to decimal decoder
// wire [9:0] u1_q;
// ttl_7442 u1
// (
// 	.a(ADDR[10]),
// 	.b(ADDR[11]),
// 	.c(ADDR[15]),
// 	.d(~MEMR),
// 	.o(u1_q)
// );


// AUDIO
wire u68_out;
reg u68_out_last;
ttl_555 #(
	.HIGH_COUNTS(140),
	.LOW_COUNTS(51)
) u68 (
	.clk(clk),
	.reset(reset),
	.out(u68_out)
);

reg [7:0] u6766_count;
reg u6766_out;
reg u6766_out_last;

always @(posedge clk)
begin
	u68_out_last <= u68_out;
	if(reset)
	begin
		u6766_count <= 8'b0;
		u6766_out <= 1'b0;
		u6766_out_last <= 1'b0;
	end
	else
	begin
		u6766_out_last <= u6766_out;
		if(u68_out && !u68_out_last)
		begin
			if(u6766_out) // Load new inputs when counter overflows
			begin
				 // load parallel inputs
				//$display("Loading u6766: %b", { u66_p, u67_p });
				u6766_count <= u6766_p;
				u6766_out <= 1'b0;
			end
			else
			begin
				// count up
				u6766_count <= u6766_count + 8'b1;
				u6766_out <= (u6766_count == 8'd255);
			end
		end
	end
end

reg [7:0] u6766_p;
wire u60_1_ce = ~u6766_out;
reg u60_1_q;

// U60_1 flip flop
always @(posedge clk)
begin
	if(reset)
		u60_1_q <= 1'b0;
	else
		if(u60_1_ce) u60_1_q <= 1'b1;
end

// U60_2 flip flop
reg u60_2_q;
always @(posedge clk)
begin
	if(~u60_1_q)
	begin
		u60_2_q <= 1'b0;
	end
	else
	begin
		if(u6766_out && !u6766_out_last)
		begin
			u60_2_q <= ~u60_2_q;
		end
	end
end

reg [31:0] timer_last_outp2;
reg OUTP_last;

wire u50_1 = ~(OUTP && ADDR[3]);
wire u50_2 = ~(OUTP && ADDR[2]);
/* verilator lint_off UNOPTFLAT */
wire u50_3 = ~(u50_1 && u50_4);
wire u50_4 = ~(u50_2 && u50_3);
/* verilator lint_on UNOPTFLAT */

always @(posedge clk) begin
//	OUTP_last <= OUTP;
//	if(OUTP && !OUTP_last)
	if(OUTP)
	begin
		if(ADDR[1])
		begin
			// OUTP2 - Movement sound latch
			//$display("(%d) Latching OUTP 2 %b %b >> %b %b  (%d)", timer, u66_p, u67_p, cpu_data_out[7:4], cpu_data_out[3:0], timer - timer_last_outp2);
			u6766_p <= DATA;
			timer_last_outp2 <= timer;
		end
		// else if(ADDR[3])
		// begin
		// 	// OUTP8 - ?
		// 	//$display("OUTP 8: %b", cpu_data_out);
		// end
		else
		begin
			//$display("OUTP: %b %b", ADDR[3:0], cpu_data_out);
		end
	end

	if(u50_4)
	begin
		$display("ENV");
	end
end

// SOUND SAMPLE

//assign audio_l = { 2'b0, u66_q, 10'b0 };
// assign audio_r = { 2'b0, u66_q, 10'b0 };
//wire signed [15:0] sound_out = (u6766_p == 8'hFF) ? 0 : (!u60_2_q ? -30000 : 30000);
wire signed [15:0] sound_out = (!u60_2_q ? -30000 : 30000);

// Low-pass filter the audio output
wire signed [15:0] sound_filtered;
blockade_lpf lpf
(
	.clk(clk),
	.reset(reset),
	.in(sound_out),
	.out(sound_filtered)
);
// Invert the 
assign audio_l = 16'hFFFF - sound_filtered;
assign audio_r = sound_out;


// U2, U3 - Program ROM
// --------------------
// Each ROM is 1024 x 4 bytes.  Combined to 8 bytes with U2 as most significant bits, U3 as least significant bits

// Program ROM data outs
wire [3:0] rom_data_out_lsb;
wire [3:0] rom_data_out_msb;
wire [7:0] rom_data_out = { rom_data_out_msb, rom_data_out_lsb };

// Program ROM download write enables
wire rom_lsb_wr = dn_addr[12:10] == 3'b000 && dn_wr;
wire rom_msb_wr = dn_addr[12:10] == 3'b001 && dn_wr;

// Program ROM - U3 - Least-significant bits
dpram #(10,4) rom_lsb
(
	.clock_a(clk),
	.address_a(ADDR[9:0]),
	.wren_a(1'b0),
	.data_a(),
	.q_a(rom_data_out_lsb),

	.clock_b(clk),
	.address_b(dn_addr[9:0]),
	.wren_b(rom_lsb_wr),
	.data_b(dn_data[3:0]),
	.q_b()
);
// Program ROM - U2 - Most-significant bits
dpram #(10,4) rom_msb
(
	.clock_a(clk),
	.address_a(ADDR[9:0]),
	.wren_a(1'b0),
	.data_a(),
	.q_a(rom_data_out_msb),

	.clock_b(clk),
	.address_b(dn_addr[9:0]),
	.wren_b(rom_msb_wr),
	.data_b(dn_data[3:0]),
	.q_b()
);

// U38, U39, U40, U41, U42 - 2102 - Video RAM
// ------------------------------------------
// The original board used logic to allow CPU to write during VBLANK and the video system to read otherwise - I have used dual port RAM for simplicity
// In Blockade only 5-bits per address is used, but Comotion and others use 8-bits

// Data outs
wire [7:0] vram_data_out_cpu;	// Data read by CPU
wire [7:0] vram_data_out;		// Data read by video system

// Video RAM address select and write enable
wire vram_cs = ADDR[15] && !ADDR[12];
wire vram_we = vram_cs && !WR_N;

// U38, U39, U40, U41, U42 combined
dpram #(10,8) ram
(
	.clock_a(clk),
	.address_a(vram_read_addr),
	.wren_a(),
	.data_a(),
	.q_a(vram_data_out),

	.clock_b(clk),
	.address_b(ADDR[9:0]),
	.wren_b(vram_we),
	.data_b(cpu_data_out),
	.q_b(vram_data_out_cpu)
);


// U6, U7 - 2111 - Static RAM
// --------------------------

// Static RAM Data out
wire [7:0]	sram_data_out;

// Static RAM address select and write enable
wire sram_cs = ADDR[15] && ADDR[12];
wire sram_we = sram_cs && !WR_N;

// U6, U7 combined
spram #(8,8) sram
(
	.clk(clk),
	.address(ADDR[7:0]),
	.wren(sram_we),
	.data(cpu_data_out),
	.q(sram_data_out)
);

// U29, U43 - Graphics PROMs
// --------------------
// Each ROM is 256 x 4 bytes.  Combined to 8 bytes with U29 as most significant bits, U43 as least significant bits

// Graphics PROM data outs
wire [3:0] prom_data_out_lsb;
wire [3:0] prom_data_out_msb;
wire [7:0] prom_data_out = { prom_data_out_msb, prom_data_out_lsb } ;

// Graphics PROM read adress
wire [7:0] prom_addr = { vram_data_out[4:0], s_4V, s_2V, s_1V };

// Graphics ROM download write enables
wire prom_lsb_wr = dn_addr[12:8] == 5'b10000 && dn_wr;
wire prom_msb_wr = dn_addr[12:8] == 5'b10001 && dn_wr;

// Graphics ROM - U43 - Least-significant bits
dpram #(8,4) prom_lsb
(
	.clock_a(clk),
	.address_a(prom_addr),
	.wren_a(1'b0),
	.data_a(),
	.q_a(prom_data_out_lsb),

	.clock_b(clk),
	.address_b(dn_addr[7:0]),
	.wren_b(prom_lsb_wr),
	.data_b(dn_data[3:0]),
	.q_b()
);
// Graphics PROM - U29 - Most-significant bits
dpram #(8,4) prom_msb
(
	.clock_a(clk),
	.address_a(prom_addr),
	.wren_a(1'b0),
	.data_a(),
	.q_a(prom_data_out_msb),

	.clock_b(clk),
	.address_b(dn_addr[7:0]),
	.wren_b(prom_msb_wr),
	.data_b(dn_data[3:0]),
	.q_b()
);



reg [15:0] sound_rom_addr;
wire [7:0] sound_rom_data_out;
// Sound samples
spram #(16,8, "sound.hex") sound_rom
(
	.clk(clk),
	.address(sound_rom_addr),
	.wren(1'b0),
	.data(),
	.q(sound_rom_data_out)
);

endmodule
