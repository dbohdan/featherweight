# Shared harness for the scripts in tests/. Each test sources this file, calls
# test::start, makes assertions with ok and fails, and ends with test::finish.
# Every test gets a working directory of its own under tests/.tmp/, so the
# project's stored sessions are never touched.
package require fileutil

namespace eval ::test {
    variable passed 0
    variable failed 0
    variable work {}
    variable harness {}
}

# Create a clean working directory, cd into it, and load Featherweight into
# this interpreter. info script names the test that is calling this, so each
# test keeps its own state and its own debug log.
proc ::test::start {{path {}}} {
    variable passed
    variable failed
    variable work
    variable harness

    set here [file dirname [file normalize [info script]]]
    if {$path eq {}} {
        set path [file normalize [file join $here .. featherweight.tcl]]
    }
    set harness $path

    set work [file join $here .tmp [file rootname [file tail [info script]]]]
    file delete -force $work
    file mkdir $work
    cd $work

    set passed 0
    set failed 0

    source $harness
}

# Report and set the exit status. Every test ends this way.
proc ::test::finish {} {
    variable passed
    variable failed

    if {$failed} {
        ::puts stdout "$failed FAILED, $passed passed"
        exit 1
    }
    ::puts stdout "all $passed checks passed"
    exit 0
}

# Read one option of one text tag: what it is set to, not what it defaults
# to. Tk answers with the option's whole record; the value is the last word
# of it.
proc tag_value {chat tag option} {
    set record [$chat tag configure $tag $option]
    if {[llength $record] == 5 && [lindex $record 0] eq $option} {
        return [lindex $record 4]
    }
    return $record
}

# Read a file as UTF-8.
proc slurp {path} {
    return [::fileutil::cat -encoding utf-8 $path]
}

# Run a script and expect it to succeed. The script is evaluated in the
# caller's scope, so it can use the test's own variables, and must return a
# boolean.
proc ok {label script} {
    set code [catch {uplevel 1 $script} result]
    if {$code} {
        incr ::test::failed
        ::puts stdout "FAIL $label: error: $result"
        return
    }
    if {$result} {
        incr ::test::passed
        ::puts stdout "pass  $label"
    } else {
        incr ::test::failed
        ::puts stdout "FAIL $label: returned false"
    }
}

# Run a script and expect it to raise an error.
proc fails {label script} {
    set code [catch {uplevel 1 $script} result]
    if {$code} {
        incr ::test::passed
        ::puts stdout "pass  $label (refused: $result)"
    } else {
        incr ::test::failed
        ::puts stdout "FAIL $label: expected an error, got: $result"
    }
}

# Run the command line the way a user would, from the test's directory, and
# return the exit code and the combined output as a dict.
proc run_cli {argv} {
    set tclsh [auto_execok tclsh]
    if {$tclsh eq {}} {
        error {tclsh is not on PATH}
    }

    set pipe [open |[list {*}$tclsh $::test::harness {*}$argv 2>@1]]
    fconfigure $pipe -encoding utf-8
    set output [read $pipe]
    set code 0
    if {[catch {close $pipe} error detail]} {
        set errorcode [dict get $detail -errorcode]
        if {[lindex $errorcode 0] eq {CHILDSTATUS}} {
            set code [lindex $errorcode 2]
        } else {
            set code 1
            append output "$errorcode: $error"
        }
    }
    return [dict create code $code output $output]
}
