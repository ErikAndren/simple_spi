/////////////////////////////////////////////////////////////////////
////                                                             ////
////  OpenCores                    MC68HC11E based SPI interface ////
////                                                             ////
////  Author: Richard Herveille                                  ////
////          richard@asics.ws                                   ////
////          www.asics.ws                                       ////
////                                                             ////
/////////////////////////////////////////////////////////////////////
////                                                             ////
//// Copyright (C) 2002 Richard Herveille                        ////
////                    richard@asics.ws                         ////
////                                                             ////
//// This source file may be used and distributed without        ////
//// restriction provided that this copyright statement is not   ////
//// removed from the file and that any derivative work contains ////
//// the original copyright notice and the associated disclaimer.////
////                                                             ////
////     THIS SOFTWARE IS PROVIDED ``AS IS'' AND WITHOUT ANY     ////
//// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED   ////
//// TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS   ////
//// FOR A PARTICULAR PURPOSE. IN NO EVENT SHALL THE AUTHOR      ////
//// OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,         ////
//// INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES    ////
//// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE   ////
//// GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR        ////
//// BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF  ////
//// LIABILITY, WHETHER IN  CONTRACT, STRICT LIABILITY, OR TORT  ////
//// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT  ////
//// OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE         ////
//// POSSIBILITY OF SUCH DAMAGE.                                 ////
////                                                             ////
/////////////////////////////////////////////////////////////////////

//  CVS Log
//
//  $Id: simple_spi_top.v,v 1.5 2004-02-28 15:59:50 rherveille Exp $
//
//  $Date: 2004-02-28 15:59:50 $
//  $Revision: 1.5 $
//  $Author: rherveille $
//  $Locker:  $
//  $State: Exp $
//
// Change History:
//               $Log: not supported by cvs2svn $
//               Revision 1.4  2003/08/01 11:41:54  rherveille
//               Fixed some timing bugs.
//
//               Revision 1.3  2003/01/09 16:47:59  rherveille
//               Updated clkcnt size and decoding due to new SPR bit assignments.
//
//               Revision 1.2  2003/01/07 13:29:52  rherveille
//               Changed SPR bits coding.
//
//               Revision 1.1.1.1  2002/12/22 16:07:15  rherveille
//               Initial release
//
//
//
// Motorola MC68HC11E based SPI interface
//
// Currently only MASTER mode is supported
//


