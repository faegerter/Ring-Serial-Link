# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

onerror {resume}
quietly WaveActivateNextPane {} 0

# ---------------------------------------------------------------------------
#  Find all slink instances — these paths are proven to work.
#  Typical element: /tb_obi_slink/gen_nodes[3]/i_slink
# ---------------------------------------------------------------------------
set slink_instances [find instances -bydu slink -recursive]
set num_nodes       [llength $slink_instances]
if {$num_nodes == 0} {
    puts "wave.tcl: ERROR — no 'slink' instances found"
    return
}

# ---------------------------------------------------------------------------
#  Derive tb_name from the first slink path rather than a separate find call.
#  Split "/tb_obi_slink/gen_nodes[0]/i_slink" on "/" → {"" "tb_obi_slink" ...}
#  Index 1 is the testbench name.
# ---------------------------------------------------------------------------
set first_path [lindex $slink_instances 0]
set tb_name    [lindex [split $first_path "/"] 1]
puts "wave.tcl: testbench  = $tb_name"
puts "wave.tcl: num_nodes  = $num_nodes"

# ---------------------------------------------------------------------------
#  Count PHY channels per node.
# ---------------------------------------------------------------------------
set all_phy      [find instances -bydu serial_link_physical -recursive]
set total_phy    [llength $all_phy]
if {$total_phy == 0} {
    puts "wave.tcl: WARNING — no serial_link_physical instances found, defaulting to 1"
    set num_channels 1
} else {
    set num_channels [expr {$total_phy / $num_nodes}]
}
puts "wave.tcl: num_channels = $num_channels"

# ---------------------------------------------------------------------------
#  Helper: escape [ and ] in a path so Tcl does not treat them as command
#  substitutions when the variable is expanded inside an add wave call.
# ---------------------------------------------------------------------------
proc esc {path} {
    return [string map {[ \[ ] \]} $path]
}

# ---------------------------------------------------------------------------
#  Add waves for every ring node.
# ---------------------------------------------------------------------------
for {set i 0} {$i < $num_nodes} {incr i} {
    set group_name "Node $i"
    set base [esc [format {/%s/gen_nodes[%d]/i_slink} $tb_name $i]]

    # -- Top-level slink ports --
    add wave -noupdate -expand -group $group_name -ports $base/*

    # -- Network layer --
    add wave -noupdate -group $group_name -group {NETWORK} \
        $base/i_serial_link_protocol/*

    # -- Data-link layer --
    add wave -noupdate -group $group_name -group {LINK} \
        $base/i_serial_link_data_link/*

    # -- Channel allocator (only when NumChannels > 1) --
    if {$num_channels > 1} {
        add wave -noupdate -group $group_name -group {CHANNEL_ALLOCATOR} -ports \
            $base/gen_channel_alloc/i_channel_allocator/*
    }

    # -- PHY TX / RX per channel --
    for {set c 0} {$c < $num_channels} {incr c} {
        set phy_base [esc [format {%s/gen_phy_channels[%d]/i_serial_link_physical} $base $c]]
        add wave -noupdate -group $group_name -group PHY -group TX -group CH$c \
            $phy_base/i_serial_link_physical_tx/*
        add wave -noupdate -group $group_name -group PHY -group RX -group CH$c \
            $phy_base/i_serial_link_physical_rx/*
    }

    # -- Register map --
    add wave -noupdate -group $group_name -group {CONFIG} $base/reg2hw
    add wave -noupdate -group $group_name -group {CONFIG} $base/hw2reg
}

TreeUpdate [SetDefaultTree]
quietly wave cursor active 1
configure wave -namecolwidth 220
configure wave -valuecolwidth 110
configure wave -justifyvalue left
configure wave -signalnamewidth 1
configure wave -snapdistance 10
configure wave -datasetprefix 0
configure wave -rowmargin 4
configure wave -childrowmargin 2
configure wave -gridoffset 0
configure wave -gridperiod 1
configure wave -griddelta 40
configure wave -timeline 0
configure wave -timelineunits ns
update