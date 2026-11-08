#! /usr/bin/env tclsh

package require Tcl 8.6 9
package require sqlite3


namespace eval ::featherweight {
    variable version 0.0.0

    # Configuration is embedded.
    variable config [dict create \
        debug true \
        database featherweight.sqlite3 \
        api_key_env_var OPENROUTER_API_KEY \
        endpoint https://openrouter.ai/api/v1/chat/completions \
        model moonshotai/kimi-k3.1-pro \
        system_prompt {You are an expert software developer working with a user on their code.
The user will ask for changes to the code, or ask questions about it.
If a request is ambiguous, ask clarifying questions before making changes.

You have one tool available: run_code.
Use it as a window into the user's environment.} \
        tools [subst {
            run_code {
                -name run_code
                -description {Evaluate code in a stateful Tcl [info patchlevel] interp that persists between calls. Tcllib is available. You receive whatever the code writes to stdout/stderr; use puts to return results.}
                -param {code string {The code to evaluate.}}
                -required code
                -command ::featherweight::tool_run_code
            }
        }]
    ]

    variable code_interp {}
    variable code_output {}
    variable db {}
}


proc ::featherweight::get_env {name {default %UNSET%}} {
    if {![info exists ::env($name)]} {
        if {$default ne {%UNSET%}} {
            return $default
        }

        error "environment variable [list $name] unset"
    }

    return $::env($name)
}


proc ::featherweight::api_key {} {
    variable config

    return [get_env [dict get $config api_key_env_var]]
}


# SQLite's json_quote makes JSON strings, including strings that look like
# numbers, booleans, or null.  SQL literals below contain only its output (or
# other already validated JSON), never unescaped user input.
proc ::featherweight::json_string value {
    variable db
    return [$db onecolumn {SELECT json_quote(:value)}]
}


proc ::featherweight::sql_literal value {
    return '[string map {' ''} $value]'
}


proc ::featherweight::json_object fields {
    variable db

    if {[llength $fields] % 2 != 0} {
        error {json_object requires an even number of arguments}
    }
    set expressions {}
    foreach {key value} $fields {
        lappend expressions [sql_literal $key]  "json([sql_literal $value])"
    }
    return [$db onecolumn "SELECT json_object([join $expressions ,])"]
}


proc ::featherweight::json_array values {
    variable db

    set expressions {}
    foreach value $values {
        lappend expressions "json([sql_literal $value])"
    }
    return [$db onecolumn "SELECT json_array([join $expressions ,])"]
}


proc ::featherweight::json_decode json {
    variable db

    set rows {}
    $db eval {
        SELECT id, parent, key, value, type FROM json_tree(:json)
    } row {
        lappend rows $row(id) $row(parent) $row(key) $row(value) $row(type)
    }
    if {[llength $rows] == 0} {
        error {JSON tree is empty}
    }
    return [json_tree_value $rows [lindex $rows 0]]
}


proc ::featherweight::json_tree_value {rows id} {
    set value {}
    set type {}
    foreach {node_id parent key node_value node_type} $rows {
        if {$node_id == $id} {
            set value $node_value
            set type $node_type
            break
        }
    }
    if {$type eq {}} {
        error "missing JSON tree node: $id"
    }

    switch -- $type {
        object {
            set result {}
            foreach {child_id parent key child_value child_type} $rows {
                if {$parent ne {} && $parent == $id} {
                    dict set result $key [json_tree_value $rows $child_id]
                }
            }
            return $result
        }
        array {
            set result {}
            foreach {child_id parent key child_value child_type} $rows {
                if {$parent ne {} && $parent == $id} {
                    lappend result [json_tree_value $rows $child_id]
                }
            }
            return $result
        }
        true { return 1 }
        false { return 0 }
        null { return null }
        default { return $value }
    }
}


