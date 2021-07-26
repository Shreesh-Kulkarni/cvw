///////////////////////////////////////////
// dcache (data cache)
//
// Written: ross1728@gmail.com July 07, 2021
//          Implements the L1 data cache
//
// Purpose: Storage for data and meta data.
//
// A component of the Wally configurable RISC-V project.
//
// Copyright (C) 2021 Harvey Mudd College & Oklahoma State University
//
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy,
// modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software
// is furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
// OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
// BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT
// OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
///////////////////////////////////////////

`include "wally-config.vh"

module dcache
  (input logic clk,
   input logic 		       reset,
   input logic 		       StallM,
   input logic 		       StallWtoDCache,
   input logic 		       FlushM,
   input logic 		       FlushW,

   // cpu side
   input logic [1:0] 	       MemRWM,
   input logic [2:0] 	       Funct3M,
   input logic [6:0] 	       Funct7M,
   input logic [1:0] 	       AtomicM,
   input logic [11:0] 	       MemAdrE, // virtual address, but we only use the lower 12 bits.
   input logic [`PA_BITS-1:0]  MemPAdrM, // physical address
   input logic [11:0] 	       VAdr, // when hptw writes dtlb we use this address to index SRAM.

   input logic [`XLEN-1:0]     WriteDataM,
   output logic [`XLEN-1:0]    ReadDataM,
   output logic 	       DCacheStall,
   output logic 	       CommittedM,
   output logic 	       DCacheMiss,
   output logic 	       DCacheAccess,

   // inputs from TLB and PMA/P
   input logic 		       ExceptionM,
   input logic 		       PendingInterruptM, 
   input logic 		       DTLBMissM,
   input logic 		       ITLBMissF,
   input logic 		       CacheableM,
   input logic 		       DTLBWriteM,
   input logic 		       ITLBWriteF,
   input logic 		       WalkerInstrPageFaultF,
   // from ptw
   input logic 		       SelPTW,
   input logic 		       WalkerPageFaultM, 
   output logic [`XLEN-1:0]    LSUData,
   output logic 	       MemAfterIWalkDone,
   // ahb side
   output logic [`PA_BITS-1:0] AHBPAdr, // to ahb
   output logic 	       AHBRead,
   output logic 	       AHBWrite,
   input logic 		       AHBAck, // from ahb
   input logic [`XLEN-1:0]     HRDATA, // from ahb
   output logic [`XLEN-1:0]    HWDATA // to ahb
   );

