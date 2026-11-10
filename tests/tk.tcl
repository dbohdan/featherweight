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

# The current value of one option of a text tag. Tk 8.6 hands back a record of
# five fields -- the option name, three empty ones, then the value -- so take
# the value from wherever it turns up rather than assuming a shape.
proc tag_value {chat tag option} {
    set record [$chat tag configure $tag $option]
    if {[llength $record] == 5 && [lindex $record 0] eq $option} {
        return [lindex $record 4]
    }
    return $record
}

::featherweight::init_config
if {[catch {::featherweight::build_ui} error]} {
    ::puts stdout "FAIL build_ui: $error"
    exit 1
}
::puts stdout "pass  build_ui"
incr ::test::passed

check "the title is set when the window is built" \
    {[wm title .] eq "Featherweight - [file tail [pwd]]/ - [dict get $::featherweight::config model]"}

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
check "the input is the third pane of the same panedwindow" \
    {[llength [.root.pane panes]] == 3 && {.root.input} in [.root.pane panes]}
check "the Send button fills the height of the input" \
    {[dict get [pack info .root.input.send] -fill] in {y both}}
set sash_gap [expr {[.root.pane sashpos 1]
    - [winfo height .root.pane.chatf]
    - [winfo height .root.pane.dbgf]}]
check "the gap beside the button matches the sash height" \
    {$sash_gap > 0 && [dict get [pack info .root.input.send] -padx] eq [list $sash_gap 0]}
check "the window title names the directory and the model" \
    {[wm title .] eq "Featherweight - [file tail [pwd]]/ - [dict get $::featherweight::config model]"}
::featherweight::handle_slash_command {/model title/model}
check "/model refreshes the title" \
    {[wm title .] eq "Featherweight - [file tail [pwd]]/ - title/model"}
::featherweight::handle_slash_command {/eval dict set ::featherweight::config model from-eval}
check "/eval refreshes the title" \
    {[wm title .] eq "Featherweight - [file tail [pwd]]/ - from-eval"}
check "the view timestamps each message" \
    {[regexp {\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [+-]\d{4}} [$chat get 1.0 end]]}
set line_dump [$chat dump -text -tag 1.0 {1.0 lineend}]
check "the timestamp carries its own tag beside the bold label" \
    {[lsearch -exact $line_dump timestamp] >= 0
        && [lsearch -exact $line_dump role] >= 0}
set sample {0000-00-00 00:00:00 +0000}
set stamp_font [tag_value $chat timestamp -font]
set label_font [tag_value $chat role -font]
check "the timestamp is the size of the message text" \
    {[font measure $stamp_font $sample] == [font measure TkTextFont $sample]}
check "only the label is bold" \
    {[font configure $stamp_font -weight] eq {normal}
        && [font configure $label_font -weight] eq {bold}}

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

# A model turn can change what the title shows: run_code changes the model
# here, the way it could cd or move harness state any other way.
set ::featherweight::busy 1
::featherweight::apply_message [dict create role assistant tool_calls [list \
    [dict create type function id title-check function [dict create name run_code \
        arguments {{"code": "dict set ::featherweight::config model from-tool"}}]]]]
set ::featherweight::busy 0
check "a model turn refreshes the title" \
    {[wm title .] eq "Featherweight - [file tail [pwd]]/ - from-tool"}

# And the directory half: the title is rebuilt from pwd each time.
file mkdir subdir
set here [pwd]
cd subdir
::featherweight::update_window_title
set dir_title [wm title .]
cd $here
check "the title follows the working directory" \
    {$dir_title eq "Featherweight - subdir/ - [dict get $::featherweight::config model]"}

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