proc ::featherweight::json_tool args {
    if {[llength $args] % 2 != 0
        || [lsort [dict keys $args]] ne {-command -description -name -param -required}} {
        error {wrong # args: should be "::featherweight::json_tool -command command -name name -description description ?-param param ...? ?-required required?"}
    }

    set name [dict get $args -name]
    set description [dict get $args -description]
    set properties {}
    set required {}

    if {[dict exists $args -required]} {
        set required [dict get $args -required]
    }

    dict for {option value} $args {
        switch -- $option {
            -command -
            -name -
            -description -
            -required {
                # Do nothing.
            }

            -param {
                if {[llength $value] != 3} {
                    error {each -param must be {name type description}}
                }

                lassign $value property type param_description

                if {[dict exists $properties $property]} {
                    error "duplicate parameter: $property"
                }

                dict set properties $property [list $type $param_description]
            }

            default {
                error "unknown option: $option"
            }
        }
    }

    set json_properties {}
    dict for {property schema} $properties {
        lassign $schema type param_description
        lappend json_properties $property [json_object [list  type [json_string $type]  description [json_string $param_description]  ]]
    }

    set json_required {}
    foreach property $required {
        lappend json_required [json_string $property]
    }

    set parameters [json_object [list  type [json_string object]  properties [json_object $json_properties]  required [json_array $json_required]  ]]

    return [json_object [list  type [json_string function]  function [json_object [list  name [json_string $name]  description [json_string $description]  parameters $parameters  ]]  ]]
}


proc ::featherweight::json_tool_call call {
    set function [dict get $call function]

    return [json_object [list  id [json_string [dict get $call id]]  type [json_string [dict get $call type]]  function [json_object [list  name [json_string [dict get $function name]]  arguments [json_string [dict get $function arguments]]  ]]  ]]
}


proc ::featherweight::json_message message {
    set fields {}

    dict for {key value} $message {
        if {$key eq {tool_calls}} {
            set calls {}
            foreach call $value {
                lappend calls [json_tool_call $call]
            }
            lappend fields tool_calls [json_array $calls]
        } else {
            lappend fields $key [json_string $value]
        }
    }

    return [json_object $fields]
}


proc ::featherweight::json_payload {model json_tools message_json_values} {
    return [json_object [list  model [json_string $model]  messages [json_array $message_json_values]  reasoning [json_object [list effort [json_string low]]]  tools [json_array $json_tools]  tool_choice [json_string auto]  ]]
}


proc ::featherweight::db_open {} {
    variable config
    variable db

    if {$db ne {}} { return }
    sqlite3 [namespace current]::database [dict get $config database]
    set db [namespace current]::database
    $db eval {
        PRAGMA journal_mode = WAL;
        CREATE TABLE IF NOT EXISTS messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            role TEXT NOT NULL,
            json TEXT NOT NULL CHECK (json_valid(json)),
            created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
        );
    }
}


proc ::featherweight::messages {} {
    variable db

    set result {}
    $db eval {SELECT json FROM messages ORDER BY id} row {
        lappend result $row(json)
    }
    return $result
}


proc ::featherweight::append_message message {
    variable db

    set json [json_message $message]
    set role [dict get $message role]
    $db eval {INSERT INTO messages (role, json) VALUES (:role, :json)}
}


proc ::featherweight::clear_messages {} {
    variable config
    variable db

    set message [dict create role system content [dict get $config system_prompt]]
    set json [json_message $message]
    $db transaction {
        $db eval {DELETE FROM messages}
        $db eval {INSERT INTO messages (role, json) VALUES ('system', :json)}
    }
}


proc ::featherweight::initialize_session {} {
    variable db

    if {[$db onecolumn {SELECT count(*) FROM messages}] == 0} {
        clear_messages
    }
}


proc ::featherweight::tools_json {} {
    variable config

    return [lmap tool_args [dict values [dict get $config tools]] {
        json_tool {*}$tool_args
    }]
}


