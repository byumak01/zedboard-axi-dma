#
# build-bitstream.tcl: build the bitstream and export the XSA for zedboard_axi_dma
#

set design_name zedboard_axi_dma
set project_file "[file normalize "./${design_name}/${design_name}.xpr"]"
set export_dir "[file normalize "./export"]"
set xsa_file "${export_dir}/${design_name}.xsa"

if {![file exists $project_file]} {
  puts "###############################"
  puts "### Missing Vivado project  ###"
  puts "###############################"
  puts "Run build.tcl first to create the project:"
  puts "  vivado -mode batch -source build.tcl"
  return 1
}

open_project $project_file
reset_run synth_1
reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 16
wait_on_run impl_1

set impl_status [get_property STATUS [get_runs impl_1]]
if {![string match "*write_bitstream Complete*" $impl_status]} {
  puts "###############################"
  puts "### Bitstream build failed  ###"
  puts "###############################"
  puts "impl_1 status: $impl_status"
  return 1
}

open_run impl_1
file mkdir $export_dir
write_hw_platform -fixed -include_bit -force -file $xsa_file
puts "INFO: Exported hardware platform to $xsa_file"

close_project
