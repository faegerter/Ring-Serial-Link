// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Author: Llorenç Muela Hausmann <lmuela@ethz.ch>
// Author: Fabian Aegerter <faegerter@ethz.ch>
//
// Non-parameterized performance/metrics collector. Events are passed as
// primitive types so a single monitor handle can be shared across
// heterogeneously parameterized Nodes in the same testbench.

`ifndef SLINK_PERF_MONITOR_SVH
`define SLINK_PERF_MONITOR_SVH

class SlinkPerfMonitor;

    typedef struct {
        longint unsigned n_issued;
        longint unsigned n_completed;
        longint unsigned n_errors;
        longint unsigned latency_cyc_sum;
        longint unsigned latency_cyc_sum_from_granted;
        longint unsigned latency_cyc_min;
        longint unsigned latency_cyc_max;
        longint unsigned latency_cyc_min_from_granted;
        longint unsigned latency_cyc_max_from_granted;
        longint unsigned payload_bytes;   // Useful bytes transferred (only data bytes)
        longint unsigned effective_bytes; // Number of bytes transferred, including headers etc
    } stats_t;

    string       label;
    realtime     t_start;
    realtime     t_end;
    int unsigned latency_bin_cyc;
    int unsigned latency_num_bins;

    // Indexed by node_id and by tag (caller-supplied int)
    stats_t      per_node [int];
    stats_t      per_tag  [int];
    // Histogram: hist[tag][bin] = count
    int unsigned hist     [int][int];

    function void print (string m); $display("[%s] %s", this.label, m); endfunction


    function new(
        string       label             = "slink_perf",
        int unsigned latency_bin_cyc   = 4,
        int unsigned latency_num_bins  = 256
    );
        this.label            = label;
        this.t_start          = 0;
        this.t_end            = 0;
        this.latency_bin_cyc  = (latency_bin_cyc  > 0) ? latency_bin_cyc  : 1;
        this.latency_num_bins = (latency_num_bins > 0) ? latency_num_bins : 1;
    endfunction


    function void mark_start();
        this.t_start = $realtime;
    endfunction

    function void mark_end();
        this.t_end = $realtime;
    endfunction

    // Clear all collected stats and timing; keeps label and histogram config.
    function void reset();
        this.t_start = 0;
        this.t_end   = 0;
        this.per_node.delete();
        this.per_tag.delete();
        this.hist.delete();
    endfunction

    function void change_label(string label);
        this.label = label;
    endfunction


    protected function void ensure_node(int nid);
        if (this.per_node.exists(nid)) return;
        this.per_node[nid] = '{
            n_issued        : 0,
            n_completed     : 0,
            n_errors        : 0,
            latency_cyc_sum : 0,
            latency_cyc_min : 64'hFFFF_FFFF_FFFF_FFFF,
            latency_cyc_max : 0,
            latency_cyc_sum_from_granted : 0,
            latency_cyc_min_from_granted : 64'hFFFF_FFFF_FFFF_FFFF,
            latency_cyc_max_from_granted : 0,
            payload_bytes   : 0,
            effective_bytes : 0
        };
    endfunction

    protected function void ensure_tag(int tag);
        if (this.per_tag.exists(tag)) return;
        this.per_tag[tag] = '{
            n_issued        : 0,
            n_completed     : 0,
            n_errors        : 0,
            latency_cyc_sum : 0,
            latency_cyc_min : 64'hFFFF_FFFF_FFFF_FFFF,
            latency_cyc_max : 0,
            latency_cyc_sum_from_granted : 0,
            latency_cyc_min_from_granted : 64'hFFFF_FFFF_FFFF_FFFF,
            latency_cyc_max_from_granted : 0,
            payload_bytes   : 0,
            effective_bytes : 0
        };
    endfunction


    function void on_a_issued(int nid, int tag, int payload_bytes, int effective_bytes);
        ensure_node(nid);
        ensure_tag(tag);
        this.per_node[nid].n_issued      += 1;
        this.per_node[nid].payload_bytes += payload_bytes;
        this.per_node[nid].effective_bytes += effective_bytes;
        this.per_tag [tag].n_issued      += 1;
        this.per_tag [tag].payload_bytes += payload_bytes;
        this.per_tag [tag].effective_bytes += effective_bytes;
    endfunction


    function void on_r_received(
        int               nid,
        int               tag,
        longint unsigned  latency_cyc,
        longint unsigned  latency_cyc_from_granted,
        logic             err,
        int               effective_bytes
    );
        int unsigned bin;
        ensure_node(nid);
        ensure_tag(tag);

        this.per_node[nid].n_completed     += 1;
        this.per_node[nid].latency_cyc_sum += latency_cyc;
        this.per_node[nid].latency_cyc_sum_from_granted += latency_cyc_from_granted;
        this.per_node[nid].effective_bytes += effective_bytes;
        if (latency_cyc < this.per_node[nid].latency_cyc_min) this.per_node[nid].latency_cyc_min = latency_cyc;
        if (latency_cyc > this.per_node[nid].latency_cyc_max) this.per_node[nid].latency_cyc_max = latency_cyc;
        if (latency_cyc_from_granted < this.per_node[nid].latency_cyc_min_from_granted) this.per_node[nid].latency_cyc_min_from_granted = latency_cyc_from_granted;
        if (latency_cyc_from_granted > this.per_node[nid].latency_cyc_max_from_granted) this.per_node[nid].latency_cyc_max_from_granted = latency_cyc_from_granted;
        if (err) this.per_node[nid].n_errors += 1;

        this.per_tag[tag].n_completed     += 1;
        this.per_tag[tag].latency_cyc_sum += latency_cyc;
        this.per_tag[tag].latency_cyc_sum_from_granted += latency_cyc_from_granted;
        this.per_tag[tag].effective_bytes += effective_bytes;
        if (latency_cyc < this.per_tag[tag].latency_cyc_min) this.per_tag[tag].latency_cyc_min = latency_cyc;
        if (latency_cyc > this.per_tag[tag].latency_cyc_max) this.per_tag[tag].latency_cyc_max = latency_cyc;
        if (latency_cyc_from_granted < this.per_tag[tag].latency_cyc_min_from_granted) this.per_tag[tag].latency_cyc_min_from_granted = latency_cyc_from_granted;
        if (latency_cyc_from_granted > this.per_tag[tag].latency_cyc_max_from_granted) this.per_tag[tag].latency_cyc_max_from_granted = latency_cyc_from_granted;
        if (err) this.per_tag[tag].n_errors += 1;

        bin = int'(latency_cyc / this.latency_bin_cyc);
        if (bin >= this.latency_num_bins) bin = this.latency_num_bins - 1;
        if (!this.hist.exists(tag)) this.hist[tag][bin] = 1;
        else begin
            if (!this.hist[tag].exists(bin))
                this.hist[tag][bin] = 0;
            this.hist[tag][bin] += 1;
        end
    endfunction


    // Convenience accessors (handy for assertions/checks in TBs)
    function longint unsigned total_completed();
        longint unsigned t = 0;
        foreach (this.per_node[nid]) t += this.per_node[nid].n_completed;
        return t;
    endfunction

    function real throughput_bps(stats_t s = '{default: '0});
        longint unsigned total_bytes = 0;
        realtime         dt;
        if (s == '{default: '0})
            foreach (this.per_node[nid]) total_bytes += this.per_node[nid].effective_bytes;
        else
            total_bytes = s.effective_bytes;
        dt = (this.t_end > this.t_start) ? (this.t_end - this.t_start) : 0;
        if (dt <= 0) return 0.0;
        return (real'(total_bytes) * 8.0) / (real'(dt) * 1e-9 * NumNodes);
    endfunction

    function real goodput_bps(stats_t s = '{default: '0});
        longint unsigned total_bytes = 0;
        realtime         dt;
        if (s == '{default: '0})
            foreach (this.per_node[nid]) total_bytes += this.per_node[nid].payload_bytes;
        else
            total_bytes = s.payload_bytes;
        dt = (this.t_end > this.t_start) ? (this.t_end - this.t_start) : 0;
        if (dt <= 0) return 0.0;
        return (real'(total_bytes) * 8.0) / (real'(dt) * 1e-9);
    endfunction

    function real average_latency(stats_t s, bit from_granted);
        if (from_granted) 
            return (s.n_completed > 0) ? real'(s.latency_cyc_sum_from_granted) / real'(s.n_completed) : 0.0;
        else
            return (s.n_completed > 0) ? real'(s.latency_cyc_sum) / real'(s.n_completed) : 0.0;
    endfunction


    function void report();
        realtime dt;
        real     avg;
        real     avg_from_granted;
        dt = (this.t_end > this.t_start) ? (this.t_end - this.t_start) : 0;
        $display("================ Perf Report: %s ================", this.label);
        print($sformatf("Wall time: %0g -> %0g (delta = %0g)", this.t_start, this.t_end, dt));
        print("--------------- NODE STATS ---------------");
        foreach (this.per_node[nid]) begin
            stats_t s = this.per_node[nid];
            print($sformatf("Node %2d:", nid));
            // print($sformatf("    Throughput:     %0.3f Mbps", this.throughput_bps(s)/1e6));
            print($sformatf("    Goodput:        %0.3f Mbps", this.goodput_bps(s)/1e6));
            print($sformatf("    Latency:        %0.2f cyc (min=%0d, max=%0d)", this.average_latency(s, 0), s.latency_cyc_min, s.latency_cyc_max));
            print($sformatf("    Lat. since gnt: %0.2f cyc (min=%0d, max=%0d)", this.average_latency(s, 1), s.latency_cyc_min_from_granted, s.latency_cyc_max_from_granted));
        end
        print("----------------- TAG STATS---------------");
        foreach (this.per_tag[tag]) begin
            stats_t s = this.per_tag[tag];
            print($sformatf("Tag %2d:", tag));
            print($sformatf("    Throughput:     %0.3f Mbps", this.throughput_bps(s)/1e6));
            print($sformatf("    Goodput:        %0.3f Mbps", this.goodput_bps(s)/1e6));
            print($sformatf("    Latency:        %0.2f cyc (min=%0d, max=%0d)", this.average_latency(s, 0), s.latency_cyc_min, s.latency_cyc_max));
            print($sformatf("    Lat. since gnt: %0.2f cyc (min=%0d, max=%0d)", this.average_latency(s, 1), s.latency_cyc_min_from_granted, s.latency_cyc_max_from_granted));
        end
        print("----------------- TAG HISTOGRAMS ---------------");
        foreach (this.hist[tag]) begin
            int unsigned tag_bins[int];
            print($sformatf("Tag %2d:", tag));
            tag_bins = this.hist[tag];
            foreach (tag_bins[bin]) begin
                int unsigned bin_start = bin * this.latency_bin_cyc;
                int unsigned bin_end   = (bin+1) * this.latency_bin_cyc;
                print($sformatf("    [%0d, %0d): %0d", bin_start, bin_end, tag_bins[bin]));
            end
        end
        print("----------------- OVERALL STATS ---------------");
        print($sformatf("Ring Throughput: %0.2f Mbps", this.throughput_bps()/1e6));
        print($sformatf("Ring Goodput:    %0.2f Mbps", this.goodput_bps()/1e6));

        $display("================ End Perf Report =================");
    endfunction

endclass

`endif // SLINK_PERF_MONITOR_SVH
