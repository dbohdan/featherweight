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
ok "the values line up under the longest name, two spaces at least" {
    expr {[regexp {(?n)^path:    /tmp/x$} $out]
        && [regexp {(?n)^offset:  1130$} $out]
        && [regexp {(?n)^limit:   60$} $out]}
}
ok "a blank line separates the arguments" {
    expr {[string first "/tmp/x\n\noffset:" $out] >= 0
        && [string first "1130\n\nlimit:" $out] >= 0}
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
    expr {[string first {Result} $text] >= 0
        && [string first {Tool result} $text] < 0}
}

puts "== the date is on its own line above the heading =="
::featherweight::ui_label {You} 1700000000
set text [$chat get 1.0 end]
set stamp [::featherweight::format_time 1700000000]
ok "the date leads, on its own line" {
    expr {[string first "$stamp\nYou\n" $text] >= 0
        && ![string match "*You   $stamp*" $text]}
}

puts "== the model's reasoning is shown folded =="
::featherweight::ui_thinking {first I think about it} 1700000000
set body "body$::featherweight::thinking_serial"
set text [$chat get 1.0 end]
ok "the date leads, then a folded Thinking heading" {
    expr {[string first "$stamp\nThinking \[+\]\n" $text] >= 0
        && [string first {first I think about it} $text] >= 0
        && [tag_value $chat $body -elide]}
}
::featherweight::ui_thinking_toggle $::featherweight::thinking_serial
ok "the toggle opens it" {
    expr {![tag_value $chat $body -elide]
        && [string first "Thinking \[\u2212\]" [$chat get 1.0 end]] >= 0}
}
::featherweight::ui_thinking_toggle $::featherweight::thinking_serial
ok "and closes it again" {
    expr {[tag_value $chat $body -elide]
        && [string first {Thinking [+]} [$chat get 1.0 end]] >= 0}
}
ok "the marker is fixed width, so the bracket does not move" {
    expr {[tag_value $chat "think$::featherweight::thinking_serial" -font] eq {TkFixedFont}}
}

puts "== run_code still shows its code =="
::featherweight::ui_tool_code [call run_code {{"code": "puts hi"}}] {}
set text [$chat get 1.0 end]
ok "the code, and the old label" {
    expr {[string first {Tool call: run_code} $text] >= 0
        && [string first {puts hi} $text] >= 0}
}

catch {destroy .}
test::finish
