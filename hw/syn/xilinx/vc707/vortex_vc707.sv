// Copyright © 2019-2023
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

`include "VX_define.vh"

// Standalone Vortex on the VC707: on-chip block RAM as device memory, the
// kernel preloaded into it, and a launch sequencer standing in for the host.
//
// LED[7]   Vortex busy
// LED[6:0] low bits of the last word the kernel stored to LED_ADDR

`ifndef SYS_DIV
`define SYS_DIV 20.000
`endif

module vortex_vc707 import VX_gpu_pkg::*; #(
    parameter MEM_LOG_LINES = 12,                  // 4096 x 64B = 256 KB
    parameter STARTUP_ADDR  = 32'h80000000,
    // inside Vortex's IO window [VX_MEM_IO_BASE_ADDR, VX_MEM_IO_END_ADDR), so
    // stores bypass the write-back D-cache and reach the memory port at once
    parameter LED_ADDR      = 32'h0000FF00
) (
    input  wire       IO_CLK_P,
    input  wire       IO_CLK_N,
    input  wire       IO_RST,
    output wire [7:0] LED
);
    localparam LINE_SIZE = VX_MEM_DATA_WIDTH / 8;
    localparam LINE_BITS = `CLOG2(LINE_SIZE);
    localparam PORT_BITS = `CLOG2(VX_MEM_PORTS);
    localparam TAG_WIDTH = VX_MEM_TAG_WIDTH + PORT_BITS;

    wire clk, clk_mac_unused, rst_sys_n, locked_unused;
    clkgen_vc707 #(.SYS_DIV(`SYS_DIV)) clkgen (
        .IO_CLK_P (IO_CLK_P),
        .IO_CLK_N (IO_CLK_N),
        .IO_RST_N (~IO_RST),
        .clk_sys  (clk),
        .clk_mac  (clk_mac_unused),
        .rst_sys_n(rst_sys_n),
        .locked   (locked_unused)
    );

    // Vortex wants reset held for several cycles so its internal relays settle.
    reg [8:0] rst_cnt = '0;
    wire reset = ~rst_cnt[8];
    always @(posedge clk) begin
        if (~rst_sys_n)
            rst_cnt <= '0;
        else if (reset)
            rst_cnt <= rst_cnt + 1'b1;
    end

    // ---------------------------------------------------------------- launch

    // One single-thread CTA, in the order the runtime programs the KMU.
    localparam [VX_DCR_ADDR_WIDTH-1:0] LAST_DCR = `VX_DCR_KMU_STATE_END - 1;

    function automatic [31:0] kmu_dcr_value(input [VX_DCR_ADDR_WIDTH-1:0] addr);
        case (addr)
        `VX_DCR_KMU_STARTUP_ADDR0,
        `VX_DCR_KMU_KERNEL_ENTRY0: kmu_dcr_value = STARTUP_ADDR;
        `VX_DCR_KMU_BLOCK_DIM_X,
        `VX_DCR_KMU_BLOCK_DIM_Y,
        `VX_DCR_KMU_BLOCK_DIM_Z,
        `VX_DCR_KMU_GRID_DIM_X,
        `VX_DCR_KMU_GRID_DIM_Y,
        `VX_DCR_KMU_GRID_DIM_Z,
        `VX_DCR_KMU_BLOCK_SIZE,
        `VX_DCR_KMU_CLUSTER_DIM_X,
        `VX_DCR_KMU_CLUSTER_DIM_Y,
        `VX_DCR_KMU_CLUSTER_DIM_Z: kmu_dcr_value = 32'd1;
        default:                   kmu_dcr_value = 32'd0;
        endcase
    endfunction

    localparam S_DCR = 2'd0, S_START = 2'd1, S_RUN = 2'd2;

    reg [1:0]                   state;
    reg [VX_DCR_ADDR_WIDTH-1:0] dcr_addr;
    reg                         dcr_valid;
    reg                         start;

    always @(posedge clk) begin
        if (reset) begin
            state     <= S_DCR;
            dcr_addr  <= `VX_DCR_KMU_STATE_BEGIN;
            dcr_valid <= 1'b0;
            start     <= 1'b0;
        end else begin
            dcr_valid <= 1'b0;
            start     <= 1'b0;
            case (state)
            S_DCR: begin
                if (dcr_valid) begin
                    if (dcr_addr == LAST_DCR)
                        state <= S_START;
                    else
                        dcr_addr <= dcr_addr + 1'b1;
                end else begin
                    dcr_valid <= 1'b1;
                end
            end
            S_START: begin
                start <= 1'b1;
                state <= S_RUN;
            end
            default:;
            endcase
        end
    end

    // ---------------------------------------------------------------- Vortex

    wire                           vx_mem_req_valid [VX_MEM_PORTS];
    wire                           vx_mem_req_rw [VX_MEM_PORTS];
    wire [VX_MEM_BYTEEN_WIDTH-1:0] vx_mem_req_byteen [VX_MEM_PORTS];
    wire [VX_MEM_ADDR_WIDTH-1:0]   vx_mem_req_addr [VX_MEM_PORTS];
    wire [VX_MEM_DATA_WIDTH-1:0]   vx_mem_req_data [VX_MEM_PORTS];
    wire [VX_MEM_TAG_WIDTH-1:0]    vx_mem_req_tag [VX_MEM_PORTS];
    wire                           vx_mem_req_ready [VX_MEM_PORTS];
    wire                           vx_mem_rsp_valid [VX_MEM_PORTS];
    wire [VX_MEM_DATA_WIDTH-1:0]   vx_mem_rsp_data [VX_MEM_PORTS];
    wire [VX_MEM_TAG_WIDTH-1:0]    vx_mem_rsp_tag [VX_MEM_PORTS];
    wire                           vx_mem_rsp_ready [VX_MEM_PORTS];

    wire                           dcr_rsp_valid_unused;
    wire [VX_DCR_DATA_WIDTH-1:0]   dcr_rsp_data_unused;
    wire                           busy;

    Vortex vortex (
        .clk            (clk),
        .reset          (reset),
        .mem_req_valid  (vx_mem_req_valid),
        .mem_req_rw     (vx_mem_req_rw),
        .mem_req_byteen (vx_mem_req_byteen),
        .mem_req_addr   (vx_mem_req_addr),
        .mem_req_data   (vx_mem_req_data),
        .mem_req_tag    (vx_mem_req_tag),
        .mem_req_ready  (vx_mem_req_ready),
        .mem_rsp_valid  (vx_mem_rsp_valid),
        .mem_rsp_data   (vx_mem_rsp_data),
        .mem_rsp_tag    (vx_mem_rsp_tag),
        .mem_rsp_ready  (vx_mem_rsp_ready),
        .dcr_req_valid  (dcr_valid),
        .dcr_req_rw     (1'b1),
        .dcr_req_addr   (dcr_addr),
        .dcr_req_data   (kmu_dcr_value(dcr_addr)),
        .dcr_rsp_valid  (dcr_rsp_valid_unused),
        .dcr_rsp_data   (dcr_rsp_data_unused),
        .start          (start),
        .busy           (busy)
    );

    // All memory ports onto the one block RAM.
    wire                           mem_req_valid [1];
    wire                           mem_req_rw [1];
    wire [LINE_SIZE-1:0]           mem_req_byteen [1];
    wire [VX_MEM_ADDR_WIDTH-1:0]   mem_req_addr [1];
    wire [VX_MEM_DATA_WIDTH-1:0]   mem_req_data [1];
    wire [TAG_WIDTH-1:0]           mem_req_tag [1];
    wire                           mem_req_ready [1];
    wire                           mem_rsp_valid [1];
    wire [VX_MEM_DATA_WIDTH-1:0]   mem_rsp_data [1];
    wire [TAG_WIDTH-1:0]           mem_rsp_tag [1];
    wire                           mem_rsp_ready [1];

    VX_mem_bank_adapter #(
        .DATA_WIDTH     (VX_MEM_DATA_WIDTH),
        .ADDR_WIDTH_IN  (VX_MEM_ADDR_WIDTH),
        .ADDR_WIDTH_OUT (VX_MEM_ADDR_WIDTH),
        .TAG_WIDTH_IN   (VX_MEM_TAG_WIDTH),
        .TAG_WIDTH_OUT  (TAG_WIDTH),
        .NUM_PORTS_IN   (VX_MEM_PORTS),
        .NUM_BANKS_OUT  (1),
        .REQ_OUT_BUF    ((VX_MEM_PORTS > 1) ? 2 : 0),
        .RSP_OUT_BUF    ((VX_MEM_PORTS > 1) ? 2 : 0)
    ) mem_bank_adapter (
        .clk                (clk),
        .reset              (reset),
        .mem_req_valid_in   (vx_mem_req_valid),
        .mem_req_rw_in      (vx_mem_req_rw),
        .mem_req_byteen_in  (vx_mem_req_byteen),
        .mem_req_addr_in    (vx_mem_req_addr),
        .mem_req_data_in    (vx_mem_req_data),
        .mem_req_tag_in     (vx_mem_req_tag),
        .mem_req_ready_in   (vx_mem_req_ready),
        .mem_rsp_valid_in   (vx_mem_rsp_valid),
        .mem_rsp_data_in    (vx_mem_rsp_data),
        .mem_rsp_tag_in     (vx_mem_rsp_tag),
        .mem_rsp_ready_in   (vx_mem_rsp_ready),
        .mem_req_valid_out  (mem_req_valid),
        .mem_req_rw_out     (mem_req_rw),
        .mem_req_byteen_out (mem_req_byteen),
        .mem_req_addr_out   (mem_req_addr),
        .mem_req_data_out   (mem_req_data),
        .mem_req_tag_out    (mem_req_tag),
        .mem_req_ready_out  (mem_req_ready),
        .mem_rsp_valid_out  (mem_rsp_valid),
        .mem_rsp_data_out   (mem_rsp_data),
        .mem_rsp_tag_out    (mem_rsp_tag),
        .mem_rsp_ready_out  (mem_rsp_ready)
    );

    // ---------------------------------------------------------------- memory

    // One-cycle read latency; a stalled response holds the RAM output (no new
    // read is accepted until it drains). Writes are posted: no response.
    reg                 rsp_valid;
    reg [TAG_WIDTH-1:0] rsp_tag;

    wire req_ready = ~rsp_valid | mem_rsp_ready[0];
    wire req_fire  = mem_req_valid[0] & req_ready;
    wire rd_fire   = req_fire & ~mem_req_rw[0];
    wire wr_fire   = req_fire & mem_req_rw[0];

    always @(posedge clk) begin
        if (reset) begin
            rsp_valid <= 1'b0;
        end else if (req_ready) begin
            rsp_valid <= rd_fire;
        end
        if (rd_fire)
            rsp_tag <= mem_req_tag[0];
    end

    assign mem_req_ready[0] = req_ready;
    assign mem_rsp_valid[0] = rsp_valid;
    assign mem_rsp_tag[0]   = rsp_tag;

    wire [MEM_LOG_LINES-1:0] ram_addr = mem_req_addr[0][MEM_LOG_LINES-1:0];

    // Byte-wide lanes: each is one plain 4K x 8 block RAM with its own init image.
    for (genvar i = 0; i < LINE_SIZE; ++i) begin : g_lane
        vortex_vc707_lane #(
            .LOG_DEPTH (MEM_LOG_LINES),
            .INIT_FILE ({"lane", 8'("0" + i / 10), 8'("0" + i % 10), ".hex"})
        ) lane (
            .clk   (clk),
            .en    (rd_fire),
            .we    (wr_fire & mem_req_byteen[0][i]),
            .addr  (ram_addr),
            .wdata (mem_req_data[0][i*8 +: 8]),
            .rdata (mem_rsp_data[0][i*8 +: 8])
        );
    end

    // ---------------------------------------------------------------- LEDs

    localparam [VX_MEM_ADDR_WIDTH-1:0] LED_LINE = VX_MEM_ADDR_WIDTH'(LED_ADDR >> LINE_BITS);
    localparam LED_BYTE = (LED_ADDR % LINE_SIZE);

    reg [6:0] led_r;
    always @(posedge clk) begin
        if (reset)
            led_r <= '0;
        else if (wr_fire && mem_req_addr[0] == LED_LINE && mem_req_byteen[0][LED_BYTE])
            led_r <= mem_req_data[0][LED_BYTE*8 +: 7];
    end

    assign LED = {busy, led_r};

endmodule

module vortex_vc707_lane #(
    parameter LOG_DEPTH = 12,
    parameter INIT_FILE = ""
) (
    input  wire                 clk,
    input  wire                 en,
    input  wire                 we,
    input  wire [LOG_DEPTH-1:0] addr,
    input  wire [7:0]           wdata,
    output reg  [7:0]           rdata
);
    reg [7:0] mem [0:(1<<LOG_DEPTH)-1];
    initial $readmemh(INIT_FILE, mem);
    always @(posedge clk) begin
        if (we)
            mem[addr] <= wdata;
        if (en)
            rdata <= mem[addr];
    end
endmodule
