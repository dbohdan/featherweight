#! /usr/bin/env tclsh
# A session file is append-only: a compaction records a marker instead of
# rewriting the conversation, and everything cut away stays in the file above
# it, whole and recoverable. The file is Tcl: records are lists, and a
# record's text may span lines. One parser reads it and one writes it.

source [file join [file dirname [info script]] lib.tcl]
test::start
::featherweight::init_config

set path [::featherweight::session_path default]

# The one parser the app itself uses: the file is a Tcl list of records.
proc records {path} {
    return [::featherweight::session_records [slurp $path]]
}

# The last marker in a file, or {}.
proc last_marker {path} {
    set marker {}
    foreach record [records $path] {
        if {[::featherweight::is_marker $record]} { set marker $record }
    }
    return $marker
}

puts "== a fold appends a marker instead of rewriting =="
dict set ::featherweight::config context_size 4096
set messages [list [dict create role system content {system prompt}]]
for {set turn 0} {$turn < 6} {incr turn} {
    lappend messages [dict create role user content [string repeat "user $turn " 200]]
    lappend messages [dict create role assistant content [string repeat "reply $turn " 200]]
}
::featherweight::set_current_messages $messages
set before_count [llength $messages]
set before_records [records $path]

ok "the fold happens" {
    expr {[::featherweight::compact_context] == 1}
}
set folded [::featherweight::current_messages]
set after_records [records $path]

ok "the fold only adds records to the file" {
    expr {[llength $after_records] > [llength $before_records]
        && [lrange $after_records 0 [expr {[llength $before_records] - 1}]]
            eq $before_records}
}

set marker [last_marker $path]
ok "the marker carries its summary" {
    set summary [dict get $marker summary]
    expr {$marker ne {}
        && [dict get $marker type] eq {fold}
        && [dict get $marker label] eq {compacted history}
        && [llength $summary] == 2
        && [dict get [lindex $summary 0] role] eq {system}
        && [string first {[featherweight]} \
            [dict get [lindex $summary 1] content]] == 0}
}

puts "== what the file holds now =="
set ::featherweight::sessions [dict create]
set live [::featherweight::current_messages]
ok "the conversation resumes from the marker" {
    expr {$live eq $folded}
}

puts "== the cut-away conversation is still in the file =="
ok "every record that was cut away is still there" {
    set found 0
    foreach record [records $path] {
        if {[::featherweight::is_message $record]
                && [dict get $record content] eq [dict get [lindex $messages 1] content]} {
            set found 1
        }
    }
    expr {$found && [llength [records $path]] >= $before_count}
}

puts "== the fold keeps what it does not cut =="
set marker_index -1
set index 0
foreach record [records $path] {
    if {[::featherweight::is_marker $record]} { set marker_index $index }
    incr index
}
set tail [lrange [records $path] [expr {$marker_index + 1}] end]
ok "the kept tail is after the marker, and the summary is before it" {
    expr {[llength $tail] == [llength $folded] - 2
        && [dict get [lindex $tail 0] content] eq \
            [dict get [lindex $folded 2] content]}
}

puts "== the last marker wins =="
# Grow the conversation again and fold once more, so both markers are in the
# file and only the newest one decides what the conversation is.
for {set i 0} {$i < 6} {incr i} {
    ::featherweight::append_message [dict create role user content [string repeat "again $i " 200]]
    ::featherweight::append_message [dict create role assistant content [string repeat "answer $i " 200]]
}
ok "a second fold happens" {
    expr {[::featherweight::compact_context] == 1}
}
set second_folded [::featherweight::current_messages]
set ::featherweight::sessions [dict create]
set live [::featherweight::current_messages]
ok "only the newest marker decides what the conversation is" {
    expr {$live eq $second_folded}
}
set markers 0
foreach record [records $path] {
    if {[::featherweight::is_marker $record]} { incr markers }
}
ok "and both markers are still in the file" {
    expr {$markers == 2}
}

puts "== files without markers are the conversation in full =="
set legacy [file join [file dirname $path] legacy]
::featherweight::write_text_file $legacy \
    "{role system content {system}}\n{role user content {hello}}\n"
set before [::featherweight::read_session legacy]
ok "a file from before markers existed is read whole" {
    expr {[llength $before] == 2
        && [dict get [lindex $before 1] content] eq {hello}}
}

puts "== a marker with no summary means nothing was kept =="
::featherweight::write_text_file $legacy "{role user content {gone}}\n{type fold}\n"
ok "a bare marker leaves an empty conversation" {
    expr {[llength [::featherweight::read_session legacy]] == 0}
}

puts "== damage is still reported =="
::featherweight::write_text_file $legacy "{role user content {fine}}\nplain\n"
ok "a record that is neither message nor marker is refused" {
    expr {[catch {::featherweight::read_session legacy} error] && $error ne {}}
}
::featherweight::write_text_file $legacy "{role user content {fine}}\n"
ok "and a well-formed file is not refused" {
    expr {![catch {::featherweight::read_session legacy} error]}
}

test::finish
