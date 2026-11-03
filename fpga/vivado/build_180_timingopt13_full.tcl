# Standalone, isolated full flow. Invoke with run_timingopt13.ps1 so paths stay
# short and ASCII despite the archive's Chinese directory name.
set_param general.maxThreads 4
set workspace_root [lindex $argv 0]
set cache_bits [lindex $argv 1]
set build_tag [lindex $argv 2]
if {$workspace_root eq "" || ![string is integer -strict $cache_bits]} {
    error "Expected workspace_root cache_bits build_tag"
}
set overlay_name [lindex $argv 3]
if {$overlay_name eq ""} {set overlay_name timingopt13}
set overlay_dir [file join $workspace_root rtl_overlays $overlay_name]
set output_dir [file join $workspace_root vivado_runs $build_tag]
set report_dir [file join $output_dir reports]
set local_project_dir [file join $workspace_root vivado_projects $build_tag]
set snapshot [file join $local_project_dir rtl]
file mkdir $snapshot
file mkdir $report_dir
create_project -force $build_tag $local_project_dir -part xc7k325tffg900-2

set source_set [get_filesets sources_1]
set source_list [open [file join $workspace_root new tb_coremark100_dual.f] r]
set rtl_files {}
while {[gets $source_list relative_source] >= 0} {
    if {$relative_source eq ""} {continue}
    set name [file tail $relative_source]
    if {$name in {tb_coremark100_dual.sv Mem_IROM.sv Mem_RAM.sv}} {continue}
    set origin [file join $overlay_dir $name]
    if {![file exists $origin]} {set origin [file join $workspace_root $relative_source]}
    set target [file join $snapshot $name]
    file copy -force $origin $target
    lappend rtl_files $target
}
close $source_list
foreach name {top.sv uart.sv twin_controller.sv} {
    set target [file join $snapshot $name]
    file copy -force [file join $workspace_root new $name] $target
    lappend rtl_files $target
}
foreach name {dram_cache.v dual_issue_pairing.v dual_issue_forwarding.v dual_issue_lane.v} {
    set origin [file join $overlay_dir $name]
    if {![file exists $origin]} {set origin [file join $workspace_root imports new $name]}
    file copy -force $origin [file join $snapshot $name]
}
add_files -norecurse $rtl_files
set_property include_dirs [list $snapshot] $source_set
set_property verilog_define [list DCACHE_INDEX_BITS=$cache_bits] $source_set
set_property top top $source_set
set_property generic [list P_CPU_CONSOLE_ON_UART=1 P_CPU_CLK_HZ=180000000 P_CPU_UART_BAUD_RATE=115200] $source_set

set xdc [file join $local_project_dir digital_twin.xdc]
file copy -force [file join $overlay_dir digital_twin.xdc] $xdc
add_files -fileset constrs_1 -norecurse $xdc
foreach pair {{Mem_IROM Mem_IROM} {Mem_RAM Mem_RAM} {pll_1 pll}} {
    lassign $pair folder name
    # import_ip rewrites relocated-IP metadata and owns the generated outputs.
    # A plain filesystem copy retains the archive's old IP output directory.
    import_ip -files [file join $workspace_root ip $folder ${name}.xci]
}
foreach name {irom dram} ip_name {Mem_IROM Mem_RAM} {
    set coe [file join $local_project_dir ${name}.coe]
    file copy -force [file join $overlay_dir images ${name}.coe] $coe
    set_property CONFIG.Coe_File $coe [get_ips $ip_name]
}
set_property CONFIG.CLKOUT2_REQUESTED_OUT_FREQ 180 [get_ips pll]
generate_target all [get_ips]
export_ip_user_files -of_objects [get_ips] -no_script -sync -force
foreach ip [get_ips] {create_ip_run $ip}
update_compile_order -fileset sources_1
set synth_run [get_runs synth_1]
set impl_run [get_runs impl_1]
set_property strategy Flow_PerfOptimized_high $synth_run
if {[lsearch -exact [list_property $synth_run] STEPS.SYNTH_DESIGN.ARGS.GLOBAL_RETIMING] >= 0} {
    set_property STEPS.SYNTH_DESIGN.ARGS.GLOBAL_RETIMING on $synth_run
}
set_property strategy Performance_ExplorePostRoutePhysOpt $impl_run
set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true $impl_run
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED false $impl_run
set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE NoTimingRelaxation $impl_run
# Serialize OOC runs: Vivado 2023.2 previously crashed with concurrent IP jobs.
launch_runs $synth_run -jobs 1
wait_on_run $synth_run
set synth_status [get_property STATUS $synth_run]
if {![regexp -nocase {complete} $synth_status]} {error "Synthesis failed: $synth_status"}
launch_runs $impl_run -to_step route_design -jobs 1
wait_on_run $impl_run
set impl_status [get_property STATUS $impl_run]
if {![regexp -nocase {complete} $impl_status]} {error "Implementation failed: $impl_status"}
open_run $impl_run
report_timing_summary -delay_type min_max -max_paths 50 -file [file join $report_dir timing_summary_routed.rpt]
phys_opt_design -directive AggressiveExplore
route_design -directive NoTimingRelaxation -tns_cleanup
write_checkpoint -force [file join $output_dir top_postroute_physopt.dcp]
report_timing_summary -delay_type min_max -max_paths 80 -nworst 10 -file [file join $report_dir timing_summary.rpt]
report_timing -delay_type max -max_paths 50 -nworst 10 -path_type full_clock_expanded -file [file join $report_dir timing_setup_paths.rpt]
report_timing -delay_type min -max_paths 30 -nworst 5 -path_type full_clock_expanded -file [file join $report_dir timing_hold_paths.rpt]
report_route_status -file [file join $report_dir route_status.rpt]
report_drc -file [file join $report_dir drc.rpt]
report_utilization -file [file join $report_dir utilization.rpt]
check_timing -verbose -file [file join $report_dir check_timing.rpt]
set wns [get_property SLACK [lindex [get_timing_paths -delay_type max -max_paths 1] 0]]
set whs [get_property SLACK [lindex [get_timing_paths -delay_type min -max_paths 1] 0]]
set period [get_property PERIOD [get_clocks clk_out2_pll]]
set actual_mhz [format %.6f [expr {1000.0 / $period}]]
set timing_met [expr {$wns >= 0.0 && $whs >= 0.0}]
set bit_path [file join $output_dir ${build_tag}.bit]
if {$timing_met} {write_bitstream -force $bit_path}
set summary [open [file join $output_dir build_summary.txt] w]
foreach entry [list "flow=full_synth_opt_place_physopt_route_postroute_physopt_final_reroute" "overlay=$overlay_name" "cache_index_bits=$cache_bits" "requested_mhz=180" "actual_mhz=$actual_mhz" "period_ns=$period" "synth_status=$synth_status" "impl_route_status=$impl_status" "wns_ns=$wns" "whs_ns=$whs" "timing_met=$timing_met" "bitstream_emitted=$timing_met"] {
    puts $summary $entry
}
close $summary
puts "FPGA_180_RESULT: tag=$build_tag actual_mhz=$actual_mhz wns=$wns whs=$whs timing_met=$timing_met"
close_project
exit 0
