#! /usr/bin/env tclsh
# What the conversation shows for a tool call: the tool's name, its
# parameters in the tool's order, padded so the values line up.

source [file join [file dirname [info script]] lib.tcl]
test::start
::featherweight::init_config

proc shown {call} {
    return [::featherweight::tool_arguments_text \
        [dict get [dict get $call function] name] \
        [dict get [dict get $call function] arguments]]
}

proc call {name json} {
    return [dict create type function id t1 \
        function [dict create name $name arguments $json]]
}

puts "== a call is shown with its parameters in the tool's own order =="
set out [shown [call read_file {{"limit": 60, "offset": "1130", "path": "/tmp/x"}}]]
ok "the tool's order, not the JSON's" {
    expr {[string first {path:} $out] < [string first {offset:} $out]
        && [string first {offset:} $out] < [string first {limit:} $out]}
}
ok "the values line up under the longest name" {
    expr {[regexp {(?n)^path:\s{3}/tmp/x$} $out]
        && [regexp {(?n)^offset:\s{1}1130$} $out]
        && [regexp {(?n)^limit:\s{2}60$} $out]}
}

puts "== a multiline value goes on its own line =="
set out [shown [call write_file {{"path": "/tmp/test.tcl", "content": "#! /usr/bin/env tclsh\n\nputs hi"}}]]
ok "the name is alone on its line and the value is not indented" {
    expr {[regexp {(?n)^content:$} $out]
        && [regexp {(?n)^#! /usr/bin/env tclsh$} $out]
        && ![regexp {(?n)^\s+#! /usr/bin/env tclsh$} $out]}
}

puts "== a one-line value keeps its place =="
set out [shown [call write_file {{"path": "/tmp/test.tcl"}}]]
ok "path is on the same line as its name" {
    expr {[regexp {(?n)^\s*path:\s+/tmp/test\.tcl$} $out]}
}

puts "== arguments that are not JSON are shown as they are =="
set out [shown [call mystery {not json at all}]]
ok "the raw text is passed through" {
    expr {$out eq {not json at all}}
}

puts "== the conversation's heading =="
package require Tk
::featherweight::build_ui
update
set chat [dict get $::featherweight::W chat]
::featherweight::ui_tool_code [call read_file {{"path": "/tmp/x"}}] {}
set text [$chat get 1.0 end]
ok "the call names the tool" {
    expr {[string first {Tool call: read_file} $text] >= 0}
}
::featherweight::ui_tool {the result} {}
set text [$chat get 1.0 end]
ok "the result is labelled as one" {
    expr {[string first {Tool result} $text] >= 0
        && [string first {Tool code} $text] < 0}
}

puts "== the gap between the label and the date =="
::featherweight::ui_label {You} 1700000000
set line [$chat get end-2l end-1l]
ok "three spaces, not one" {
    expr {[string first {You   20} $line] >= 0
        && [string first {You 20} $line] < 0}
}

puts "== run_code still shows its code =="
::featherweight::ui_tool_code [call run_code {{"code": "puts hi"}}] {}
set text [$chat get 1.0 end]
ok "the code, and the old label" {
    expr {[string first {Tool code} $text] >= 0
        && [string first {puts hi} $text] >= 0}
}

catch {destroy .}
test::finish
