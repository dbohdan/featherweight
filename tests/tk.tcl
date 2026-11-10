#! /usr/bin/env tclsh
# Tk test: the interface replays and switches sessions from the stored files,
# and /compact refreshes the conversation view.

source [file join [file dirname [info script]] lib.tcl]
test::start
package require Tk

proc check {label condition} {
    if {[catch {uplevel 1 [list expr $condition]} result]} {
        incr ::test::failed
        ::puts stdout "FAIL $label: $result"
        return
    }
    if {$result} {
        incr ::test::passed
        ::puts stdout "pass  $label"
    } else {
        incr ::test::failed
        ::puts stdout "FAIL $label"
    }
}

::featherweight::init_config
if {[catch {::featherweight::build_ui} error]} {
    ::puts stdout "FAIL build_ui: $error"
    exit 1
}
::puts stdout "pass  build_ui"
incr ::test::passed

set chat [dict get $::featherweight::W chat]

::featherweight::switch_session foldme
for {set i 0} {$i < 6} {incr i} {
    ::featherweight::append_message [dict create \
        role user \
        content "user $i"]
    ::featherweight::append_message [dict create \
        role assistant \
        content "assistant $i [string repeat {y} 400]"]
}
set before_count [llength [::featherweight::current_messages]]

# Forget what is in memory and show the session again from its file.
set ::featherweight::sessions [dict create]
::featherweight::refresh_session
check "the conversation replays from the session file" \
    {[string first {user 0} [$chat get 1.0 end]] >= 0}
check "the window title names the session" \
    {[string first {foldme} [wm title .]] >= 0}
check "the view timestamps each message" \
    {[regexp {\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [+-]\d{4}} [$chat get 1.0 end]]}
set line_dump [$chat dump -text -tag 1.0 {1.0 lineend}]
check "the timestamp carries its own tag beside the bold label" \
    {[lsearch -exact $line_dump timestamp] >= 0
        && [lsearch -exact $line_dump role] >= 0}
set sample {0000-00-00 00:00:00 +0000}
check "the timestamp font is smaller than the text font" \
    {[font measure ::featherweight::timestamp_font $sample] < [font measure TkTextFont $sample]}

check "/compact folds the session" \
    {[::featherweight::handle_slash_command {/compact}] == 1}
check "the fold dropped messages" \
    {[llength [::featherweight::current_messages]] < $before_count}
set memory_count [llength [::featherweight::current_messages]]

set after_text [$chat get 1.0 end]
check "the view was refreshed to the folded history" \
    {[string first {[featherweight]} $after_text] >= 0}
check "the folded-away assistant reply is gone from the view" \
    {[string first {assistant 0} $after_text] < 0}
check "the dropped user text is still quoted in the view" \
    {[string first {user 0} $after_text] >= 0}

set ::featherweight::sessions [dict create]
check "the folded history matches what is on disk" \
    {[llength [::featherweight::current_messages]] == $memory_count}

# A session with nothing to give up must not throw in the interface either.
::featherweight::switch_session stub
::featherweight::append_message [dict create role user content {only words}]
::featherweight::append_message [dict create role assistant content {only reply}]
set stub_count [llength [::featherweight::current_messages]]
set stub_text [$chat get 1.0 end]
check "/compact on a session it cannot halved returns cleanly" \
    {[::featherweight::handle_slash_command {/compact}] == 1 \
        && [llength [::featherweight::current_messages]] == $stub_count}
check "the view is unchanged by the refused fold" \
    {[string trim [$chat get 1.0 end]] eq [string trim $stub_text]}

# A message written before timestamps existed is shown without one.
$chat configure -state normal
$chat delete 1.0 end
$chat configure -state disabled
::featherweight::ui_user {untimed}
check "a message with no time is shown without a timestamp" \
    {[string trim [$chat get 1.0 end]] eq "You\nuntimed"}

catch {destroy .}

test::finish
