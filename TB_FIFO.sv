package fifo_pkg;
  parameter int WIDTH = 8;
  parameter int DEPTH = 4;
endpackage

import fifo_pkg::*;

// ============================================================
// INTERFACE
// ============================================================
interface fifo_if(input logic clk);

  logic [WIDTH-1:0] data;
  logic reset;
  logic read, write;
  logic [WIDTH-1:0] out;
  logic full, empty;

endinterface


// ============================================================
// TRANSACTION
// ============================================================
class transaction;

  rand bit rd;
  rand bit wr;
  rand logic [WIDTH-1:0] data;

  logic [WIDTH-1:0] out;
  logic full, empty;

  constraint c1 {
    data inside {[8'h01:8'hDD]};

    wr dist {1 := 6, 0 := 4};
    rd dist {1 := 5, 0 := 5};
  }

  function void display(string tag = "");
    $display("[%s] data=%02h read=%0b write=%0b out=%02h full=%0b empty=%0b",
             tag, data, rd, wr, out, full, empty);
  endfunction

endclass


// ============================================================
// GENERATOR
// ============================================================
class generator;

  mailbox #(transaction) gen2drv;

  function new(mailbox #(transaction) mb);
    gen2drv = mb;
  endfunction

  task run();
    transaction tr;

    repeat (100) begin
      tr = new();

      if (!tr.randomize())
        $fatal(1, "Transaction randomization failed");

      tr.display("GEN");
      gen2drv.put(tr);
    end

    $display("[GEN] Generated 100 transactions");
  endtask

endclass


// ============================================================
// DRIVER
// Drives at negedge; DUT samples at posedge.
// ============================================================
class driver;

  virtual fifo_if vif;
  mailbox #(transaction) gen2drv;

  function new(mailbox #(transaction) mb, virtual fifo_if vif);
    gen2drv = mb;
    this.vif = vif;
  endfunction

  task run();
    transaction tr;

    vif.write = 0;
    vif.read  = 0;
    vif.data  = '0;

    wait (vif.reset == 1'b1);

    forever begin
      gen2drv.get(tr);

      @(negedge vif.clk);
      vif.data  <= tr.data;
      vif.write <= tr.wr;
      vif.read  <= tr.rd;

      tr.display("DRV");

      // Keep request stable through the DUT's sampling edge.
      @(negedge vif.clk);
      vif.write <= 0;
      vif.read  <= 0;
    end
  endtask

endclass


// ============================================================
// MONITOR
// Captures the transaction and post-edge outputs.
// ============================================================
class monitor;

  virtual fifo_if vif;
  mailbox #(transaction) mon2sb;

  function new(mailbox #(transaction) mb, virtual fifo_if vif);
    mon2sb = mb;
    this.vif = vif;
  endfunction

  task run();
    transaction tr;

    forever begin
      @(posedge vif.clk);
      #1;

      if (vif.reset) begin
        tr = new();

        tr.rd    = vif.read;
        tr.wr    = vif.write;
        tr.data  = vif.data;
        tr.out   = vif.out;
        tr.full  = vif.full;
        tr.empty = vif.empty;

        tr.display("MON");
        mon2sb.put(tr);
      end
    end
  endtask

endclass


// ============================================================
// SCOREBOARD
// ============================================================
class scoreboard;

  mailbox #(transaction) mon2sb;

  logic [WIDTH-1:0] model_mem [0:DEPTH-1];
  logic [WIDTH-1:0] expected_out;

  int unsigned rdp, wrp;
  int unsigned count;

  int pass, fail;
  int accepted_reads, accepted_writes;

  bit read_accepted;
  bit write_accepted;

  function new(mailbox #(transaction) mb);
    mon2sb = mb;

    rdp = 0;
    wrp = 0;
    count = 0;

    pass = 0;
    fail = 0;
    accepted_reads = 0;
    accepted_writes = 0;
  endfunction

  task run();
    transaction tr;

    forever begin
      mon2sb.get(tr);

      // Determine acceptance using the model's PRE-edge state.
      read_accepted = tr.rd && (count > 0);

      write_accepted =
          tr.wr && ((count < DEPTH) || read_accepted);

      // Save the OLD FIFO head before changing model memory.
      if (read_accepted)
        expected_out = model_mem[rdp];

      // Update model read pointer.
      if (read_accepted) begin
        rdp = (rdp + 1) % DEPTH;
        accepted_reads++;
      end

      // Update model write pointer and memory.
      if (write_accepted) begin
        model_mem[wrp] = tr.data;
        wrp = (wrp + 1) % DEPTH;
        accepted_writes++;
      end

      // Update expected occupancy.
      case ({write_accepted, read_accepted})
        2'b10: count++;
        2'b01: count--;
        default: count = count;
      endcase

      // Compare output only when a read was accepted.
      if (read_accepted) begin
        if (tr.out === expected_out) begin
          pass++;
          $display("[SB] PASS expected=%02h actual=%02h",
                   expected_out, tr.out);
        end
        else begin
          fail++;
          $error("[SB] FAIL expected=%02h actual=%02h",
                 expected_out, tr.out);
        end
      end

      // Flags are checked against POST-edge occupancy.
      if (tr.full !== (count == DEPTH)) begin
        fail++;
        $error("[SB] FULL mismatch: DUT=%b model_count=%0d",
               tr.full, count);
      end

      if (tr.empty !== (count == 0)) begin
        fail++;
        $error("[SB] EMPTY mismatch: DUT=%b model_count=%0d",
               tr.empty, count);
      end
    end
  endtask

  function void report();
    $display("\n========== SCOREBOARD REPORT ==========");
    $display("Read data PASS     = %0d", pass);
    $display("Total failures     = %0d", fail);
    $display("Accepted reads     = %0d", accepted_reads);
    $display("Accepted writes    = %0d", accepted_writes);
    $display("Final model count  = %0d", count);
    $display("=======================================\n");
  endfunction

endclass


// ============================================================
// ENVIRONMENT
// ============================================================
class environment;

  generator gen;
  driver drv;
  monitor mon;
  scoreboard sb;

  mailbox #(transaction) gen2drv;
  mailbox #(transaction) mon2sb;

  function new(virtual fifo_if vif);

    gen2drv = new();
    mon2sb  = new();

    gen = new(gen2drv);
    drv = new(gen2drv, vif);
    mon = new(mon2sb, vif);
    sb  = new(mon2sb);

  endfunction

  task run();

    fork
      drv.run();
      mon.run();
      sb.run();

      begin
        gen.run();

        // Wait until the driver has pulled every transaction out of the
        // mailbox, then allow the last one to be driven, sampled by the
        // monitor and checked by the scoreboard before reporting.
        // (Polling loop: wait(gen2drv.num()==0) is not re-evaluated when the
        // mailbox count changes, so it can hang forever.)
        while (gen2drv.num() != 0)
          @(negedge drv.vif.clk);
        repeat (4) @(negedge drv.vif.clk);

        sb.report();
      end
    join_any

  endtask

endclass


// ============================================================
// TOP
// ============================================================
module tb;

  import fifo_pkg::*;

  logic clk = 0;

  always #5 clk = ~clk;

  fifo_if intf(clk);

  // DUT parameters are lowercase (width, depth); ports are
  // clk, reset, read, write, data, out, full, empty.
  fifo #(
    .width(WIDTH),
    .depth(DEPTH)
  ) dut (
    .clk   (clk),
    .reset (intf.reset),
    .read  (intf.read),
    .write (intf.write),
    .data  (intf.data),
    .out   (intf.out),
    .full  (intf.full),
    .empty (intf.empty)
  );


  // ==========================================================
  // FUNCTIONAL COVERAGE
  // ==========================================================
  covergroup fifo_cv @(posedge clk);

    option.per_instance = 1;

    cp_write: coverpoint intf.write {
      bins write_low  = {0};
      bins write_high = {1};
    }

    cp_read: coverpoint intf.read {
      bins read_low  = {0};
      bins read_high = {1};
    }

    cp_data: coverpoint intf.data {
      bins data1 = {[8'h01:8'h30]};
      bins data2 = {[8'h31:8'h60]};
      bins data3 = {[8'h61:8'h90]};
      bins data4 = {[8'h91:8'hB0]};
      bins data5 = {[8'hB1:8'hDD]};
      bins others = default;
    }

    cp_count: coverpoint dut.count {
      bins empty       = {0};
      bins one_entry   = {1};
      bins half_full   = {2};
      bins almost_full = {3};
      bins full        = {4};
      illegal_bins out_of_range = default;
    }

    cp_full: coverpoint intf.full;
    cp_empty: coverpoint intf.empty;

    // Includes idle, read-only, write-only and simultaneous requests.
    cp_operation: cross cp_write, cp_read;

  endgroup

  fifo_cv cov;


  // ==========================================================
  // ASSERTIONS
  // ==========================================================
  default clocking cb @(posedge clk);
  endclocking

  // The DUT uses an active-low synchronous reset.
  property full_check;
    disable iff (!intf.reset)
      intf.full |-> (dut.count == DEPTH);
  endproperty

  property empty_check;
    disable iff (!intf.reset)
      intf.empty |-> (dut.count == 0);
  endproperty

  property no_full_and_empty;
    disable iff (!intf.reset)
      !(intf.full && intf.empty);
  endproperty

  property count_in_range;
    disable iff (!intf.reset)
      dut.count <= DEPTH;
  endproperty

  property read_empty_holds_pointer;
    disable iff (!intf.reset)
      (intf.read && intf.empty) |=> $stable(dut.rdp);
  endproperty

  property write_full_holds_pointer;
    disable iff (!intf.reset)
      (intf.write && intf.full && !intf.read)
      |=> $stable(dut.wrp);
  endproperty

  a_full: assert property (full_check)
    else $error("[SVA] Full flag/count mismatch");

  a_empty: assert property (empty_check)
    else $error("[SVA] Empty flag/count mismatch");

  a_state: assert property (no_full_and_empty)
    else $error("[SVA] FIFO cannot be full and empty");

  a_count: assert property (count_in_range)
    else $error("[SVA] FIFO count out of range");

  a_read_empty: assert property (read_empty_holds_pointer)
    else $error("[SVA] Read pointer moved during empty read");

  a_write_full: assert property (write_full_holds_pointer)
    else $error("[SVA] Write pointer moved during rejected write");


  // ==========================================================
  // RESET AND TEST CONTROL
  // ==========================================================
  environment env;

  // Watchdog: 100 transactions need roughly 2000 ns; stop if it runs far longer.
  initial begin
    #100000;
    $fatal(1, "[TB] TIMEOUT: simulation did not finish");
  end

  initial begin
    intf.reset = 0;
    intf.write = 0;
    intf.read  = 0;
    intf.data  = 0;

    cov = new();

    // Apply reset across a rising clock edge.
    repeat (2) @(negedge clk);
    intf.reset = 1;

    env = new(intf);
    env.run();

    $display("[COVERAGE] Functional coverage = %0.2f%%",
             cov.get_inst_coverage());

    $finish;
  end

endmodule