proc ::featherweight::interp_puts {interp args} {
    variable code_output

    set nonewline [expr {[lindex $args 0] eq {-nonewline}}]
    if {$nonewline} {
        set args [lrange $args 1 end]
    }

    switch -- [llength $args] {
        1 {
            set channel stdout
            set text [lindex $args 0]
        }
        2 {
            lassign $args channel text
        }
        default {
            return -code error {wrong # args: should be "puts ?-nonewline? ?channelId? string"}
        }
    }

    if {$channel ni {stdout stderr}} {
        set forwarded [expr {$nonewline ? [linsert $args 0 -nonewline] : $args}]
        tailcall interp eval $interp ::__featherweight_puts {*}$forwarded
    }
    append code_output $text [expr {$nonewline ? {} : "\n"}]
    return
}


proc ::featherweight::get_code_interp {} {
    variable code_interp

    if {$code_interp eq {} || ![interp exists $code_interp]} {
        set code_interp [interp create]
        $code_interp eval {rename puts ::__featherweight_puts}
        interp alias $code_interp puts {} ::featherweight::interp_puts $code_interp
    }

    return $code_interp
}


proc ::featherweight::tool_run_code arguments {
    variable config
    variable code_output

    if {[dict get $config debug]} {
        debug_log tool "run_code $arguments"
    }

    set code_output {}
    set status [catch {
        interp eval [get_code_interp] [dict get $arguments code]
    } error]
    set result $code_output
    set code_output {}

    if {$status} {
        append result [list Error evaluating code: $error]
    }

    return $result
}


proc ::featherweight::call_tool tool_call {
    variable config

    set id [dict get $tool_call id]
    set type [dict get $tool_call type]
    if {$type ne {function}} {
        return [dict create role tool tool_call_id $id content "Error: unknown tool call type: [list $type]"]
    }
    set function [dict get $tool_call function]
    set name [dict get $function name]
    set arguments [dict get $function arguments]

    if {![dict exists [dict get $config tools] $name]} {
        return [dict create role tool tool_call_id $id content "Error: unknown tool name: [list $name]"]
    }

    set command [dict get $config tools $name -command]
    if {[catch {
        set result [{*}$command [json_decode $arguments]]
    } result]} {
        set result "Error evaluating tool: $result"
    }

    return [dict create  role tool  tool_call_id $id  content $result  ]
}


namespace eval ::featherweight {
    variable W {}
    variable json_tools {}
    variable user_input {}
    variable busy 0
    variable tok {}
    variable done 0
}


proc ::featherweight::pretty {raw} {
    variable db
    if {[$db onecolumn {SELECT json_valid(:raw)}]} {
        return [$db onecolumn {SELECT json_pretty(:raw)}]
    }
    return $raw
}


proc ::featherweight::debug_log {category text} {
    variable config
    variable W
    if {![dict get $config debug] && $category ni {error}} { return }
    set ts [clock format [clock seconds] -format {%H:%M:%S}]
    if {[dict exists $W debug]} {
        set w [dict get $W debug]
        $w configure -state normal
        $w insert end "$ts ($category) $text\n" [list "cat_$category"]
        $w configure -state disabled
        $w see end
        return
    }
    if {[catch {
        set fh [open [file join [pwd] featherweight-debug.log] a]
        puts $fh "$ts ($category) $text"
        close $fh
    }]} {}
}


proc ::featherweight::clean_assistant_message {msg} {
    set out [dict create role assistant]
    if {[dict exists $msg content]} {
        set content [dict get $msg content]
        if {$content ni {"" null}} {
            dict set out content $content
        }
    }
    if {[dict exists $msg tool_calls]} {
        dict set out tool_calls [dict get $msg tool_calls]
    }
    return $out
}


proc ::featherweight::ui_append {tag text} {
    variable W
    if {![dict exists $W chat]} { return }
    set t [dict get $W chat]
    $t configure -state normal
    $t insert end $text [list $tag]
    $t configure -state disabled
    $t see end
}


proc ::featherweight::ui_user {text} {
    ui_append role "You\n"
    ui_append user "$text\n\n"
}


proc ::featherweight::ui_assistant {text} {
    ui_append role "Assistant\n"
    ui_append assistant "$text\n\n"
}


proc ::featherweight::ui_tool {text} {
    ui_append role "Tool\n"
    ui_append tool "$text\n\n"
}


proc ::featherweight::replay_messages {} {
    foreach json [messages] {
        set message [json_decode $json]
        switch -- [dict get $message role] {
            user { ui_user [dict get $message content] }
            assistant {
                if {[dict exists $message content]} {
                    ui_assistant [dict get $message content]
                }
            }
            tool {
                if {[dict exists $message content]} {
                    ui_tool [dict get $message content]
                }
            }
        }
    }
}


proc ::featherweight::set_ui_busy {flag} {
    variable W
    variable busy
    set busy $flag
    if {![dict exists $W send]} { return }
    if {$flag} {
        [dict get $W send] configure -state disabled
        [dict get $W entry] configure -state disabled
        [dict get $W status] configure -text "Working..."
    } else {
        [dict get $W send] configure -state normal
        [dict get $W entry] configure -state normal
        [dict get $W status] configure -text "Ready"
        focus [dict get $W entry]
    }
}


proc ::featherweight::submit {} {
    variable busy
    variable user_input
    if {$busy} { return }
    set text [string trim $user_input]
    if {$text eq {}} { return }
    set user_input {}
    append_message [dict create role user content $text]
    ui_user $text
    set_ui_busy 1
    request_async
}


proc ::featherweight::clear {} {
    variable W
    variable busy
    if {$busy} { return }
    clear_messages
    if {[dict exists $W chat]} {
        set chat [dict get $W chat]
        $chat configure -state normal
        $chat delete 1.0 end
        $chat configure -state disabled
    }
    debug_log tool "conversation cleared"
}


proc ::featherweight::request_async {} {
    variable config
    variable curl_data
    variable json_tools

    set payload [json_payload [dict get $config model] $json_tools [messages]]
    debug_log request [pretty $payload]

    set curl_data(ch) {}
    set ch [open |[list curl  --data-raw $payload  --header "Authorization: Bearer [api_key]"  --header {Content-Type: application/json}  --request POST  --show-error  --silent  --write-out "\n%{http_code} %{exitcode} %{errormsg}"  [dict get $config endpoint]  ]]

    fconfigure $ch -blocking 0
    fileevent $ch readable [list [namespace current]::request_readable $ch]
}


proc ::featherweight::request_readable ch {
    variable curl_data

    # Accumulate available output.
    # Wait for EOF before parsing the response.
    append curl_data($ch) [read $ch]
    if {![eof $ch]} {
        return
    }

    fileevent $ch readable {}
    set output $curl_data($ch)
    unset curl_data($ch)

    if {[catch {close $ch} error options]} {
        debug_log error "curl request failed: $error"
        set_ui_busy 0
        return
    }

    # Separate the status appended by --write-out from the response body.
    set marker [string last "\n" $output]
    if {$marker < 0} {
        debug_log error {curl response did not include an HTTP status}
        set_ui_busy 0
        return
    }

    set metadata [string range $output [expr {$marker + 1}] end]
    set error_msg [lassign $metadata status exit_code]

    if {![string is integer -strict $status]} {
        debug_log error "invalid HTTP status from curl: $status"
        set_ui_busy 0
        return
    }

    if {![string is integer -strict $exit_code]} {
        debug_log error "invalid exit code from curl: $exit_code"
        set_ui_busy 0
        return
    }

    if {$exit_code != 0} {
        debug_log error "curl ($exit_code): $error_msg"
        set_ui_busy 0
        return
    }

    set data [string range $output 0 [expr {$marker - 1}]]

    debug_log response "HTTP $status\n[pretty $data]"

    if {$status != 200} {
        debug_log error "HTTP $status: $data"
        set_ui_busy 0
        return
    }

    if {[catch {json_decode $data} response]} {
        debug_log error "JSON decode failed: $response"
        set_ui_busy 0
        return
    }

    if {![dict exists $response choices] || [llength [dict get $response choices]] == 0} {
        debug_log error {response has no choices}
        set_ui_busy 0
        return
    }

    set choice [lindex [dict get $response choices] 0]
    if {![dict exists $choice message]} {
        debug_log error "choice has no message"
        set_ui_busy 0
        return
    }

    set raw [dict get $choice message]
    set cleaned [clean_assistant_message $raw]

    if {[dict exists $cleaned content]} {
        ui_assistant [dict get $cleaned content]
    }

    append_message $cleaned

    if {[dict exists $cleaned tool_calls]} {
        foreach call [dict get $cleaned tool_calls] {
            debug_log tool "call: $call"
            set result [call_tool $call]
            append_message $result
            ui_tool [dict get $result content]
        }
        request_async
        return
    }

    set_ui_busy 0
}


proc ::featherweight::on_close {} {
    variable done
    set done 1
}


proc ::featherweight::build_ui {} {
    variable W
    variable config

    catch {ttk::style theme use clam}

    wm title . "Featherweight - [dict get $config model]"
    wm minsize . 640 420
    wm geometry . 900x650
    wm protocol . WM_DELETE_WINDOW ::featherweight::on_close

    ttk::frame .root -padding {6 6 6 6}
    pack .root -fill both -expand 1

    ttk::panedwindow .root.pane -orient vertical
    pack .root.pane -fill both -expand 1

    ttk::frame .root.pane.chatf
    ttk::label .root.pane.chatf.lbl -text "Conversation" -anchor w
    pack .root.pane.chatf.lbl -side top -fill x
    ttk::frame .root.pane.chatf.body
    pack .root.pane.chatf.body -fill both -expand 1
    text .root.pane.chatf.body.t -wrap word -height 18 -width 80 -state disabled -yscrollcommand {.root.pane.chatf.body.sb set}
    ttk::scrollbar .root.pane.chatf.body.sb -command {.root.pane.chatf.body.t yview}
    grid .root.pane.chatf.body.t .root.pane.chatf.body.sb -sticky nsew
    grid rowconfigure .root.pane.chatf.body 0 -weight 1
    grid columnconfigure .root.pane.chatf.body 0 -weight 1
    .root.pane add .root.pane.chatf -weight 3

    ttk::frame .root.pane.dbgf
    ttk::label .root.pane.dbgf.lbl -text "Debug" -anchor w
    pack .root.pane.dbgf.lbl -side top -fill x
    ttk::frame .root.pane.dbgf.body
    pack .root.pane.dbgf.body -fill both -expand 1
    text .root.pane.dbgf.body.t -wrap word -height 8 -width 80 -state disabled -font TkFixedFont -background #11161c -foreground #d6d6d6 -yscrollcommand {.root.pane.dbgf.body.sb set}
    ttk::scrollbar .root.pane.dbgf.body.sb -command {.root.pane.dbgf.body.t yview}
    grid .root.pane.dbgf.body.t .root.pane.dbgf.body.sb -sticky nsew
    grid rowconfigure .root.pane.dbgf.body 0 -weight 1
    grid columnconfigure .root.pane.dbgf.body 0 -weight 1
    .root.pane add .root.pane.dbgf -weight 2

    ttk::frame .root.input
    pack .root.input -fill x -pady {6 0}
    ttk::entry .root.input.e -textvariable ::featherweight::user_input
    ttk::button .root.input.clear -text "Clear" -command ::featherweight::clear
    ttk::button .root.input.send -text "Send" -command ::featherweight::submit
    pack .root.input.send -side right -padx {4 0}
    pack .root.input.clear -side right
    pack .root.input.e -side left -fill x -expand 1
    bind .root.input.e <Return> {::featherweight::submit; break}
    bind .root.input.e <KP_Enter> {::featherweight::submit; break}

    ttk::label .root.status -text "Ready" -anchor w
    pack .root.status -fill x

    set W [dict create chat .root.pane.chatf.body.t debug .root.pane.dbgf.body.t entry .root.input.e send .root.input.send status .root.status]

    set chat [dict get $W chat]
    font create ::featherweight::role_font  {*}[font configure TkTextFont]  -weight bold
    $chat tag configure role -font ::featherweight::role_font -foreground #555555
    $chat tag configure user -foreground #0b57d0
    $chat tag configure assistant -foreground #1b5e20
    $chat tag configure tool -foreground #6a1b9a
    $chat configure -state disabled

    set dbg [dict get $W debug]
    $dbg tag configure cat_error -foreground #ff6b6b
    $dbg tag configure cat_request -foreground #4fc3f7
    $dbg tag configure cat_response -foreground #a5d6a7
    $dbg tag configure cat_tool -foreground #ce93d8

    focus [dict get $W entry]
}


proc ::featherweight::console_main {} {
    puts "featherweight console mode (type a message; Ctrl-D to exit)"
    while {[gets stdin line] >= 0} {
        if {[string trim $line] eq {}} { continue }
        append_message [dict create role user content $line]
        console_turn
    }
}


proc ::featherweight::console_turn {} {
    variable config
    variable json_tools
    variable tok
    while 1 {
        set payload [json_payload [dict get $config model] $json_tools [messages]]
        debug_log request [pretty $payload]
        if {[catch {
            set tok [::http::geturl [dict get $config endpoint] -method POST -type application/json -headers [list Authorization "Bearer [api_key]"] -query $payload]
            set status [::http::ncode $tok]
            set data [::http::data $tok]
        } err]} {
            puts "Error: $err"
            return
        }
        catch {::http::cleanup $tok}
        if {$status != 200} {
            puts "Error: HTTP $status"
            debug_log error "HTTP $status: $data"
            return
        }
        if {[catch {json_decode $data} response]} {
            puts "Error: response was not valid JSON"
            return
        }
        if {![dict exists $response choices] || [llength [dict get $response choices]] == 0} {
            puts "Error: response had no choices"
            return
        }
        set choice [lindex [dict get $response choices] 0]
        set cleaned [clean_assistant_message [dict get $choice message]]
        if {[dict exists $cleaned content]} {
            puts "Assistant: [dict get $cleaned content]"
        }
        append_message $cleaned
        if {![dict exists $cleaned tool_calls]} { return }
        foreach call [dict get $cleaned tool_calls] {
            debug_log tool "call: $call"
            set result [call_tool $call]
            puts "Tool: [dict get $result content]"
            append_message $result
        }
    }
}


proc ::featherweight::main {argv0 argv} {
    variable config
    variable db
    variable done

    db_open
    initialize_session
    set ::featherweight::json_tools [tools_json]

    if {[catch {package require Tk} err]} {
        puts "Tk/display unavailable ($err); falling back to console mode."
        console_main
        $db close
        return
    }

    if {[catch {build_ui} err]} {
        puts "Could not create UI ($err); falling back to console mode."
        catch {destroy .}
        console_main
        $db close
        return
    }

    replay_messages
    debug_log tool "model: [dict get $config model]"
    debug_log tool "endpoint: [dict get $config endpoint]"
    debug_log tool "database: [dict get $config database]"

    vwait ::featherweight::done
    catch {destroy .}
    $db close
}


# If this is the main script...
if {[info exists argv0] && ([file tail [info script]] eq [file tail $argv0])} {
    ::featherweight::main $argv0 $argv
}
