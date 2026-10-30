read_liberty $::env(TIMING_LIB)
read_verilog $::env(TIMING_NETLIST)
link_design chip_top
read_sdc $::env(TIMING_SDC)
set r $::env(TIMING_REPORTS)
# second pass: full paths to the chosen endpoint pins only
if {[info exists ::env(TIMING_PINS)]} {
  set pins [get_pins [split [string trim [read [open $::env(TIMING_PINS)]]] "\n"]]
  report_checks -from [all_registers -clock_pins] -to $pins -path_delay max -group_count [llength $pins] -endpoint_count 1 -fields {fanout slew net} -digits 4 > $r/r2r_top.rpt
  puts "DONE"
  exit
}
report_checks -path_delay max -digits 4 > $r/worst_path.rpt
report_checks -from [all_inputs] -path_delay max -format end -digits 4 > $r/input_worst.rpt
report_checks -path_delay min -format end -digits 4 > $r/hold_worst.rpt
report_checks -from [all_registers -clock_pins] -to [all_registers -data_pins] -path_delay max -group_count 40000 -endpoint_count 1 -format end -digits 4 > $r/r2r_endpoints.rpt
report_check_types -all_violators -max_transition -digits 4 > $r/slew.rpt
puts "DONE"
