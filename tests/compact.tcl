#! /usr/bin/env tclsh
# Tests for /compact and for the automatic context fold it shares its logic
# with, including what the two report when they do not run.

source [file join [file dirname [info script]] lib.tcl]
test::start

set log_path [file join $::test::work featherweight-debug.log]

# A session whose assistant messages are long and whose user messages are
# short: the fold's note quotes user text verbatim, so this is the shape where
# the fold has room to reach its target.
proc build_session {name turns} {
    ::featherweight::switch_session $name
    for {set i 0} {$i < $turns} {incr i} {
        ::featherweight::append_message [dict create \
            role user \
            content "turn $i"]
        ::featherweight::append_message [dict create \
            role assistant \
            content [string repeat {text } 400]]
    }
}

::featherweight::init_config
dict set ::featherweight::config debug true

puts "== automatic fold =="
dict set ::featherweight::config context_size 4096
build_session auto 12
set auto_before [::featherweight::messages_tokens [::featherweight::current_messages]]
ok "the automatic fold runs when the history is over budget" {
    expr {$auto_before > [::featherweight::history_budget]
        && [::featherweight::compact_context] == 1}
}
set auto_folded [::featherweight::current_messages]
set auto_after [::featherweight::messages_tokens $auto_folded]
ok "it reaches its target of half the budget" {
    expr {$auto_after <= [::featherweight::history_budget] / 2
        && $auto_after < $auto_before}
}
ok "it keeps the system prompt and marks the fold" {
    set note [lindex $auto_folded 1]
    expr {[dict get [lindex $auto_folded 0] role] eq {system}
        && [dict get $note role] eq {user}
        && [string first {[featherweight]} [dict get $note content]] == 0
        && [string first {turn 0} [dict get $note content]] >= 0}
}
ok "the automatic fold is on disk" {
    set ::featherweight::sessions [dict create]
    set on_disk [::featherweight::current_messages]
    expr {[llength $on_disk] == [llength $auto_folded]
        && [::featherweight::messages_tokens $on_disk] == $auto_after}
}
ok "the automatic fold logs itself" {
    expr {[string first {compacted history: dropped} [slurp $log_path]] >= 0}
}
ok "the debug log uses the configured timestamp format" {
    regexp {\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [+-]\d{4} \(tool\)} [slurp $log_path]
}
ok "a second automatic pass has nothing left to do" {
    expr {[::featherweight::compact_context] == 0
        && [::featherweight::messages_tokens [::featherweight::current_messages]]
            == $auto_after}
}
ok "fold_plan agrees with what compact_context did" {
    set plan [::featherweight::fold_plan]
    expr {[dict get $plan fold] == 0
        && [dict get $plan why] in {fits off no-turn no-gain}}
}

puts "== /compact =="
dict set ::featherweight::config context_size 1000000
build_session small 4
set small_count [llength [::featherweight::current_messages]]
set small_tokens [::featherweight::messages_tokens [::featherweight::current_messages]]

ok "the automatic fold stays off while the history fits the budget" {
    expr {[::featherweight::compact_context] == 0
        && [llength [::featherweight::current_messages]] == $small_count}
}
ok "/compact refuses arguments and folds nothing" {
    expr {[::featherweight::handle_slash_command {/compact now}] == 1
        && [llength [::featherweight::current_messages]] == $small_count}
}
ok "/compact folds the history the automatic fold left alone" {
    expr {[::featherweight::handle_slash_command {/compact}] == 1}
}
set folded [::featherweight::current_messages]
set folded_tokens [::featherweight::messages_tokens $folded]
ok "the forced fold halves the history" {
    expr {[llength $folded] < $small_count
        && $folded_tokens <= $small_tokens / 2}
}
ok "it keeps the system prompt and quotes the dropped user text" {
    set note [lindex $folded 1]
    expr {[dict get [lindex $folded 0] role] eq {system}
        && [dict get $note role] eq {user}
        && [string first {[featherweight]} [dict get $note content]] == 0
        && [string first {turn 0} [dict get $note content]] >= 0}
}
ok "the forced fold is on disk" {
    set ::featherweight::sessions [dict create]
    set on_disk [::featherweight::current_messages]
    expr {[llength $on_disk] == [llength $folded]
        && [::featherweight::messages_tokens $on_disk] == $folded_tokens}
}
ok "the forced fold reports itself in the debug log" {
    expr {[string first {folded on request: dropped} [slurp $log_path]] >= 0}
}
ok "fold_plan describes the forced fold that was applied" {
    set plan [::featherweight::fold_plan 1]
    expr {[dict get $plan fold] == 0
        || [dict get $plan before] >= [dict get $plan after]}
}

puts "== /compact with nothing to give up =="
::featherweight::switch_session tiny
::featherweight::append_message [dict create role user content {only these words}]
::featherweight::append_message [dict create role assistant content {and this reply}]
set tiny_count [llength [::featherweight::current_messages]]
ok "/compact leaves a session it cannot halved alone" {
    expr {[::featherweight::handle_slash_command {/compact}] == 1
        && [llength [::featherweight::current_messages]] == $tiny_count}
}
ok "it says why nothing was folded" {
    expr {[string first {context not folded} [slurp $log_path]] >= 0
        && [string first {at least as many as} [slurp $log_path]] >= 0}
}
ok "fold_plan says the same thing" {
    set plan [::featherweight::fold_plan 1]
    expr {[dict get $plan fold] == 0
        && [dict get $plan why] eq {no-gain}
        && [string first {at least as many as} [::featherweight::fold_decline $plan]] >= 0}
}

puts "== /compact with context_size off =="
dict set ::featherweight::config context_size 0
build_session medium 20
set medium_tokens [::featherweight::messages_tokens [::featherweight::current_messages]]
ok "context_size off disables the automatic fold" {
    expr {[::featherweight::history_budget] == 0
        && [::featherweight::compact_context] == 0
        && [::featherweight::messages_tokens [::featherweight::current_messages]]
            == $medium_tokens}
}
ok "fold_plan reports why" {
    expr {[dict get [::featherweight::fold_plan] why] eq {off}
        && [string first {context_size} [::featherweight::fold_decline [::featherweight::fold_plan]]] >= 0}
}
ok "/compact still folds when context_size is off" {
    expr {[::featherweight::handle_slash_command {/compact}] == 1
        && [::featherweight::messages_tokens [::featherweight::current_messages]]
            <= $medium_tokens / 2}
}

test::finish
