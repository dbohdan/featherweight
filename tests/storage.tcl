#! /usr/bin/env tclsh
# Tests for the split state: featherweight/config for the configuration and
# one file per session under featherweight/sessions/.

source [file join [file dirname [info script]] lib.tcl]
test::start

set config_path [::featherweight::config_path]
set sessions_dir [::featherweight::sessions_dir]

puts "== fresh start =="
::featherweight::init_config
ok "config file created" {expr {[file exists $config_path]}}
ok "sessions directory created" {expr {[file isdirectory $sessions_dir]}}
ok "default session file created" {expr {[file exists [file join $sessions_dir default]]}}
ok "config parses as a dict with no sessions key" {
    expr {![catch {dict size [slurp $config_path]} size]
        && $size > 0
        && ![dict exists [slurp $config_path] sessions]}
}
ok "default session holds the system message" {
    set messages [::featherweight::load_session default]
    expr {[llength $messages] == 1
        && [dict get [lindex $messages 0] role] eq {system}}
}
ok "only the current session was read into memory" {
    expr {[dict keys $::featherweight::sessions] eq {default}}
}
ok "the configuration carries the timestamp format" {
    set saved [slurp $config_path]
    expr {[dict get $saved timestamp_format] eq {%Y-%m-%d %H:%M:%S %z}}
}
ok "the format is the one used for display" {
    expr {[::featherweight::format_time 1794401724]
        eq [clock format 1794401724 -format {%Y-%m-%d %H:%M:%S %z}]}
}

puts "== appending =="
set config_before [slurp $config_path]
::featherweight::append_message [dict create role user content {hello}]
ok "append rewrites the session file" {
    expr {[llength [::featherweight::load_session default]] == 2}
}
ok "append leaves the config file byte-identical" {
    expr {[slurp $config_path] eq $config_before}
}
ok "messages survive a fresh read from disk" {
    set ::featherweight::sessions [dict create]
    set messages [::featherweight::load_session default]
    expr {[llength $messages] == 2
        && [dict get [lindex $messages 1] content] eq {hello}}
}
ok "appended messages carry a Unix time" {
    set messages [::featherweight::load_session default]
    set time [dict get [lindex $messages 1] time]
    expr {[string is integer -strict $time]
        && $time > 1700000000
        && $time <= [clock seconds]}
}
ok "the time is ours and is not part of the message sent to the API" {
    set message [lindex [::featherweight::load_session default] 1]
    set json [::featherweight::json_message $message]
    expr {[string first {"time"} $json] < 0
        && [string first {"content"} $json] >= 0}
}

