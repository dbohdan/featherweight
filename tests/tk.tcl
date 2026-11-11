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

# Geometry is only real once Tk has laid the window out; build_ui no longer
# takes an update of its own.
update

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

# A sash sits between the input and Send, as one sits between Conversation and
# Debug. ttk::panedwindow exposes no sash option, so the handle is found
# through identify at the sash position.
set sash_pos [.root.input.p sashpos 0]
check "there is a sash between the input and the Send button" \
    {$sash_pos > 0
        && $sash_pos < [winfo width .root.input.p]
        && [.root.input.p identify $sash_pos 5] ne {}}
check "the Send button spans the height of the input" \
    {[winfo height .root.input.p.send] == [winfo height .root.input.p]}
check "the Send button keeps its own width" \
    {[winfo width .root.input.p.send] == [winfo reqwidth .root.input.p.send]}

# Window resizes feed the input pane, not the button.
set wide_entry [winfo width .root.input.p.e]
set wide_button [winfo width .root.input.p.send]
set wide_window [winfo width .]
wm geometry . [expr {$wide_window + 300}]x[winfo height .]
update
check "resizing the window widens the input, not the button" \
    {[winfo width .root.input.p.e] > $wide_entry
        && [winfo width .root.input.p.send] == $wide_button}
wm geometry . ${wide_window}x[winfo height .]
update

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

# A request or response entry is folded to its header, with a marker that
# opens and closes it again.
set dbg [dict get $::featherweight::W debug]
::featherweight::debug_log request "{\n  \"payload\": true\n}"
set bodies {}
foreach tag [$dbg tag names] {
    if {[string match body* $tag]} { lappend bodies $tag }
}
set body [lindex $bodies end]
set n [string range $body 4 end]
check "a request is logged folded to its header" \
    {[string first {(request) [+]} [$dbg get 1.0 end]] >= 0
        && [string first {payload} [$dbg get 1.0 end]] >= 0
        && [tag_value $dbg $body -elide]}
::featherweight::debug_toggle $dbg $n
check "the marker opens it" \
    {![tag_value $dbg $body -elide]
        && [string first {(request) [-]} [$dbg get 1.0 end]] >= 0}
::featherweight::debug_toggle $dbg $n
check "and closes it again" \
    {[tag_value $dbg $body -elide]
        && [string first {(request) [+]} [$dbg get 1.0 end]] >= 0}
check "the marker is bound to the toggle" \
    {[string first {debug_toggle} [$dbg tag bind toggle$n <Button-1>]] >= 0}

# A tool call is folded too, with the tool name in its header; a tool note
# stays visible, since there is nothing to fold.
set call [dict create type function id run_code:0 \
    function [dict create name run_code arguments {"code": "puts hi"}]]
::featherweight::debug_log tool "call: $call" run_code
set bodies {}
foreach tag [$dbg tag names] {
    if {[string match body* $tag]} { lappend bodies $tag }
}
set body [lindex $bodies end]
check "a tool call is folded with its name in the header" \
    {[string first {(tool) run_code [+]} [$dbg get 1.0 end]] >= 0
        && [tag_value $dbg $body -elide]}
set folded_count [llength $bodies]
::featherweight::debug_log tool {model set to test/model}
set bodies {}
foreach tag [$dbg tag names] {
    if {[string match body* $tag]} { lappend bodies $tag }
}
check "a tool note stays visible" \
    {[llength $bodies] == $folded_count}
# Tk draws an underline in the colour of the tag that sets it, so the marker's
# own tag carries both.
set toggles {}
foreach tag [$dbg tag names] {
    if {[string match toggle* $tag]} { lappend toggles $tag }
}
set last_toggle [lindex $toggles end]
check "the marker's underline matches its text colour" \
    {[tag_value $dbg toggle$n -underline] == 1
        && [tag_value $dbg toggle$n -underlinefg] eq [tag_value $dbg cat_request -foreground]
        && [tag_value $dbg $last_toggle -underlinefg] eq [tag_value $dbg cat_tool -foreground]}

# Attachments go out with the next user message, and are listed in the status
# bar until they do.
set png [file join $::test::work shot.png]
::fileutil::writeFile -encoding binary $png "fake image bytes"
::featherweight::handle_slash_command "/attach $png"
check "attach lists the image in the status bar" \
    {[llength $::featherweight::attachments] == 1
        && [string first {(1) shot.png} [[dict get $::featherweight::W status] cget -text]] >= 0}
check "attach keeps a copy in the state directory" \
    {[file exists [file join [::featherweight::attachments_dir] 1-shot.png]]}
set png2 [file join $::test::work other.png]
::fileutil::writeFile -encoding binary $png2 "more fake bytes"
::featherweight::handle_slash_command "/attach $png2"
check "a second attachment is numbered" \
    {[string first {(2) other.png} [[dict get $::featherweight::W status] cget -text]] >= 0}
::featherweight::handle_slash_command {/detach 1}
check "detach removes one by number and renumbers the list" \
    {[llength $::featherweight::attachments] == 1
        && [string first {(1) other.png} [[dict get $::featherweight::W status] cget -text]] >= 0
        && ![file exists [file join [::featherweight::attachments_dir] 1-shot.png]]}
set attached [dict create role user content [list \
    [dict create type text text {look at this}] \
    [dict create type image name other.png path [file join [::featherweight::attachments_dir] 2-other.png]]]]
check "the request carries an attached image as a data URL" \
    {[string first {image_url} [::featherweight::json_message $attached]] >= 0
        && [string first {base64,} [::featherweight::json_message $attached]] >= 0}
check "an attached image is counted from its shape, not its bytes" \
    {[::featherweight::message_tokens $attached] == 1600 + [::featherweight::estimate_tokens {look at this}]}
check "the report counts staged attachments too" \
    {[string first {staged attachments} [::featherweight::context_report]] >= 0}
check "a message with an image displays it by name" \
    {[string first {[image: other.png]} [::featherweight::content_display [dict get $attached content]]] >= 0}
::featherweight::handle_slash_command {/detach}
check "detach with no argument clears them" \
    {[llength $::featherweight::attachments] == 0
        && [[dict get $::featherweight::W status] cget -text] eq {Ready}}

# A request the network drops is sent again, and gives up after the configured
# number of retries. The endpoint is a dead port, so curl fails locally and
# nothing leaves the machine.
dict set ::featherweight::config endpoint http://127.0.0.1:1/
dict set ::featherweight::config api_key_env_var TEST_API_KEY
dict set ::featherweight::config retries 2
dict set ::featherweight::config timeout 5
set ::env(TEST_API_KEY) test-key
set dbg [dict get $::featherweight::W debug]
::featherweight::append_message [dict create role user content {hello}]
set ::featherweight::retry_count 0
set ::featherweight::busy 1
::featherweight::request_async
set deadline [expr {[clock milliseconds] + 30000}]
while {$::featherweight::busy && [clock milliseconds] < $deadline} {
    update
    after 25
}
set log_text [$dbg get 1.0 end]
check "a dropped request is retried before giving up" \
    {[string first {retry 1 of 2} $log_text] >= 0
        && [string first {retry 2 of 2} $log_text] >= 0
        && [string first {giving up after 2 retries} $log_text] >= 0}
check "the turn stops once the retries are spent" \
    {$::featherweight::busy == 0}

catch {destroy .}

test::finish
