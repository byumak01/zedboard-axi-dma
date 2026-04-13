#
# sim-nn-bridge.tcl: run the standalone AXI-stream NN bridge simulation
#

set version_required "2025.2"
set ver [version -short]
if {![string equal $ver $version_required]} {
  puts "###############################"
  puts "### Simulation version error ###"
  puts "###############################"
  puts "This simulation flow was written for Vivado $version_required."
  puts "You are using Vivado $ver."
  return 1
}

set origin_dir [file normalize [file dirname [info script]]]
set src_dir [file normalize "$origin_dir/src/new"]
set tb_file [file normalize "$origin_dir/../scripts/hd_dma_stream_bridge_tb.sv"]

create_project -in_memory hd_dma_stream_bridge_sim -part xc7z020clg484-1

add_files -fileset sim_1 -norecurse [list \
  "$src_dir/params.vh" \
  "$src_dir/simplified_neuron.v" \
  "$src_dir/calcium_update.v" \
  "$src_dir/weight_update.v" \
  "$src_dir/synapse.v" \
  "$src_dir/hd_neuron.v" \
  "$src_dir/hd_dma_stream_bridge.v" \
  "$tb_file" \
]

set_property file_type {Verilog Header} [get_files "$src_dir/params.vh"]
set_property include_dirs [list $src_dir] [get_filesets sim_1]
set_property top hd_dma_stream_bridge_tb [get_filesets sim_1]

launch_simulation -simset sim_1 -mode behavioral
run all
close_sim
close_project
