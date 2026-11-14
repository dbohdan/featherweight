#! /usr/bin/env tclsh
# Tests for the code the run_code tool evaluates: commands run through exec
# with a timeout, and the thread that keeps the interface alive.

source [file join [file dirname [info script]] lib.tcl]
test::start
::featherweight::init_config
dict set ::featherweight::config debug false

# One tool call, and one field of the answer it gives back.
proc call {code} {
    return [::featherweight::tool_run_code [dict create code $code]]
}

proc field {payload name} {
    if {![regexp (?s)<$name>(.*?)</$name> $payload -> value]} {
        return {}
    }
    return $value
}

# Any process the tests left running, by what its command line looks like.
proc leftovers {pattern} {
    set pids {}
    catch {
        foreach line [split [::exec ps -eo pid=,args=] \n] {
            if {[string match $pattern $line]} {
                lappend pids [lindex [string trim $line] 0]
            }
        }
    }
    return $pids
}

puts "== commands through exec =="
ok "echo returns what it wrote" {
    expr {[field [call {exec echo hi}] result] eq {hi}}
}
ok "stdout and stderr are one result" {
    expr {[field [call {exec sh -c {echo out; echo err 1>&2}}] result] eq "out\nerr"}
}
ok "a failing command raises what it wrote" {
    expr {[field [call {exec sh -c {echo oops 1>&2; exit 3}}] result] eq {oops}}
}
ok "a failing command that wrote nothing raises exec's wording" {
    expr {[field [call {exec false}] result] eq {child process exited abnormally}}
}
ok "a command that reads input sees end of file, not a wait" {
    expr {[field [call {exec cat}] result] eq {}}
}
ok "words after -- are the command's own" {
    expr {[field [call {exec -- echo -timeout x}] result] eq {-timeout x}}
}
ok "a command word that looks like an option is a word" {
    expr {[field [call {exec echo -timeout x}] result] eq {-timeout x}}
}
ok "durations take a unit" {
    expr {[field [call {list [duration 30] [duration 30s] [duration 1m] [duration 500ms]}] result] eq {30000 30000 60000 500}}
}

puts "== timeouts =="
set answer [call {exec -timeout 1 sleep 777}]
ok "a command that hangs is killed, and said so" {
    expr {[string match {*timed out after 1s*} [field $answer result]]
        && [string match {*was killed*} [field $answer result]]}
}
ok "and nothing of it is left running" {
    expr {[leftovers *sleep\ 777*] eq {}}
}

set answer [call {exec -timeout 1 sh -c {sleep 777 & sleep 777}}]
ok "the children of a hung command go with it" {
    expr {[string match {*processes it started*} [field $answer result]]
        && [leftovers *sleep\ 777*] eq {}}
}

puts "== the thread behind a call =="
ok "state does not survive the call" {
    expr {[field [call {set x 5}] result] eq {5}
        && [field [call {info exists x}] result] eq {0}}
}
ok "the harness is reachable from model code" {
    expr {[string match {*bridge-ok*} [field [call {harness {dict set ::featherweight::config model bridge-ok}}] result]]
        && [dict get $::featherweight::config model] eq {bridge-ok}}
}

puts "== code that never ends =="
dict set ::featherweight::config run_code_timeout 2
set ::ticks 0
after 500 {incr ::ticks}
set start [clock milliseconds]
set answer [call {while 1 {}}]
set elapsed [expr {[clock milliseconds] - $start}]
ok "a loop that never ends is stopped and said so" {
    expr {[string match {*timed out after 2s*} [field $answer result]]
        && $elapsed < 15000}
}
ok "and the harness kept running while it did" {
    expr {$::ticks >= 1}
}

ok "a call can ask for more time" {
    expr {[field [call {deadline 20; after 3000; set done 1}] result] eq {1}}
}

puts "== the harness's own thread =="
ok "evaluation here keeps its state, as /eval needs" {
    expr {[field [::run_code::execute {set y 7}] result] eq {7}
        && [field [::run_code::execute {set y}] result] eq {7}}
}

ok "the answer's sections are separated by blank lines" {
    set out [call {puts hi}]
    expr {[string first "</output>\n\n<result>" $out] >= 0
        && [string first "</result>\n\n<options>" $out] >= 0}
}

puts "== the state does not move with a model's cd =="
# Threads share one working directory, so a model's cd moves [pwd] for
# everything that follows -- and the state must not go with it.
set state [::featherweight::state_dir]
set here [pwd]
file mkdir move
::featherweight::tool_run_code [dict create code {cd move}]
ok "a model's cd is the working directory's to make" {
    expr {[file tail [pwd]] eq {move}}
}
ok "the state directory stays where the harness started" {
    expr {[::featherweight::state_dir] eq $state
        && [::featherweight::session_path default] eq [file join $state sessions default]
        && [::featherweight::config_path] eq [file join $state config]}
}
cd $here

test::finish