// synopsys translate_off
`include "timescale.v"
// synopsys translate_on

module simple_spi #(
		    parameter SS_WIDTH = 1,
		    parameter OCSPI_REG_BURST_WR = 4'h8,
		    parameter OCSPI_REG_BURST_RD = 4'h9,
		    parameter FIFO_SIZE = 4
)(
  // 8bit WISHBONE bus slave interface
  input wire 		clk_i, // clock
  input wire 		rst_i, // reset (synchronous active high)
  input wire 		cyc_i, // cycle
  input wire 		stb_i, // strobe
  input wire [3:0] 	adr_i, // address
  input wire 		we_i, // write enable
  input wire [3:0] 	sel_i, // select input
  input wire [31:0] 	dat_i, // data input
  output reg [31:0] 	dat_o, // data output
  output reg 		ack_o, // normal bus termination
  output reg 		inta_o, // interrupt output

  // SPI port
  output reg 		sck_o, // serial clock output
  output [SS_WIDTH-1:0] ss_o, // slave select (active low)
  output wire 		mosi_o, // MasterOut SlaveIN
  input wire 		miso_i         // MasterIn SlaveOut
);

   // Prefetch must handle different scenarios:
   // Prefetching of one byte:
   // Inc fill level by one
   // Place new data on proper place
   localparam PREFETCH_ONLY = 4'd1;

   // Prefetch plus ordinary read:
   // Shift rfdout 8 bits
   // Place new data on proper position as a function of current fill level
   localparam PREFETCH_AND_READ = 4'd2;

   // Prefetch plus batch read
   // Put new data on first position, set fill level to 1
   localparam PREFETCH_AND_BATCH_READ = 4'd3;

   // Ordinary read:
   // Decrement fill level, shift data 8 bits
   localparam READ_ONLY = 4'd4;

   // batch read:
   // Clear fill level
   localparam BATCH_READ_ONLY = 4'd5;

   function integer log2;
      input integer 	x;
      integer 		tmp;
      integer 		res;
      begin
	 tmp = x;
	 res = 0;
	 while (tmp > 1)
	   begin
	      res = res + 1;
	      tmp = tmp / 2;
	   end
	 log2 = res;
      end
   endfunction

   function integer bits;
      input integer x;
      begin
	 if (x > 1) begin
	    bits = log2(x-1)+1;
	 end else begin
	    bits = 1;
	 end
      end
   endfunction

  //
  // Module body
  //
  reg  [7:0]          spcr;       // Serial Peripheral Control   Register ('HC11 naming)
  wire [7:0]          spsr;       // Serial Peripheral Status    Register ('HC11 naming)
  reg  [7:0]          sper;       // Serial Peripheral Extension Register
  reg  [7:0]          treg;       // Transmit Register
  reg  [SS_WIDTH-1:0] ss_r;       // Slave Select Register

  // fifo signals
  wire [7:0] rfdout;
  reg        wfre, rfwe;
  reg 	     rfre;
  wire       rffull, rfempty;
  wire [7:0] wfdout;
  wire       wfwe, wffull, wfempty;


  localparam FIFO_SIZE_BITS = bits(FIFO_SIZE);


  reg [FIFO_SIZE_BITS:0] rfdout_pref_fill_lvl;
  reg [31:0] rfdout_pref;

  // misc signals
  wire      tirq;     // transfer interrupt (selected number of transfers done)
  wire      wfov;     // write fifo overrun (writing while fifo full)
  reg [1:0] state;    // statemachine state
  reg [2:0] bcnt;

  reg [31:0] burst_wr;
  reg [3:0] burst_wr_slices;
  wire     bur_write;

  //
  // Wishbone interface
  wire wb_acc = cyc_i & stb_i;       // WISHBONE access
  wire wb_wr  = wb_acc & we_i;       // WISHBONE write access

  // dat_i
  always @(posedge clk_i)
    if (rst_i)
      begin
          spcr <= 8'h10;  // set master bit
          sper <= 8'h00;
          ss_r <= 0;
       	  burst_wr_slices <= 0;

      end
    else if (wb_wr)
      begin
        if (adr_i[3:2] == 4'b00 && sel_i == 4'b1000)
          spcr <= dat_i[31:24] | 8'h10; // always set master bit

        if (adr_i[3:2] == 4'b00 && sel_i == 4'b0001)
          sper <= dat_i[7:0];

	 if (adr_i[3:2] == 4'b01 && sel_i == 4'b1000)
          ss_r <= dat_i[SS_WIDTH+24-1:24];

	 if (adr_i == OCSPI_REG_BURST_WR && sel_i == 4'b1111) begin
	   burst_wr        <= dat_i;
	   burst_wr_slices <= sel_i;
	 end
      end // if (wb_wr)
   else if (burst_wr_slices[3] == 1'b1)
     begin
      burst_wr_slices <= burst_wr_slices << 1;
      burst_wr <= burst_wr << 8;
     end

  // slave select (active low)
  assign ss_o = ~ss_r;

  assign bur_write = (burst_wr_slices[3] == 1'b1);

  // write fifo
  assign wfwe = (wb_acc & (adr_i[3:2] == 4'b00) & (sel_i == 4'b0010) & ack_o & we_i) || (bur_write == 1'b1 && ack_o == 1'b0);
  assign wfov = wfwe & wffull;

  // dat_o
   always @(posedge clk_i)
     if (adr_i[3:2] == 4'b00)
       begin
	  case(sel_i)
	    4'b1000: dat_o[31:24] <= spcr;
	    4'b0100: dat_o[23:16] <= spsr;
	    4'b0010: dat_o[15:8]  <= rfdout_pref[7:0];
	    4'b0001: dat_o[7:0]   <= sper;
	    default: dat_o <= 0;
	  endcase // case (sel_i)
       end
     else if ((adr_i[3:2] == 4'b01) && (sel_i == 4'b1000))
       begin
	  dat_o[31:24] <= {{ (8-SS_WIDTH){1'b0} }, ss_r};
       end
     else if ((adr_i == OCSPI_REG_BURST_RD) && (sel_i == 4'b1111))
       begin
	  dat_o <= rfdout_pref;
       end


   reg [3:0] prefetch_action;
   wire       wb_fifo_read = (wb_acc & (adr_i[3:2] == 4'b00) & (sel_i == 4'b0010) & ack_o & ~we_i);
   wire       wb_fifo_batch_read = (wb_acc & (adr_i == OCSPI_REG_BURST_RD) & (sel_i == 4'b1111) & ack_o & ~we_i);

  always @(rfempty, wb_acc, wb_fifo_read, wb_fifo_batch_read, rfdout_pref_fill_lvl)
    begin
       prefetch_action = 0;
       rfre = 1'b0;

       if ((!rfempty & wb_fifo_read) && rfdout_pref_fill_lvl > 0)
	 begin
	    prefetch_action = PREFETCH_AND_READ;
	    rfre = 1'b1;
	 end
       if ((!rfempty & wb_fifo_batch_read) && rfdout_pref_fill_lvl == 4)
	 begin
	    prefetch_action = PREFETCH_AND_BATCH_READ;
	    rfre = 1'b1;
	 end
       else if (wb_fifo_read && rfdout_pref_fill_lvl > 0)
	 prefetch_action = READ_ONLY;
       else if (wb_fifo_batch_read && rfdout_pref_fill_lvl == 4)
	 prefetch_action = BATCH_READ_ONLY;
       else if (!rfempty && rfdout_pref_fill_lvl < 4)
	 begin
	    prefetch_action = PREFETCH_ONLY;
	    rfre = 1'b1;
	 end
    end

   // rfdout_pref
   always @(posedge clk_i or posedge rst_i)
     if (rst_i)
       begin
	  rfdout_pref <= 0;
	  rfdout_pref_fill_lvl <= 0;
       end
     else
       begin
	  case (prefetch_action)
	    READ_ONLY:
	      begin
	       rfdout_pref_fill_lvl <= rfdout_pref_fill_lvl - 1;
	       rfdout_pref <= rfdout_pref >> 8;
	      end

	    PREFETCH_ONLY:
	      begin
		 case (rfdout_pref_fill_lvl)
		   0: rfdout_pref[8-1 :   0] <= rfdout;
		   1: rfdout_pref[16-1 :  8] <= rfdout;
		   2: rfdout_pref[24-1 : 16] <= rfdout;
		   3: rfdout_pref[32-1 : 24] <= rfdout;
		   default: $display("Error: Prefetching when full!");
		 endcase

		 rfdout_pref_fill_lvl <= rfdout_pref_fill_lvl + 1;
	      end

	    PREFETCH_AND_READ:
	      begin
		 rfdout_pref <= rfdout_pref >> 8;

		 case (rfdout_pref_fill_lvl)
		   0: rfdout_pref[8-1 :   0] <= rfdout;
		   1: rfdout_pref[16-1 :  8] <= rfdout;
		   2: rfdout_pref[24-1 : 16] <= rfdout;
		   3: rfdout_pref[32-1 : 24] <= rfdout;
		   default: $display("Error: Prefetching when full!");
		 endcase
	      end

	    PREFETCH_AND_BATCH_READ:
	      begin
		 rfdout_pref[8-1 : 0] <= rfdout;
		 rfdout_pref_fill_lvl <= rfdout_pref_fill_lvl - 1;
	      end

	    BATCH_READ_ONLY:
	      begin
		 rfdout_pref_fill_lvl <= 0;
	      end

	    default: $display("Illegal state");
	  endcase
       end

  // ack_o
  always @(posedge clk_i)
    if (rst_i)
      ack_o <= 1'b0;
    else
      ack_o <= wb_acc & !ack_o;

  // decode Serial Peripheral Control Register
  wire       spie = spcr[7];   // Interrupt enable bit
  wire       spe  = spcr[6];   // System Enable bit
  wire       dwom = spcr[5];   // Port D Wired-OR Mode Bit
  wire       mstr = spcr[4];   // Master Mode Select Bit
  wire       cpol = spcr[3];   // Clock Polarity Bit
  wire       cpha = spcr[2];   // Clock Phase Bit
  wire [1:0] spr  = spcr[1:0]; // Clock Rate Select Bits

  // decode Serial Peripheral Extension Register
  wire [1:0] icnt = sper[7:6]; // interrupt on transfer count
  wire [1:0] spre = sper[1:0]; // extended clock rate select

  wire [3:0] espr = {spre, spr};

  // generate status register
  wire wr_spsr = wb_wr & (adr_i[3:2] == 4'b00) & (sel_i == 4'b0100);

  reg spif;
  always @(posedge clk_i)
    if (~spe | rst_i)
      spif <= 1'b0;
    else
      spif <= (tirq | spif) & ~(wr_spsr & dat_i[23]);

  reg wcol;
  always @(posedge clk_i)
    if (~spe | rst_i)
      wcol <= 1'b0;
    else
      wcol <= (wfov | wcol) & ~(wr_spsr & dat_i[22]);

  assign spsr[7]   = spif;
  assign spsr[6]   = wcol;
  assign spsr[5:4] = 2'b00;
  assign spsr[3]   = wffull;
  assign spsr[2]   = wfempty;
  assign spsr[1]   = rffull;
  assign spsr[0]   = rfempty;

  reg [7:0] wfifo_din;

  always @(dat_i or bur_write or burst_wr[31:24])
    begin
       if (bur_write == 1'b1)
	 wfifo_din = burst_wr[31:24];
       else
	 wfifo_din = dat_i[15:8];
    end

  // generate IRQ output (inta_o)
  always @(posedge clk_i)
    inta_o <= spif & spie;

  //
  // hookup read/write buffer fifo
  fifo4 #(8)
  rfifo(
	.clk   ( clk_i   ),
	.rst   ( ~rst_i  ),
	.clr   ( ~spe    ),
	.din   ( treg    ),
	.we    ( rfwe    ),
	.dout  ( rfdout  ),
	.re    ( rfre    ),
	.full  ( rffull  ),
	.empty ( rfempty )
  ),
  wfifo(
	.clk   ( clk_i   ),
	.rst   ( ~rst_i  ),
	.clr   ( ~spe    ),
	.din   ( wfifo_din),
	.we    ( wfwe    ),
	.dout  ( wfdout  ),
	.re    ( wfre    ),
	.full  ( wffull  ),
	.empty ( wfempty )
  );

  //
  // generate clk divider
  reg [11:0] clkcnt;
  always @(posedge clk_i)
    if(spe & (|clkcnt & |state))
      clkcnt <= clkcnt - 11'h1;
    else
      case (espr) // synopsys full_case parallel_case
        4'b0000: clkcnt <= 12'h0;   // 2   -- original M68HC11 coding
        4'b0001: clkcnt <= 12'h1;   // 4   -- original M68HC11 coding
        4'b0010: clkcnt <= 12'h3;   // 16  -- original M68HC11 coding
        4'b0011: clkcnt <= 12'hf;   // 32  -- original M68HC11 coding
        4'b0100: clkcnt <= 12'h1f;  // 8
        4'b0101: clkcnt <= 12'h7;   // 64
        4'b0110: clkcnt <= 12'h3f;  // 128
        4'b0111: clkcnt <= 12'h7f;  // 256
        4'b1000: clkcnt <= 12'hff;  // 512
        4'b1001: clkcnt <= 12'h1ff; // 1024
        4'b1010: clkcnt <= 12'h3ff; // 2048
        4'b1011: clkcnt <= 12'h7ff; // 4096
      endcase

  // generate clock enable signal
  wire ena = ~|clkcnt;

  // transfer statemachine
  always @(posedge clk_i)
    if (~spe | rst_i)
      begin
          state <= 2'b00; // idle
          bcnt  <= 3'h0;
          treg  <= 8'h00;
          wfre  <= 1'b0;
          rfwe  <= 1'b0;
          sck_o <= 1'b0;
      end
    else
      begin
         wfre <= 1'b0;
         rfwe <= 1'b0;

         case (state) //synopsys full_case parallel_case
           2'b00: // idle state
              begin
                  bcnt  <= 3'h7;   // set transfer counter
                  treg  <= wfdout; // load transfer register
                  sck_o <= cpol;   // set sck

                  if (~wfempty) begin
                    wfre  <= 1'b1;
                    state <= 2'b01;
                    if (cpha) sck_o <= ~sck_o;
                  end
              end

           2'b01: // clock-phase2, next data
              if (ena) begin
                sck_o   <= ~sck_o;
                state   <= 2'b11;
              end

           2'b11: // clock phase1
              if (ena) begin
                treg <= {treg[6:0], miso_i};
                bcnt <= bcnt -3'h1;

                if (~|bcnt) begin
                  state <= 2'b00;
                  sck_o <= cpol;
                  rfwe  <= 1'b1;
                end else begin
                  state <= 2'b01;
                  sck_o <= ~sck_o;
                end
              end

           2'b10: state <= 2'b00;
         endcase
      end

  assign mosi_o = treg[7];


  // count number of transfers (for interrupt generation)
  reg [1:0] tcnt; // transfer count
  always @(posedge clk_i)
    if (~spe)
      tcnt <= icnt;
    else if (rfwe) // rfwe gets asserted when all bits have been transfered
      if (|tcnt)
        tcnt <= tcnt - 2'h1;
      else
        tcnt <= icnt;

  assign tirq = ~|tcnt & rfwe;

endmodule