puts "== awkward contents round trip =="
set nasty "line one\nline two {braces} \[brackets\] \\backslash \"quotes\" \${dollar}\n\ttab and ünïcode ✓"
::featherweight::append_message [dict create \
    role assistant \
    content $nasty \
    tool_calls [list [dict create \
        type function \
        id {run_code:0} \
        function [dict create name run_code arguments {{\"code\":\"puts hi\"}}] \
    ]] \
]
ok "newlines, braces, quotes and unicode round trip" {
    set ::featherweight::sessions [dict create]
    set messages [::featherweight::load_session default]
    expr {[dict get [lindex $messages end] content] eq $nasty}
}
ok "tool calls round trip" {
    set messages [::featherweight::load_session default]
    set calls [dict get [lindex $messages end] tool_calls]
    expr {[llength $calls] == 1
        && [dict get [lindex $calls 0] id] eq {run_code:0}}
}

puts "== lazy loading =="
set handmade [file join $sessions_dir handmade]
::fileutil::writeFile -encoding utf-8 $handmade \
    "[list [dict create role system content {from disk}]]\n[list [dict create role user content {second}]]\n"
ok "an existing file is not read until it is needed" {
    expr {![dict exists $::featherweight::sessions handmade]}
}
::featherweight::switch_session handmade
ok "switching loads that session from disk" {
    set messages [::featherweight::current_messages]
    expr {[llength $messages] == 2
        && [dict get [lindex $messages 0] content] eq {from disk}
        && [dict get [lindex $messages 1] content] eq {second}}
}
ok "switching persists current_session to the config file" {
    expr {[dict get [slurp $config_path] current_session] eq {handmade}}
}
ok "messages written before timestamps have none" {
    set messages [::featherweight::load_session handmade]
    expr {[llength $messages] == 2
        && ![dict exists [lindex $messages 0] time]
        && [::featherweight::message_time [lindex $messages 0]] eq {}
        && [::featherweight::message_time [lindex $messages 1]] eq {}}
}

puts "== creating a session by switching =="
ok "a new name is not in memory yet" {
    expr {![dict exists $::featherweight::sessions fresh]}
}
::featherweight::switch_session fresh
ok "switching to a new name creates its file" {
    expr {[file exists [file join $sessions_dir fresh]]
        && [llength [::featherweight::load_session fresh]] == 1
        && [dict get [lindex [::featherweight::load_session fresh] 0] role] eq {system}}
}

puts "== session names =="
file mkdir [file join $sessions_dir subdir]
ok "session_names lists the files, sorted" {
    set names [::featherweight::session_names]
    expr {[lsort $names] eq $names
        && {default} in $names
        && {handmade} in $names
        && {fresh} in $names}
}
ok "session_names skips directories" {
    expr {{subdir} ni [::featherweight::session_names]}
}
file delete -force [file join $sessions_dir subdir]

puts "== invalid session names =="
foreach bad [list {} {.} {..} {a/b} {a\b} {sub/../../etc}] {
    fails "session_path refuses [list $bad]" [list ::featherweight::session_path $bad]
}
fails "switching to an empty name" {::featherweight::switch_session {}}
fails "switching to a path-shaped name" {::featherweight::switch_session {../escape}}
ok "the slash command reports it instead of crashing" {
    expr {[::featherweight::handle_slash_command {/session a/b}] == 1}
}
ok "no session file escaped the sessions directory" {
    expr {![file exists [file join $::test::work escape]]
        && ![file exists [file join [file dirname $sessions_dir] escape]]}
}

puts "== unreadable session files =="
set corrupt [file join $sessions_dir corrupt]
set corrupt_text "this is {not a list\n"
::fileutil::writeFile -encoding utf-8 $corrupt $corrupt_text
fails "a file that is not a list is an error" {::featherweight::load_session corrupt}
ok "the corrupt file is left untouched" {
    expr {[slurp $corrupt] eq $corrupt_text}
}
set oddfile [file join $sessions_dir oddfile]
::fileutil::writeFile -encoding utf-8 $oddfile {plain words}
fails "a file that is not message dicts is an error" {::featherweight::load_session oddfile}
ok "the odd file is left untouched" {
    expr {[slurp $oddfile] eq {plain words}}
}
file delete -force $corrupt $oddfile

puts "== configuration round trip =="
set ::featherweight::config [dict create \
    debug false \
    api_key_env_var TEST_KEY \
    endpoint http://localhost:1 \
    model test/model \
    context_size 8192 \
    timestamp_format {%d/%m/%Y} \
    system_prompt "multi\nline {prompt} with \"quotes\"" \
    current_session default \
]
::featherweight::save_config
ok "every configuration key round trips and sessions stay out" {
    set saved [slurp $config_path]
    expr {![catch {dict size $saved}]
        && [dict get $saved debug] eq {false}
        && [dict get $saved api_key_env_var] eq {TEST_KEY}
        && [dict get $saved endpoint] eq {http://localhost:1}
        && [dict get $saved model] eq {test/model}
        && [dict get $saved context_size] eq {8192}
        && [dict get $saved timestamp_format] eq {%d/%m/%Y}
        && [dict get $saved system_prompt] eq "multi\nline {prompt} with \"quotes\""
        && [dict get $saved current_session] eq {default}
        && ![dict exists $saved sessions]}
}

puts "== startup with a bad current_session =="
set saved [slurp $config_path]
dict set saved current_session {bad/name}
::fileutil::writeFile -encoding utf-8 $config_path $saved
set ::featherweight::sessions [dict create]
::featherweight::init_config
ok "it falls back to the default session" {
    expr {[dict get $::featherweight::config current_session] eq {default}
        && [dict get [slurp $config_path] current_session] eq {default}}
}

puts "== startup with an empty session file =="
set empty_session [file join $sessions_dir empty1]
::fileutil::writeFile -encoding utf-8 $empty_session {}
set saved [slurp $config_path]
dict set saved current_session empty1
::fileutil::writeFile -encoding utf-8 $config_path $saved
set ::featherweight::sessions [dict create]
::featherweight::init_config
ok "an empty current session is seeded with the system message" {
    set messages [::featherweight::current_messages]
    expr {[llength $messages] == 1
        && [dict get [lindex $messages 0] role] eq {system}
        && [file size $empty_session] > 0}
}
file delete -force $empty_session

puts "== the legacy featherweight.conf is ignored =="
set legacy [file join $::test::work featherweight.conf]
set legacy_text "debug true\ncurrent_session old\nsessions {\n    old {\n        {role user content stale}\n    }\n}\n"
::fileutil::writeFile -encoding utf-8 $legacy $legacy_text
set ::featherweight::sessions [dict create]
::featherweight::init_config
ok "the legacy file is not read, rewritten, or migrated" {
    expr {[slurp $legacy] eq $legacy_text
        && [dict get $::featherweight::config current_session] eq {default}
        && [dict get [slurp $config_path] current_session] eq {default}}
}
file delete -force $legacy

puts "== compaction writes to the session file =="
dict set ::featherweight::config context_size 4096
set messages [list [dict create role system content {system prompt}]]
for {set turn 0} {$turn < 6} {incr turn} {
    lappend messages [dict create role user content [string repeat "user $turn " 200]]
    lappend messages [dict create role assistant content [string repeat "reply $turn " 200]]
}
::featherweight::set_current_messages $messages
set before_count [llength $messages]
set before_tokens [::featherweight::messages_tokens $messages]
ok "compaction runs and folds the history" {
    expr {$before_tokens > [::featherweight::history_budget]
        && [::featherweight::compact_context] == 1}
}
set folded [::featherweight::current_messages]
set ::featherweight::sessions [dict create]
set reloaded [::featherweight::current_messages]
ok "the folded history is what is on disk" {
    expr {[llength $folded] < $before_count
        && [llength $folded] >= 3
        && [dict get [lindex $folded 0] role] eq {system}
        && [dict get [lindex $folded 1] role] eq {user}
        && [string first {[featherweight]} [dict get [lindex $folded 1] content]] == 0
        && [dict get [lindex $folded 2] role] eq {user}
        && [lrange $reloaded 0 end] eq [lrange $folded 0 end]}
}

puts "== a long conversation does not bloat the config =="
for {set i 0} {$i < 60} {incr i} {
    ::featherweight::append_message [dict create \
        role user \
        content [string repeat "abcdefghij" 200]]
}
ok "the config file stays small" {
    expr {[file size $config_path] < 10000}
}
ok "the session file holds every message" {
    set ::featherweight::sessions [dict create]
    set messages [::featherweight::current_messages]
    expr {[llength $messages] >= 60
        && [file size [file join $sessions_dir [::featherweight::current_session_name]]] > 100000}
}
ok "no legacy featherweight.conf was written" {
    expr {![file exists [file join $::test::work featherweight.conf]]}
}

puts "== retries and timeout =="
set saved [slurp $config_path]
dict set saved retries -1
::fileutil::writeFile -encoding utf-8 $config_path $saved
fails "a negative retry count is refused" {::featherweight::init_config}
set saved [slurp $config_path]
dict set saved retries 2
dict set saved timeout 0
::fileutil::writeFile -encoding utf-8 $config_path $saved
fails "a zero timeout is refused" {::featherweight::init_config}
set saved [slurp $config_path]
dict set saved retries 5
dict set saved timeout 300
::fileutil::writeFile -encoding utf-8 $config_path $saved
::featherweight::init_config
ok "the defaults are 5 retries and a 300 second timeout" {
    expr {[dict get $::featherweight::config retries] == 5
        && [dict get $::featherweight::config timeout] == 300}
}

puts "== every procedure compiles =="
set source [slurp $::test::harness]
ok "the source is complete Tcl" {expr {[info complete $source]}}
set uncompiled {}
foreach name [lsort [info procs ::featherweight::*]] {
    if {[catch {::tcl::unsupported::disassemble proc $name} error]} {
        lappend uncompiled "$name: $error"
    }
}
ok "all procedures compile" {expr {[llength $uncompiled] == 0}}
foreach error $uncompiled {
    ::puts stdout "  $error"
}

test::finish
