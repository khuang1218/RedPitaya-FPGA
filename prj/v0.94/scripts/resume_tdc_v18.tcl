# Resume a known V18 build stopped after routing. No source refresh or reset.
# Use only when impl_1 contains the V18 route you want to finish.
set ::v18_resume_routed 1
set v18_resume_code [catch {
  source [file join [file dirname [file normalize [info script]]] build_tdc_v18.tcl]
} v18_resume_result v18_resume_options]
unset ::v18_resume_routed
if {$v18_resume_code} {
  return -options $v18_resume_options $v18_resume_result
}