/*  localparam integer	       BLOCKLEN = 256;
  localparam integer	       NUMLINES = 64;
  localparam integer	       NUMWAYS = 4;
  localparam integer	       NUMREPL_BITS = 3;*/
  localparam integer	       BLOCKLEN = `DCACHE_BLOCKLENINBITS;
  localparam integer	       NUMLINES = `DCACHE_WAYSIZEINBYTES*8/BLOCKLEN;
  localparam integer	       NUMWAYS = `DCACHE_NUMWAYS;
  localparam integer	       NUMREPL_BITS = `DCACHE_REPLBITS;

  localparam integer	       BLOCKBYTELEN = BLOCKLEN/8;
  localparam integer	       OFFSETLEN = $clog2(BLOCKBYTELEN);
  localparam integer	       INDEXLEN = $clog2(NUMLINES);
  localparam integer	       TAGLEN = `PA_BITS - OFFSETLEN - INDEXLEN;
  localparam integer	       WORDSPERLINE = BLOCKLEN/`XLEN;
  localparam integer	       LOGWPL = $clog2(WORDSPERLINE);
  localparam integer 	       LOGXLENBYTES = $clog2(`XLEN/8);


  logic [1:0] 		       SelAdrM;
  logic [INDEXLEN-1:0]	       SRAMAdr;
  logic [BLOCKLEN-1:0]	       SRAMWriteData;
  logic [BLOCKLEN-1:0] 	       DCacheMemWriteData;
  logic			       SetValidM, ClearValidM;
  logic			       SetDirtyM, ClearDirtyM;
  logic [BLOCKLEN-1:0] 	       ReadDataBlockWayM [NUMWAYS-1:0];
  logic [BLOCKLEN-1:0] 	       ReadDataBlockWayMaskedM [NUMWAYS-1:0];
  logic [BLOCKLEN-1:0] 	       VictimReadDataBLockWayMaskedM [NUMWAYS-1:0];
  logic [TAGLEN-1:0]	       ReadTag [NUMWAYS-1:0];
  logic [NUMWAYS-1:0]	       Valid, Dirty, WayHit;
  logic			       CacheHit;
  logic [NUMWAYS-2:0] 	       ReplacementBits [NUMLINES-1:0];
  logic [NUMWAYS-2:0] 	       BlockReplacementBits;
  logic [NUMWAYS-2:0] 	       NewReplacement;
  logic [BLOCKLEN-1:0]	       ReadDataBlockM;
  logic [`XLEN-1:0]	       ReadDataBlockSetsM [(WORDSPERLINE)-1:0];
  logic [`XLEN-1:0]	       VictimReadDataBlockSetsM [(WORDSPERLINE)-1:0];  
  logic [`XLEN-1:0]	       ReadDataWordM, ReadDataWordMuxM;
  logic [`XLEN-1:0]	       FinalWriteDataM, FinalAMOWriteDataM;
  logic [BLOCKLEN-1:0]	       FinalWriteDataWordsM;
  logic [LOGWPL-1:0] 	       FetchCount, NextFetchCount;
  logic [WORDSPERLINE-1:0]     SRAMWordEnable;
  logic 		       SelMemWriteDataM;
  logic [2:0] 		       Funct3W;

  logic 		       SRAMWordWriteEnableM, SRAMWordWriteEnableW;
  logic 		       SRAMBlockWriteEnableM;
  logic [NUMWAYS-1:0] 	       SRAMBlockWayWriteEnableM;
  logic 		       SRAMWriteEnable;
  logic [NUMWAYS-1:0] 	       SRAMWayWriteEnable;
  

  logic 		       SaveSRAMRead;
  logic [1:0] 		       AtomicW;
  logic [NUMWAYS-1:0] 	       VictimWay;
  logic [NUMWAYS-1:0] 	       VictimDirtyWay;
  logic [BLOCKLEN-1:0] 	       VictimReadDataBlockM;
  logic 		       VictimDirty;
  logic 		       SelAMOWrite;
  logic 		       SelUncached;
  logic [6:0] 		       Funct7W;
  logic [2**LOGWPL-1:0]	       MemPAdrDecodedW;

  logic [`PA_BITS-1:0] 	       BasePAdrM;
  logic [OFFSETLEN-1:0]        BasePAdrOffsetM;
  logic [`PA_BITS-1:0] 	       BasePAdrMaskedM;  
  logic [TAGLEN-1:0] 	       VictimTagWay [NUMWAYS-1:0];
  logic [TAGLEN-1:0] 	       VictimTag;

  
  logic AnyCPUReqM;
  logic FetchCountFlag;
  logic PreCntEn;
  logic CntEn;
  logic CntReset;
  logic CPUBusy, PreviousCPUBusy;
  logic SelEvict;

  logic LRUWriteEn;

  logic CaptureDataM;
  logic [`XLEN-1:0] SavedReadDataM;

  
  typedef enum {STATE_READY,

		STATE_MISS_FETCH_WDV,
		STATE_MISS_FETCH_DONE,
		STATE_MISS_EVICT_DIRTY,
		STATE_MISS_WRITE_BACK_EVICTED_BLOCK,
		STATE_MISS_WRITE_CACHE_BLOCK,
		STATE_MISS_READ_WORD,
		STATE_MISS_READ_WORD_DELAY,
		STATE_MISS_WRITE_WORD,
		STATE_MISS_WRITE_WORD_DELAY,		

		STATE_AMO_MISS_FETCH_WDV,
		STATE_AMO_MISS_FETCH_DONE,
		STATE_AMO_MISS_CHECK_EVICTED_DIRTY,
		STATE_AMO_MISS_WRITE_BACK_EVICTED_BLOCK,
		STATE_AMO_MISS_WRITE_CACHE_BLOCK,
		STATE_AMO_MISS_READ_WORD,
		STATE_AMO_MISS_UPDATE_WORD,
		STATE_AMO_MISS_WRITE_WORD,
		STATE_AMO_UPDATE,
		STATE_AMO_WRITE,

		STATE_PTW_READY,
		STATE_PTW_READ_MISS_FETCH_WDV,
		STATE_PTW_READ_MISS_FETCH_DONE,
		STATE_PTW_READ_MISS_WRITE_CACHE_BLOCK,
		STATE_PTW_READ_MISS_EVICT_DIRTY,		
		STATE_PTW_READ_MISS_READ_WORD,
		STATE_PTW_READ_MISS_READ_WORD_DELAY,
		STATE_PTW_ACCESS_AFTER_WALK,		
		STATE_PTW_UPDATE_TLB,

		STATE_UNCACHED_WRITE,
		STATE_UNCACHED_WRITE_DONE,
		STATE_UNCACHED_READ,
		STATE_UNCACHED_READ_DONE,

		STATE_PTW_FAULT_READY,
		STATE_PTW_FAULT_CPU_BUSY,
		STATE_PTW_FAULT_MISS_FETCH_WDV,
		STATE_PTW_FAULT_MISS_FETCH_DONE,
		STATE_PTW_FAULT_MISS_WRITE_CACHE_BLOCK,
		STATE_PTW_FAULT_MISS_READ_WORD,
		STATE_PTW_FAULT_MISS_READ_WORD_DELAY,
		STATE_PTW_FAULT_MISS_WRITE_WORD,
		STATE_PTW_FAULT_MISS_WRITE_WORD_DELAY,
		STATE_PTW_FAULT_MISS_EVICT_DIRTY,

		STATE_PTW_FAULT_UNCACHED_WRITE,
		STATE_PTW_FAULT_UNCACHED_WRITE_DONE,
		STATE_PTW_FAULT_UNCACHED_READ,
		STATE_PTW_FAULT_UNCACHED_READ_DONE,

		STATE_CPU_BUSY} statetype;

  statetype CurrState, NextState;
    

  flopenr #(7) Funct7WReg(.clk(clk),
			  .reset(reset),
			  .en(~StallWtoDCache),
			  .d(Funct7M),
			  .q(Funct7W));
  
  

  // data path

  mux3 #(INDEXLEN)
  AdrSelMux(.d0(MemAdrE[INDEXLEN+OFFSETLEN-1:OFFSETLEN]),
	    .d1(MemPAdrM[INDEXLEN+OFFSETLEN-1:OFFSETLEN]),
	    .d2(VAdr[INDEXLEN+OFFSETLEN-1:OFFSETLEN]),
	    .s(SelAdrM),
	    .y(SRAMAdr));


  oneHotDecoder #(LOGWPL)
  oneHotDecoder(.bin(MemPAdrM[LOGWPL+LOGXLENBYTES-1:LOGXLENBYTES]),
		.decoded(MemPAdrDecodedW));
  

  assign SRAMWordEnable = SRAMBlockWriteEnableM ? '1 : MemPAdrDecodedW;
  

  genvar		       way;
  generate
    for(way = 0; way < NUMWAYS; way = way + 1) begin :CacheWays
      DCacheMem #(.NUMLINES(NUMLINES), .BLOCKLEN(BLOCKLEN), .TAGLEN(TAGLEN))
      MemWay(.clk(clk),
	     .reset(reset),
	     .Adr(SRAMAdr),
	     .WAdr(MemPAdrM[INDEXLEN+OFFSETLEN-1:OFFSETLEN]),
	     .WriteEnable(SRAMWayWriteEnable[way]),
	     .WriteWordEnable(SRAMWordEnable),
	     .TagWriteEnable(SRAMBlockWayWriteEnableM[way]), 
	     .WriteData(SRAMWriteData),
	     .WriteTag(MemPAdrM[`PA_BITS-1:OFFSETLEN+INDEXLEN]),
	     .SetValid(SetValidM),
	     .ClearValid(ClearValidM),
	     .SetDirty(SetDirtyM),
	     .ClearDirty(ClearDirtyM),
	     .ReadData(ReadDataBlockWayM[way]),
	     .ReadTag(ReadTag[way]),
	     .Valid(Valid[way]),
	     .Dirty(Dirty[way]));
      assign WayHit[way] = Valid[way] & (ReadTag[way] == MemPAdrM[`PA_BITS-1:OFFSETLEN+INDEXLEN]);
      assign ReadDataBlockWayMaskedM[way] = WayHit[way] ? ReadDataBlockWayM[way] : '0;  // first part of AO mux.

      // the cache block candiate for eviction
      // *** this should be sharable with the read data muxing, but for now i'm doing the simple
      // thing and making them separate.
      assign VictimReadDataBLockWayMaskedM[way] = VictimWay[way] ? ReadDataBlockWayM[way] : '0;
      assign VictimDirtyWay[way] = VictimWay[way] & Dirty[way] & Valid[way];
      assign VictimTagWay[way] = VictimWay[way] ? ReadTag[way] : '0;
    end
  endgenerate

  always_ff @(posedge clk, posedge reset) begin
    if (reset) begin
      for(int index = 0; index < NUMLINES; index++)
	ReplacementBits[index] <= '0;
    end else begin
      BlockReplacementBits <= ReplacementBits[SRAMAdr];
      if (LRUWriteEn) begin
	ReplacementBits[MemPAdrM[INDEXLEN+OFFSETLEN-1:OFFSETLEN]] <= NewReplacement;
      end
    end
  end

  // *** TODO only supports 1, 2, 4, and 8 way
  generate
    if(NUMWAYS > 1) begin
      cacheLRU #(NUMWAYS)
      cacheLRU(.LRUIn(BlockReplacementBits),
	       .WayIn(WayHit),
	       .LRUOut(NewReplacement),
	       .VictimWay(VictimWay));
    end else begin
      assign NewReplacement = '0;
      assign VictimWay = 1'b1;
    end
  endgenerate

  assign SRAMBlockWayWriteEnableM = SRAMBlockWriteEnableM ? VictimWay : '0;
  
  mux2 #(NUMWAYS) WriteEnableMux(.d0(SRAMWordWriteEnableM ? WayHit : '0),
				 .d1(SRAMBlockWayWriteEnableM),
				 .s(SRAMBlockWriteEnableM),
				 .y(SRAMWayWriteEnable));

  
  
  

  assign CacheHit = |WayHit;
  // ReadDataBlockWayMaskedM is a 2d array of cache block len by number of ways.
  // Need to OR together each way in a bitwise manner.
  // Final part of the AO Mux.
  genvar index;
  always_comb begin
    ReadDataBlockM = '0;
    VictimReadDataBlockM = '0;
    VictimTag = '0;
    for(int index = 0; index < NUMWAYS; index++) begin
      ReadDataBlockM = ReadDataBlockM | ReadDataBlockWayMaskedM[index];
      VictimReadDataBlockM = VictimReadDataBlockM | VictimReadDataBLockWayMaskedM[index];
      VictimTag = VictimTag | VictimTagWay[index];      
    end
  end
  assign VictimDirty = | VictimDirtyWay;


  // Convert the Read data bus ReadDataSelectWay into sets of XLEN so we can
  // easily build a variable input mux.
  // *** consider using a limited range shift to do this final muxing.
  generate
    for (index = 0; index < WORDSPERLINE; index++) begin
      assign ReadDataBlockSetsM[index] = ReadDataBlockM[((index+1)*`XLEN)-1: (index*`XLEN)];
      assign VictimReadDataBlockSetsM[index] = VictimReadDataBlockM[((index+1)*`XLEN)-1: (index*`XLEN)];      
    end
  endgenerate

  // variable input mux
  assign ReadDataWordM = ReadDataBlockSetsM[MemPAdrM[$clog2(WORDSPERLINE+`XLEN/8) : $clog2(`XLEN/8)]];


  assign HWDATA = CacheableM ? VictimReadDataBlockSetsM[FetchCount] : WriteDataM;

  mux2 #(`XLEN) UnCachedDataMux(.d0(ReadDataWordM),
				.d1(DCacheMemWriteData[`XLEN-1:0]),
				.s(SelUncached),
				.y(ReadDataWordMuxM));
  
  // finally swr
  // *** BUG fix HSIZED? why was it this way?
  subwordread subwordread(.HRDATA(ReadDataWordMuxM),
			  .HADDRD(MemPAdrM[2:0]),
			  .HSIZED({Funct3M[2], 1'b0, Funct3M[1:0]}),
			  .HRDATAMasked(LSUData));

  assign CaptureDataM = ~SelPTW & MemRWM[1];
  
  flopen #(`XLEN) 
  SavedReadDataReg(.clk,
		   .en(CaptureDataM),
		   .d(LSUData),
		   .q(SavedReadDataM));

// *** BUG remove mux
  mux2 #(`XLEN)
  ReadDataMMux(.d0(LSUData),
	       .d1(SavedReadDataM),
	       .s(1'b0),
	       .y(ReadDataM));
		   
  

  // This is a confusing point.
  // The final read data should be updated only if the CPU's StallWtoDCache is low
  // which means the CPU is ready to take data.  Or if the CPU just became
  // busy.  Then when we exit CPU_BUSY we want to ensure the data is not
  // updated, this is ~PreviousCPUBusy.
  // also must update if cpu stalled and processing a read miss
  // which occurs if in state miss read word delay.
  assign CPUBusy = CurrState == STATE_CPU_BUSY;
  flop #(1) CPUBusyReg(.clk, .d(CPUBusy), .q(PreviousCPUBusy));
  



  // write path
  subwordwrite subwordwrite(.HRDATA(ReadDataWordM),
			    .HADDRD(MemPAdrM[2:0]),
			    .HSIZED({Funct3M[2], 1'b0, Funct3M[1:0]}),
			    .HWDATAIN(WriteDataM),
			    .HWDATA(FinalWriteDataM));

  generate
    if (`A_SUPPORTED) begin
      logic [`XLEN-1:0] AMOResult;
      amoalu amoalu(.srca(ReadDataM), .srcb(WriteDataM), .funct(Funct7M), .width(Funct3M[1:0]), 
                    .result(AMOResult));
      mux2 #(`XLEN) wdmux(FinalWriteDataM, AMOResult, SelAMOWrite & AtomicM[1], FinalAMOWriteDataM);
    end else
      assign FinalAMOWriteDataM = FinalWriteDataM;
  endgenerate
  

  // register the fetch data from the next level of memory.
  generate
    for (index = 0; index < WORDSPERLINE; index++) begin:fetchbuffer
      flopen #(`XLEN) fb(.clk(clk),
			 .en(AHBAck & AHBRead & (index == FetchCount)),
			 .d(HRDATA),
			 .q(DCacheMemWriteData[(index+1)*`XLEN-1:index*`XLEN]));
    end
  endgenerate

  mux2 #(`PA_BITS) BaseAdrMux(.d0(MemPAdrM),
			      .d1({VictimTag, MemPAdrM[INDEXLEN+OFFSETLEN-1:OFFSETLEN], {{OFFSETLEN}{1'b0}}}),
			      .s(SelEvict),
			      .y(BasePAdrM));

  // if not cacheable the offset bits needs to be sent to the EBU.
  // if cacheable the offset bits are discarded.  $ FSM will fetch the whole block.
  assign BasePAdrOffsetM = CacheableM ? {{OFFSETLEN}{1'b0}} : BasePAdrM[OFFSETLEN-1:0];
  assign BasePAdrMaskedM = {BasePAdrM[`PA_BITS-1:OFFSETLEN], BasePAdrOffsetM};
  
  assign AHBPAdr = ({{`PA_BITS-LOGWPL{1'b0}}, FetchCount} << $clog2(`XLEN/8)) + BasePAdrMaskedM;
  
    
  
  // mux between the CPU's write and the cache fetch.
  generate
    for(index = 0; index < WORDSPERLINE; index++) begin
      assign FinalWriteDataWordsM[((index+1)*`XLEN)-1 : (index*`XLEN)] = FinalAMOWriteDataM;
    end
  endgenerate

  mux2 #(BLOCKLEN) WriteDataMux(.d0(FinalWriteDataWordsM),
				.d1(DCacheMemWriteData),
				.s(SRAMBlockWriteEnableM),
				.y(SRAMWriteData));


  // control path *** eventually move to own module.


  
  localparam FetchCountThreshold = WORDSPERLINE - 1;
  

  assign AnyCPUReqM = |MemRWM | (|AtomicM);
  assign FetchCountFlag = (FetchCount == FetchCountThreshold[LOGWPL-1:0]);

  flopenr #(LOGWPL) 
  FetchCountReg(.clk(clk),
		.reset(reset | CntReset),
		.en(CntEn),
		.d(NextFetchCount),
		.q(FetchCount));

  assign NextFetchCount = FetchCount + 1'b1;

  assign SRAMWriteEnable = SRAMBlockWriteEnableM | SRAMWordWriteEnableM;

  flopr #(1)
  SRAMWritePipeReg(.clk(clk),
	      .reset(reset),
	      .d({SRAMWordWriteEnableM}),
	      .q({SRAMWordWriteEnableW}));

  
  always_ff @(posedge clk, posedge reset)
    if (reset)    CurrState <= #1 STATE_READY;
    else CurrState <= #1 NextState;

  
  // next state logic and some state ouputs.
  always_comb begin
    DCacheStall = 1'b0;
    SelAdrM = 2'b00;
    PreCntEn = 1'b0;
    SetValidM = 1'b0;
    ClearValidM = 1'b0;
    SetDirtyM = 1'b0;    
    ClearDirtyM = 1'b0;
    SelMemWriteDataM = 1'b0;
    SRAMWordWriteEnableM = 1'b0;
    SRAMBlockWriteEnableM = 1'b0;
    SaveSRAMRead = 1'b1;
    CntReset = 1'b0;
    AHBRead = 1'b0;
    AHBWrite = 1'b0;
    SelAMOWrite = 1'b0;
    CommittedM = 1'b0;        
    SelUncached = 1'b0;
    SelEvict = 1'b0;
    DCacheAccess = 1'b0;
    DCacheMiss = 1'b0;
    LRUWriteEn = 1'b0;
    MemAfterIWalkDone = 1'b0;

    case (CurrState)
      STATE_READY: begin
	// TLB Miss	
	if((AnyCPUReqM & DTLBMissM) | ITLBMissF) begin
	  // the LSU arbiter has not yet selected the PTW.
	  // The CPU needs to be stalled until that happens.
	  // If we set DCacheStall for 1 cycle before going to
	  // PTW ready the CPU will stall.
	  // The page table walker asserts it's control 1 cycle
	  // after the TLBs miss.
	  CommittedM = 1'b1;
	  DCacheStall = 1'b1;
	  NextState = STATE_PTW_READY;
	end
/* -----\/----- EXCLUDED -----\/-----
	else if(SelPTW) begin
	  // Now we have activated the ptw.
	  // Do not assert Stall as we are now directing the stall the ptw.
	  NextState = STATE_PTW_READY;
	  CommittedM = 1'b1;
	end
 -----/\----- EXCLUDED -----/\----- */
	// amo hit
/* -----\/----- EXCLUDED -----\/-----
	else if(|AtomicM & CacheableM & ~(ExceptionM | PendingInterruptM) & CacheHit & ~DTLBMissM) begin
	  NextState = STATE_AMO_UPDATE;
	  DCacheStall = 1'b1;

	  if(StallWtoDCache) begin 
            NextState = STATE_CPU_BUSY;
            SelAdrM = 2'b01; 
	  else NextState = STATE_AMO_UPDATE;
	end
 -----/\----- EXCLUDED -----/\----- */
	// read hit valid cached
	else if(MemRWM[1] & CacheableM & ~(ExceptionM | PendingInterruptM) & CacheHit & ~DTLBMissM) begin
	  DCacheStall = 1'b0;
	  DCacheAccess = 1'b1;
	  LRUWriteEn = 1'b1;
	  
	  if(StallWtoDCache) begin
	    NextState = STATE_CPU_BUSY;
            SelAdrM = 2'b01;
	  end
	  else begin
	    NextState = STATE_READY;
	    end
	end
	// write hit valid cached
	else if (MemRWM[0] & CacheableM & ~(ExceptionM | PendingInterruptM) & CacheHit & ~DTLBMissM) begin
	  SelAdrM = 2'b01;
	  DCacheStall = 1'b0;
	  SRAMWordWriteEnableM = 1'b1;
	  SetDirtyM = 1'b1;
	  DCacheStall = 1'b1;
	  LRUWriteEn = 1'b1;
	  
	  if(StallWtoDCache) begin 
	    NextState = STATE_CPU_BUSY;
	    SelAdrM = 2'b01;
	  end
	  else begin
	    NextState = STATE_READY;
	  end
	end
	// read or write miss valid cached
	else if((|MemRWM) & CacheableM & ~(ExceptionM | PendingInterruptM) & ~CacheHit & ~DTLBMissM) begin
	  NextState = STATE_MISS_FETCH_WDV;
	  CntReset = 1'b1;
	  DCacheStall = 1'b1;
	  DCacheAccess = 1'b1;
	  DCacheMiss = 1'b1;
	end
	// uncached write
	else if(MemRWM[0] & ~CacheableM & ~(ExceptionM | PendingInterruptM) & ~DTLBMissM) begin
	  NextState = STATE_UNCACHED_WRITE;
	  CntReset = 1'b1;
	  DCacheStall = 1'b1;
	  AHBWrite = 1'b1;
	end
	// uncached read
	else if(MemRWM[1] & ~CacheableM & ~(ExceptionM | PendingInterruptM) & ~DTLBMissM) begin
	  NextState = STATE_UNCACHED_READ;
	  CntReset = 1'b1;
	  DCacheStall = 1'b1;
	  AHBRead = 1'b1;	  
	end
	// fault
	else if(AnyCPUReqM & (ExceptionM | PendingInterruptM) & ~DTLBMissM) begin
	  NextState = STATE_READY;
	end
	else NextState = STATE_READY;
      end
      
      STATE_AMO_UPDATE: begin
	NextState = STATE_AMO_WRITE;
	SaveSRAMRead = 1'b1;
	SRAMWordWriteEnableM = 1'b1; // pipelined 1 cycle
      end
      STATE_AMO_WRITE: begin
	SelAMOWrite = 1'b1;
	if(StallWtoDCache) begin 
	  NextState = STATE_CPU_BUSY;
	  SelAdrM = 2'b01;
	end
	else begin
	  NextState = STATE_READY;
	end	  
      end

      STATE_MISS_FETCH_WDV: begin
	DCacheStall = 1'b1;
        PreCntEn = 1'b1;
	AHBRead = 1'b1;
	SelAdrM = 2'b01;
	CommittedM = 1'b1;
	
        if (FetchCountFlag & AHBAck) begin
          NextState = STATE_MISS_FETCH_DONE;
        end else begin
          NextState = STATE_MISS_FETCH_WDV;
        end
      end

      STATE_MISS_FETCH_DONE: begin
	DCacheStall = 1'b1;
	SelAdrM = 2'b01;
        CntReset = 1'b1;
	CommittedM = 1'b1;
	if(VictimDirty) begin
	  NextState = STATE_MISS_EVICT_DIRTY;
	end else begin
	  NextState = STATE_MISS_WRITE_CACHE_BLOCK;
	end
      end

      STATE_MISS_WRITE_CACHE_BLOCK: begin
	SRAMBlockWriteEnableM = 1'b1;
	DCacheStall = 1'b1;
	NextState = STATE_MISS_READ_WORD;
	SelAdrM = 2'b01;
	SetValidM = 1'b1;
	ClearDirtyM = 1'b1;
	CommittedM = 1'b1;
	//LRUWriteEn = 1'b1;  // DO not update LRU on SRAM fetch update.  Wait for subsequent read/write
      end

      STATE_MISS_READ_WORD: begin
	SelAdrM = 2'b01;
	DCacheStall = 1'b1;
	CommittedM = 1'b1;
	if (MemRWM[1]) begin
	  NextState = STATE_MISS_READ_WORD_DELAY;
	  // delay state is required as the read signal MemRWM[1] is still high when we
	  // return to the ready state because the cache is stalling the cpu.
	end else begin
	  NextState = STATE_MISS_WRITE_WORD;
	end
      end

      STATE_MISS_READ_WORD_DELAY: begin
	//SelAdrM = 2'b01;
	CommittedM = 1'b1;
	LRUWriteEn = 1'b1;
	if(StallWtoDCache) begin 
	  NextState = STATE_CPU_BUSY;
	  SelAdrM = 2'b01;
	end
	else begin
	  NextState = STATE_READY;
	end
      end

      STATE_MISS_WRITE_WORD: begin
	SRAMWordWriteEnableM = 1'b1;
	SetDirtyM = 1'b1;
	SelAdrM = 2'b01;
	DCacheStall = 1'b1;
	CommittedM = 1'b1;
	LRUWriteEn = 1'b1;
	NextState = STATE_MISS_WRITE_WORD_DELAY;
      end

      STATE_MISS_WRITE_WORD_DELAY: begin
	CommittedM = 1'b1;
	if(StallWtoDCache) begin 
	  NextState = STATE_CPU_BUSY;
	  SelAdrM = 2'b01;
	end
	else begin
	  NextState = STATE_READY;
	end
      end

      STATE_MISS_EVICT_DIRTY: begin
	DCacheStall = 1'b1;
        PreCntEn = 1'b1;
	AHBWrite = 1'b1;
	SelAdrM = 2'b01;
	CommittedM = 1'b1;
	SelEvict = 1'b1;
	if( FetchCountFlag & AHBAck) begin
	  NextState = STATE_MISS_WRITE_CACHE_BLOCK;
	end else begin
	  NextState = STATE_MISS_EVICT_DIRTY;
	end	  
      end

      STATE_PTW_READY: begin
	// now all output connect to PTW instead of CPU.
	CommittedM = 1'b1;

	// In this branch we remove stall and go back to ready.  There is no request for memory from the
	// datapath or the walker had a fault.
	// types 3b, 4a, 4b, and 7c.
	if ((DTLBMissM & WalkerPageFaultM) | // 3b
	    (ITLBMissF & (WalkerInstrPageFaultF | ITLBWriteF) & ~AnyCPUReqM & ~DTLBMissM) | // 4a and 4b
	    (DTLBMissM & ITLBMissF & WalkerPageFaultM)) begin // 7c
	  NextState = STATE_READY;
	  DCacheStall = 1'b0;
	end
	// in this branch we go back to ready, but there is a memory operation from
	// the datapath so we MUST stall and replay the operation.
	// types 3a and 5a
	else if ((DTLBMissM & DTLBWriteM) |  // 3a
		 (ITLBMissF & ITLBWriteF & AnyCPUReqM)) begin // 5a
	  NextState = STATE_READY;
	  DCacheStall = 1'b1;
	  SelAdrM = 2'b10;
	end

	// like 5a we want to stall and go to the ready state, but we also have to save
	// the WalkerInstrPageFaultF so it is held until the end of the memory operation
	// from the datapath.
	// types 5b
	else if (ITLBMissF & WalkerInstrPageFaultF & AnyCPUReqM) begin // 5b
	  NextState = STATE_PTW_FAULT_READY;
	  DCacheStall = 1'b1;
	  SelAdrM = 2'b10;
	end

	// in this branch we stay in ptw_ready because we are doing an itlb walk
	// after a dtlb walk.
	// types 7a and 7b.
	else if (DTLBMissM & DTLBWriteM & ITLBMissF)begin
	  NextState = STATE_PTW_READY;
	  DCacheStall = 1'b0;
	  
	// read hit valid cached
	end else if(MemRWM[1] & CacheableM & ~ExceptionM & CacheHit) begin
	  NextState = STATE_PTW_READY;
	  DCacheStall = 1'b0;
	  LRUWriteEn = 1'b1;
	end

	// read miss valid cached
	else if(SelPTW & MemRWM[1] & CacheableM & ~ExceptionM & ~CacheHit) begin
	  NextState = STATE_PTW_READ_MISS_FETCH_WDV;
	  CntReset = 1'b1;
	  DCacheStall = 1'b1;
	end

	else begin
	  NextState = STATE_PTW_READY;
	  DCacheStall = 1'b0;
	end
      end

      STATE_PTW_READ_MISS_FETCH_WDV: begin
	DCacheStall = 1'b1;
        PreCntEn = 1'b1;
	AHBRead = 1'b1;
	SelAdrM = 2'b01;
	CommittedM = 1'b1;
	
        if (FetchCountFlag & AHBAck) begin
          NextState = STATE_PTW_READ_MISS_FETCH_DONE;
        end else begin
          NextState = STATE_PTW_READ_MISS_FETCH_WDV;
        end
      end

      STATE_PTW_READ_MISS_FETCH_DONE: begin
	DCacheStall = 1'b1;
	SelAdrM = 2'b01;
        CntReset = 1'b1;
	CommittedM = 1'b1;
        CntReset = 1'b1;
	if(VictimDirty) begin
	  NextState = STATE_PTW_READ_MISS_EVICT_DIRTY;
	end else begin
	  NextState = STATE_PTW_READ_MISS_WRITE_CACHE_BLOCK;
	end
      end

      STATE_PTW_READ_MISS_EVICT_DIRTY: begin
	DCacheStall = 1'b1;
        PreCntEn = 1'b1;
	AHBWrite = 1'b1;
	SelAdrM = 2'b01;
	CommittedM = 1'b1;
	SelEvict = 1'b1;
	if( FetchCountFlag & AHBAck) begin
	  NextState = STATE_PTW_READ_MISS_WRITE_CACHE_BLOCK;
	end else begin
	  NextState = STATE_PTW_READ_MISS_EVICT_DIRTY;
	end	  
      end
      

      STATE_PTW_READ_MISS_WRITE_CACHE_BLOCK: begin
	SRAMBlockWriteEnableM = 1'b1;
	DCacheStall = 1'b1;
	NextState = STATE_PTW_READ_MISS_READ_WORD;
	SelAdrM = 2'b01;
	SetValidM = 1'b1;
	ClearDirtyM = 1'b1;
	CommittedM = 1'b1;
	//LRUWriteEn = 1'b1;
      end

      STATE_PTW_READ_MISS_READ_WORD: begin
	SelAdrM = 2'b01;
	DCacheStall = 1'b1;
	CommittedM = 1'b1;
	NextState = STATE_PTW_READ_MISS_READ_WORD_DELAY;
      end

      STATE_PTW_READ_MISS_READ_WORD_DELAY: begin
	SelAdrM = 2'b01;
	NextState = STATE_PTW_READY;
	CommittedM = 1'b1;
      end
      
      STATE_PTW_ACCESS_AFTER_WALK: begin
	DCacheStall = 1'b1;
	SelAdrM = 2'b01;
	CommittedM = 1'b1;
	LRUWriteEn = 1'b1;
	NextState = STATE_READY;
      end
      
      STATE_CPU_BUSY: begin
	CommittedM = 1'b1;
	if(StallWtoDCache) begin
	  NextState = STATE_CPU_BUSY;
	  SelAdrM = 2'b01;
	end
	else begin
	  NextState = STATE_READY;
	end
      end

      STATE_UNCACHED_WRITE : begin
	DCacheStall = 1'b1;	
	AHBWrite = 1'b1;
	CommittedM = 1'b1;
	if(AHBAck) begin
	  NextState = STATE_UNCACHED_WRITE_DONE;
	end else begin
	  NextState = STATE_UNCACHED_WRITE;
	end
      end

      STATE_UNCACHED_READ : begin
	DCacheStall = 1'b1;	
	AHBRead = 1'b1;
	CommittedM = 1'b1;
	if(AHBAck) begin
	  NextState = STATE_UNCACHED_READ_DONE;
	end else begin
	  NextState = STATE_UNCACHED_READ;
	end
      end
      
      STATE_UNCACHED_WRITE_DONE: begin
	CommittedM = 1'b1;
	if(StallWtoDCache) begin
	  NextState = STATE_CPU_BUSY;
	  SelAdrM = 2'b01;
	end
	else begin
	  NextState = STATE_READY;
	end
      end

      STATE_UNCACHED_READ_DONE: begin
	CommittedM = 1'b1;
	SelUncached = 1'b1;
	if(StallWtoDCache) begin 
	  NextState = STATE_CPU_BUSY;
	  SelAdrM = 2'b01;
	end
	else begin
	  NextState = STATE_READY;
	end 
      end


      // itlb => instruction page fault states with memory request.
      STATE_PTW_FAULT_READY: begin
	// read hit valid cached
	if(MemRWM[1] & CacheableM & CacheHit & ~DTLBMissM) begin
	  DCacheStall = 1'b0;
	  DCacheAccess = 1'b1;
	  LRUWriteEn = 1'b1;
	  
	  if(StallWtoDCache) begin
	    NextState = STATE_PTW_FAULT_CPU_BUSY;
            SelAdrM = 2'b01;
	  end
	  else begin
	    MemAfterIWalkDone = 1'b1;
	    NextState = STATE_READY;
	  end
	end
	
	// write hit valid cached
	else if (MemRWM[0] & CacheableM & CacheHit & ~DTLBMissM) begin
	  SelAdrM = 2'b01;
	  DCacheStall = 1'b0;
	  SRAMWordWriteEnableM = 1'b1;
	  SetDirtyM = 1'b1;
	  DCacheStall = 1'b1;
	  LRUWriteEn = 1'b1;
	  
	  if(StallWtoDCache) begin 
	    NextState = STATE_PTW_FAULT_CPU_BUSY;
	    SelAdrM = 2'b01;
	  end
	  else begin
	    MemAfterIWalkDone = 1'b1;
	    NextState = STATE_READY;
	  end
	end
	// read or write miss valid cached
	else if((|MemRWM) & CacheableM & ~CacheHit & ~DTLBMissM) begin
	  NextState = STATE_PTW_FAULT_MISS_FETCH_WDV;
	  CntReset = 1'b1;
	  DCacheStall = 1'b1;
	  DCacheAccess = 1'b1;
	  DCacheMiss = 1'b1;
	end
	// uncached write
	else if(MemRWM[0] & ~CacheableM & ~DTLBMissM) begin
	  NextState = STATE_PTW_FAULT_UNCACHED_WRITE;
	  CntReset = 1'b1;
	  DCacheStall = 1'b1;
	  AHBWrite = 1'b1;
	end
	// uncached read
	else if(MemRWM[1] & ~CacheableM & ~DTLBMissM) begin
	  NextState = STATE_PTW_FAULT_UNCACHED_READ;
	  CntReset = 1'b1;
	  DCacheStall = 1'b1;
	  AHBRead = 1'b1;	  
	end
	// fault
	else  begin
	  MemAfterIWalkDone = 1'b1;
	  NextState = STATE_READY;
	end
      end
      
      STATE_PTW_FAULT_CPU_BUSY: begin
	CommittedM = 1'b1;
	if(StallWtoDCache) begin
	  NextState = STATE_PTW_FAULT_CPU_BUSY;
	  SelAdrM = 2'b01;
	end
	else begin
	  MemAfterIWalkDone = 1'b1;
	  NextState = STATE_READY;
	end
      end

      STATE_PTW_FAULT_MISS_FETCH_WDV: begin
	DCacheStall = 1'b1;
        PreCntEn = 1'b1;
	AHBRead = 1'b1;
	SelAdrM = 2'b01;
	CommittedM = 1'b1;
	
        if (FetchCountFlag & AHBAck) begin
          NextState = STATE_PTW_FAULT_MISS_FETCH_DONE;
        end else begin
          NextState = STATE_PTW_FAULT_MISS_FETCH_WDV;
        end
      end

      STATE_PTW_FAULT_MISS_FETCH_DONE: begin
	DCacheStall = 1'b1;
	SelAdrM = 2'b01;
        CntReset = 1'b1;
	CommittedM = 1'b1;
	if(VictimDirty) begin
	  NextState = STATE_PTW_FAULT_MISS_EVICT_DIRTY;
	end else begin
	  NextState = STATE_PTW_FAULT_MISS_WRITE_CACHE_BLOCK;
	end
      end

      STATE_PTW_FAULT_MISS_WRITE_CACHE_BLOCK: begin
	SRAMBlockWriteEnableM = 1'b1;
	DCacheStall = 1'b1;
	NextState = STATE_PTW_FAULT_MISS_READ_WORD;
	SelAdrM = 2'b01;
	SetValidM = 1'b1;
	ClearDirtyM = 1'b1;
	CommittedM = 1'b1;
	//LRUWriteEn = 1'b1;  // DO not update LRU on SRAM fetch update.  Wait for subsequent read/write
      end

      STATE_PTW_FAULT_MISS_READ_WORD: begin
	SelAdrM = 2'b01;
	DCacheStall = 1'b1;
	CommittedM = 1'b1;
	if (MemRWM[1]) begin
	  NextState = STATE_PTW_FAULT_MISS_READ_WORD_DELAY;
	  // delay state is required as the read signal MemRWM[1] is still high when we
	  // return to the ready state because the cache is stalling the cpu.
	end else begin
	  NextState = STATE_PTW_FAULT_MISS_WRITE_WORD;
	end
      end

      STATE_PTW_FAULT_MISS_READ_WORD_DELAY: begin
	CommittedM = 1'b1;
	LRUWriteEn = 1'b1;
	if(StallWtoDCache) begin 
	  NextState = STATE_PTW_FAULT_CPU_BUSY;
	  SelAdrM = 2'b01;
	end
	else begin
	  MemAfterIWalkDone = 1'b1;
	  NextState = STATE_READY;
	end
      end

      STATE_PTW_FAULT_MISS_WRITE_WORD: begin
	SRAMWordWriteEnableM = 1'b1;
	SetDirtyM = 1'b1;
	SelAdrM = 2'b01;
	DCacheStall = 1'b1;
	CommittedM = 1'b1;
	LRUWriteEn = 1'b1;
	NextState = STATE_PTW_FAULT_MISS_WRITE_WORD_DELAY;
      end

      STATE_PTW_FAULT_MISS_WRITE_WORD_DELAY: begin
	CommittedM = 1'b1;
	if(StallWtoDCache) begin 
	  NextState = STATE_PTW_FAULT_CPU_BUSY;
	  SelAdrM = 2'b01;
	end
	else begin
	  MemAfterIWalkDone = 1'b1;
	  NextState = STATE_READY;
	end
      end

      STATE_PTW_FAULT_MISS_EVICT_DIRTY: begin
	DCacheStall = 1'b1;
        PreCntEn = 1'b1;
	AHBWrite = 1'b1;
	SelAdrM = 2'b01;
	CommittedM = 1'b1;
	SelEvict = 1'b1;
	if( FetchCountFlag & AHBAck) begin
	  NextState = STATE_PTW_FAULT_MISS_WRITE_CACHE_BLOCK;
	end else begin
	  NextState = STATE_PTW_FAULT_MISS_EVICT_DIRTY;
	end	  
      end


      STATE_PTW_FAULT_UNCACHED_WRITE : begin
	DCacheStall = 1'b1;	
	AHBWrite = 1'b1;
	CommittedM = 1'b1;
	if(AHBAck) begin
	  NextState = STATE_PTW_FAULT_UNCACHED_WRITE_DONE;
	end else begin
	  NextState = STATE_PTW_FAULT_UNCACHED_WRITE;
	end
      end

      STATE_PTW_FAULT_UNCACHED_READ : begin
	DCacheStall = 1'b1;	
	AHBRead = 1'b1;
	CommittedM = 1'b1;
	if(AHBAck) begin
	  NextState = STATE_PTW_FAULT_UNCACHED_READ_DONE;
	end else begin
	  NextState = STATE_PTW_FAULT_UNCACHED_READ;
	end
      end
      
      STATE_PTW_FAULT_UNCACHED_WRITE_DONE: begin
	CommittedM = 1'b1;
	if(StallWtoDCache) begin
	  NextState = STATE_PTW_FAULT_CPU_BUSY;
	  SelAdrM = 2'b01;
	end
	else begin
	  MemAfterIWalkDone = 1'b1;
	  NextState = STATE_READY;
	end
      end

      STATE_PTW_FAULT_UNCACHED_READ_DONE: begin
	CommittedM = 1'b1;
	SelUncached = 1'b1;
	if(StallWtoDCache) begin 
	  NextState = STATE_PTW_FAULT_CPU_BUSY;
	  SelAdrM = 2'b01;
	end
	else begin
	  MemAfterIWalkDone = 1'b1;
	  NextState = STATE_READY;
	end 
      end

      default: begin
      end
    endcase
  end

  assign CntEn = PreCntEn & AHBAck;

endmodule // dcache
