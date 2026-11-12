#! /usr/bin/env tclsh
# Tests for recall: the session record searched as memory, the way Strument's
# recall does it -- grep-shaped, ids that open a message whole, matches in
# the conversation counted rather than shown, and recall's own results left
# out.

source [file join [file dirname [info script]] lib.tcl]
test::start
::featherweight::init_config

proc recall {arguments} {
    return [::featherweight::tool_recall $arguments]
}

puts "== a fixture that gets folded =="
dict set ::featherweight::config context_size 4096
set messages [list [dict create role system content {system prompt}]]
for {set turn 0} {$turn < 2} {incr turn} {
    lappend messages [dict create role user \
        content "question $turn about zirconium [string repeat {filler } 150]"]
    lappend messages [dict create role assistant \
        content "answer $turn found tungsten [string repeat {filler } 150]"]
}
# A tool call and its result, early enough that the fold drops them, and a
# recall call and its result at the end. The recall result must not be
# searchable; its word is here to prove it.
lappend messages [dict create role assistant content {} tool_calls [list \
    [dict create type function id call_1 \
        function [dict create name run_code arguments {{\"code\":\"puts hi\"}}]]]]
lappend messages [dict create role tool tool_call_id call_1 \
    content {carbide output line}]
for {set turn 2} {$turn < 6} {incr turn} {
    lappend messages [dict create role user \
        content "question $turn about zirconium [string repeat {filler } 150]"]
    lappend messages [dict create role assistant \
        content "answer $turn found tungsten [string repeat {filler } 150]"]
}
lappend messages [dict create role assistant content {} tool_calls [list \
    [dict create type function id call_2 \
        function [dict create name recall arguments {{\"pattern\":\"zirconium\"}}]]]]
lappend messages [dict create role tool tool_call_id call_2 \
    content {zephyrous answer found in the record}]

::featherweight::set_current_messages $messages
ok "the fold happens" {
    expr {[::featherweight::compact_context] == 1}
}

puts "== the record is searched across the fold =="
set out [recall [dict create pattern zirconium]]
ok "a folded-away message is found outside the conversation" {
    expr {[string first {outside this conversation} $out] >= 0}
}
set hit_id {}
regexp {t[0-9]+\.[0-9]+} $out hit_id
ok "hits carry an id" {
    expr {$hit_id ne {}}
}
ok "matches in the conversation are counted, not shown" {
    expr {[string first {more in messages still in this conversation} $out] >= 0}
}

puts "== an id opens a message whole =="
set out [recall [dict create id $hit_id]]
ok "the message opens with its text" {
    expr {[string first {about zirconium} $out] >= 0
        && [string first "$hit_id \u00b7 turn " $out] == 0}
}
ok "an unknown id says so" {
    expr {[string first {No message has the id} [recall [dict create id t99.99]]] == 0}
}

puts "== tool output is searched apart =="
set out [recall [dict create pattern carbide from conversation]]
ok "the conversation scope leaves tool output out, and says so" {
    expr {[string first {more in tool output: pass from="all"} $out] >= 0}
}
set out [recall [dict create pattern carbide from tools]]
ok "the tools scope finds the tool result" {
    expr {[string first {carbide output line} $out] >= 0
        && [string first {tool run_code} $out] >= 0}
}

puts "== recall's own results are left out =="
ok "a search cannot find a previous answer of its own" {
    expr {[string first {No matches outside this conversation} \
        [recall [dict create pattern zephyrous]]] >= 0}
}

puts "== the query is raw FTS5 =="
ok "an invalid query is searched for as a phrase, and says so" {
    expr {[string first {searched for as a phrase} \
        [recall [dict create pattern {"}]]] >= 0}
}
ok "a phrase matches" {
    expr {[string first {outside this conversation} \
        [recall [dict create pattern {"question 3 about zirconium"}]]] >= 0}
}
ok "a message id as the pattern opens the message" {
    expr {[string first {is a message id, not text in the record} \
        [recall [dict create pattern t2.1]]] >= 0
        && [string first {about zirconium} \
            [recall [dict create pattern t2.1]]] >= 0}
}
ok "a search needs a pattern or an id" {
    expr {[string first {Give a "pattern" to search for} \
        [recall [dict create]]] == 0}
}

puts "== another session can be named =="
::featherweight::switch_session other
::featherweight::append_message [dict create role user content {something about xenolith}]
set out [recall [dict create pattern xenolith session other]]
ok "the named session is searched" {
    expr {[string first {xenolith} $out] >= 0}
}
ok "and the current session is not" {
    expr {[string first {No matches outside this conversation} \
        [recall [dict create pattern zirconium]]] >= 0}
}

test::finish
