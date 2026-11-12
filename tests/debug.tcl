#! /usr/bin/env tclsh
# Tests for script mode: tclsh featherweight.tcl debug <subcommand>.

source [file join [file dirname [info script]] lib.tcl]
test::start

set fixture [file join [file dirname [file normalize [info script]]] fixtures replay.jsonl]

puts "== usage =="
set r [run_cli {--help}]
ok "--help exits 0 and lists the subcommands" {
    expr {[dict get $r code] == 0
        && [string first {debug fold} [dict get $r output]] >= 0
        && [string first {debug selftest} [dict get $r output]] >= 0}
}
set r [run_cli {debug}]
ok "debug with no subcommand exits 2 with usage" {
    expr {[dict get $r code] == 2
        && [string first {debug needs a subcommand} [dict get $r output]] >= 0
        && [string first {Usage:} [dict get $r output]] >= 0}
}
set r [run_cli {bogus}]
ok "an unknown option exits 2" {
    expr {[dict get $r code] == 2
        && [string first {unknown option: bogus} [dict get $r output]] >= 0}
}
set r [run_cli {debug nonsense}]
ok "an unknown subcommand exits 2" {
    expr {[dict get $r code] == 2
        && [string first {unknown subcommand: nonsense} [dict get $r output]] >= 0}
}
set r [run_cli {debug request --bogus}]
ok "an unknown option of a subcommand exits 2" {
    expr {[dict get $r code] == 2
        && [string first {unknown option: --bogus} [dict get $r output]] >= 0}
}

puts "== fold =="
set r [run_cli {debug fold}]
ok "fold reports the automatic plan without writing" {
    expr {[dict get $r code] == 0
        && [string first {automatic fold: would not run: the history already fits} [dict get $r output]] >= 0
        && [string first {nothing is written} [dict get $r output]] >= 0}
}
set r [run_cli {debug fold --force}]
ok "fold --force reports what /compact would do" {
    expr {[dict get $r code] == 0
        && [string first {forced fold (/compact): would not run: the session has no user turn} [dict get $r output]] >= 0}
}
set r [run_cli {debug fold --bogus}]
ok "fold refuses what it does not understand" {
    expr {[dict get $r code] == 2}
}

puts "== session =="
set r [run_cli {debug session list}]
ok "session list names the stored sessions" {
    expr {[dict get $r code] == 0
        && [string first {*} [dict get $r output]] >= 0
        && [string first {default} [dict get $r output]] >= 0}
}
set r [run_cli {debug session show default}]
ok "session show prints each message with its time" {
    expr {[dict get $r code] == 0
        && [string first {0 system} [dict get $r output]] >= 0
        && [regexp {\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [+-]\d{4}} [dict get $r output]]}
}
set r [run_cli {debug session show nosuch}]
ok "session show of a missing session exits 1" {
    expr {[dict get $r code] == 1
        && [string first {no such session} [dict get $r output]] >= 0}
}
set r [run_cli {debug session}]
ok "session needs a subcommand" {
    expr {[dict get $r code] == 2}
}
set r [run_cli {debug session check}]
ok "session check passes on healthy state" {
    expr {[dict get $r code] == 0
        && [string first {config: ok} [dict get $r output]] >= 0
        && [string first {session default: ok} [dict get $r output]] >= 0}
}

puts "== a broken session =="
file mkdir featherweight/sessions
set broken [file join featherweight sessions broken]
::fileutil::writeFile -encoding utf-8 $broken "not a list\n"
set r [run_cli {debug session check}]
ok "session check reports it and exits non-zero" {
    expr {[dict get $r code] == 1
        && [string first {session broken:} [dict get $r output]] >= 0
        && [string first {is not a record dict} [dict get $r output]] >= 0}
}
set r [run_cli {debug session list}]
ok "session list still works and marks it unreadable" {
    expr {[dict get $r code] == 0
        && [string first {unreadable} [dict get $r output]] >= 0}
}
file delete -force $broken

puts "== eval =="
set r [run_cli {debug eval expr 2+2}]
ok "eval prints the value it returned" {
    expr {[dict get $r code] == 0
        && [string trim [dict get $r output]] eq {4}}
}
set r [run_cli {debug eval {puts hello; expr 5}}]
ok "eval prints what the code printed, then its value" {
    expr {[dict get $r code] == 0
        && [string first {hello} [dict get $r output]] >= 0
        && [string first {5} [dict get $r output]] >= 0}
}
set r [run_cli {debug eval error boom}]
ok "a failing eval exits 1 and shows the error" {
    expr {[dict get $r code] == 1
        && [string first {boom} [dict get $r output]] >= 0}
}
set r [run_cli {debug eval}]
ok "eval needs code" {
    expr {[dict get $r code] == 2}
}

puts "== request =="
set r [run_cli {debug request}]
ok "request prints the model, counts and the payload" {
    expr {[dict get $r code] == 0
        && [string first {session:  default} [dict get $r output]] >= 0
        && [string first {model:} [dict get $r output]] >= 0
        && [string first {tools:    5 schemas} [dict get $r output]] >= 0
        && [string first {"messages"} [dict get $r output]] >= 0
        && [string first {automatic fold:} [dict get $r output]] >= 0}
}
set r [run_cli {debug request --last 1}]
ok "request --last lists messages instead of the payload" {
    expr {[dict get $r code] == 0
        && [string first {last 1 of 1 messages:} [dict get $r output]] >= 0
        && [string first {"messages"} [dict get $r output]] < 0}
}
set r [run_cli {debug request --session nosuch}]
ok "request on a missing session exits 1" {
    expr {[dict get $r code] == 1
        && [string first {no such session} [dict get $r output]] >= 0}
}
set r [run_cli {debug request --last 0}]
ok "request --last needs a positive number" {
    expr {[dict get $r code] == 2}
}

puts "== request --replay =="
set r [run_cli [list debug request --replay $fixture]]
ok "a recorded turn runs to the end" {
    expr {[dict get $r code] == 0
        && [string first {request 1:} [dict get $r output]] >= 0
        && [string first {tool call: about} [dict get $r output]] >= 0
        && [string first {result:} [dict get $r output]] >= 0
        && [string first {request 2:} [dict get $r output]] >= 0
        && [string first {turn over after 2 requests} [dict get $r output]] >= 0}
}
ok "the recorded turn ran against a copy: the stored session is untouched" {
    set ::featherweight::sessions [dict create]
    expr {[llength [::featherweight::load_session default]] == 1}
}
set empty [file join $::test::work empty.jsonl]
::fileutil::writeFile -encoding utf-8 $empty {}
set r [run_cli [list debug request --replay $empty]]
ok "an empty replay file is refused" {
    expr {[dict get $r code] == 1
        && [string first {holds no responses} [dict get $r output]] >= 0}
}

test::finish
