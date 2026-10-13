// Code your design here
module fifo#(parameter depth=4,parameter width=4)(
  input [width-1:0]data,
  input clk,reset,
  input read,write,      //0 : read, 1: write
  output reg [width-1:0]out,
  output full,empty
);
  
  
  reg [$clog2(depth)-1:0]rdp,wrp;
  reg [width-1:0]arr[depth-1:0];
  reg [$clog2(depth):0] count;
  
  assign full =(count==depth);
  assign empty = (count==0);
  
  //write logic
  always@(posedge clk)begin
    if(!reset) begin
      wrp<=0;
  end
    else if (write && (!full||read)) begin 
        arr[wrp]<=data;
        wrp <= wrp+1;
      end
  end
  //read logic
   always@(posedge clk)begin
    if(!reset) begin
      rdp<=0;
  end
    else if (read && !empty) begin 
         out <= arr[rdp];
        rdp <= rdp+1;
      end
  end
  //count logic
  
   always@(posedge clk)begin
    if(!reset) begin
      count<=0;
  end
    else  begin
      case({(write && (!full||read)),(read && !empty)})
        2'b10:count <=count+1;
        2'b01: count <=count-1;
      default : count <= count;
      endcase
        end
  end
endmodule
  
  