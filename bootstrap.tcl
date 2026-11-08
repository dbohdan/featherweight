#! /usr/bin/env tclsh

package require Tcl 8.6 9

package require fileutil
package require json
package require json::write


namespace eval ::featherweight {
    variable version 0.0.0

    # Default configuration and state.
    variable config [dict create \
        debug true \
        \
        api_key_env_var OPENROUTER_API_KEY \
        endpoint https://openrouter.ai/api/v1/chat/completions \
        model moonshotai/kimi-k3.1-pro \
        system_prompt {You are an expert software developer working with a user on their code.
The user will ask for changes to the code, or ask questions about it.
If a request is ambiguous, ask clarifying questions before making changes.

You have one tool available: run_code.
Use it as a window into the user's environment.} \
        \
        current_session default \
        sessions {default {}} \
    ]

    variable run_code_output {}
    variable tools_available [subst {
        run_code {
            -name run_code
            -description {Evaluate code in a stateful Tcl [info patchlevel] interp that the harness runs in.\
                State persists between calls.\
                Tcllib is available.\
                You receive the return value plus whatever the code writes to stdout/stderr.}
            -param {code string {The code to evaluate.}}
            -required code
            -command ::featherweight::tool_run_code
        }
    }]
}


proc ::featherweight::config_path {} {
    return [file join [pwd] featherweight.conf]
}


proc ::featherweight::init_config {} {
    variable config

    set path [config_path]
    if {[file exists $path]} {
        if {[catch {::fileutil::cat -encoding utf-8 $path} loaded options]} {
            error "could not load [list $path]: $loaded" {} [dict get $options -errorinfo]
        }
        if {[catch {dict size $loaded}]} {
            error "configuration in [list $path] is not a Tcl dict"
        }
        set config $loaded
    }

    set system_message [dict create role system content [dict get $config system_prompt]]
    if {![dict exists $config sessions] || [dict size [dict get $config sessions]] == 0} {
        dict set config sessions default [list $system_message]
    }
    if {![dict exists $config current_session]
            || ![dict exists $config sessions [dict get $config current_session]]} {
        dict set config current_session default
    }
    if {[llength [current_messages]] == 0} {
        dict set config sessions [dict get $config current_session] [list $system_message]
    }
    save_config
}


proc ::featherweight::current_messages {} {
    variable config
    return [dict get $config sessions [dict get $config current_session]]
}


proc ::featherweight::save_config {} {
    variable config

    set path [config_path]
    set temporary "$path.[pid].tmp"

    if {[catch {
        set channel [open $temporary w]
        fconfigure $channel -encoding utf-8

        dict for {key value} $config {
            if {$key eq {sessions}} {
                ::puts $channel "sessions {"
                dict for {name messages} $value {
                    ::puts $channel "    [list $name] {"
                    foreach message $messages {
                        ::puts $channel "        [list $message]"
                    }
                    ::puts $channel "    }"
                }
                ::puts $channel "}"
            } else {
                ::puts $channel [list $key $value]
            }
        }

        close $channel
        file rename -force $temporary $path
    } error]} {
        catch {close $channel}
        catch {file delete -force $temporary}
        debug_log error "could not save [list $path]: $error"
    }
}


proc ::featherweight::append_message message {
    variable config

    set sessions [dict get $config sessions]
    dict lappend sessions [dict get $config current_session] $message
    dict set config sessions $sessions

    save_config
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


proc ::featherweight::json_tool args {
    if {[llength $args] % 2 != 0
        || [lsort [dict keys $args]] ne {-command -description -name -param -required}} {
        error {wrong # args: should be\
            "::featherweight::json_tool -command command -name name\
            -description description ?-param param ...? ?-required required?"}
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
        lappend json_properties $property [::json::write object \
            type [::json::write string $type] \
            description [::json::write string $param_description] \
        ]
    }

    set json_required {}
    foreach property $required {
        lappend json_required [::json::write string $property]
    }

    set parameters [::json::write object \
        type [::json::write string object] \
        properties [::json::write object {*}$json_properties] \
        required   [::json::write array {*}$json_required] \
    ]

    return [::json::write object \
        type [::json::write string "function"] \
        function [::json::write object \
            name [::json::write string $name] \
            description [::json::write string $description] \
            parameters $parameters \
        ] \
    ]
}

proc ::featherweight::json_tool_call call {
    set function [dict get $call function]

    return [::json::write object \
        id [::json::write string [dict get $call id]] \
        type [::json::write string [dict get $call type]] \
        function [::json::write object \
            name [::json::write string [dict get $function name]] \
            arguments [::json::write string [dict get $function arguments]] \
        ] \
    ]
}

proc ::featherweight::json_message message {
    set fields {}

    dict for {key value} $message {
        if {$key eq {tool_calls}} {
            set calls {}

            foreach call $value {
                lappend calls [::featherweight::json_tool_call $call]
            }

            lappend fields tool_calls [::json::write array {*}$calls]
        } else {
            lappend fields $key [::json::write string $value]
        }
    }

    return [::json::write object {*}$fields]
}


proc ::featherweight::json_payload {model json_tools messages} {
    set json_messages [lmap message $messages {
        ::featherweight::json_message $message
    }]

    return [::json::write object \
        model [::json::write string $model] \
        messages [::json::write array {*}$json_messages] \
        reasoning [::json::write object effort [::json::write string low]] \
        tools [::json::write array {*}$json_tools] \
        tool_choice [::json::write string auto] \
    ]
}


proc ::featherweight::puts args {
    variable run_code_output

    set prefix {}
    if {[lindex $args 0] eq {-nonewline}} {
        set prefix -nonewline
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

    if {$channel in {stdout stderr}} {
        append run_code_output $text [expr {$prefix eq {-nonewline} ? {} : "\n"}]
        return
    }

    tailcall ::puts {*}$prefix $channel $text
}


proc ::featherweight::tool_run_code arguments {
    variable config
    variable run_code_output

    if {[dict get $config debug]} {
        debug_log tool "run_code $arguments"
    }

    set run_code_output {}
    set value {}

    catch {
        namespace eval ::featherweight [dict get $arguments code]
    } result options

    return [join [list \
        <output>$run_code_output</output> \
        <result>$result</result>  \
        <options>$options</options> \
    ] \n]
}


proc ::featherweight::call_tool tool_call {
    variable config
    variable tools_available

    set id [dict get $tool_call id]
    set type [dict get $tool_call type]
    if {$type ne {function}} {
        return [dict create \
            role tool \
            tool_call_id $id \
            content "Error: unknown tool call type: [list $type]" \
        ]
    }
    set function [dict get $tool_call function]
    set name [dict get $function name]
    set arguments [dict get $function arguments]

    if {![dict exists $tools_available $name]} {
        return [dict create \
            role tool \
            tool_call_id $id \
            content "Error: unknown tool name: [list $name]" \
        ]
    }

    set command [dict get $tools_available $name -command]
    if {[catch {
        set result [{*}$command [::json::json2dict $arguments]]
    } result]} {
        set result "Error evaluating tool: $result"
    }

    return [dict create \
        role tool \
        tool_call_id $id \
        content $result \
    ]
}



namespace eval ::featherweight {
    variable W {}
    variable json_tools {}
    variable busy 0
    variable tok {}
    variable done 0
    variable request_channels
    array set request_channels {}
}


proc ::featherweight::pretty {raw} {
    if {[auto_execok jq] ne {}} {
        if {![catch {exec jq . << $raw} out]} {
            return $out
        }
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
        ::puts $fh "$ts ($category) $text"
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


proc ::featherweight::ui_tool_code {call} {
    set function [dict get $call function]
    set arguments [dict get $function arguments]
    if {[dict get $function name] eq {run_code}
            && ![catch {json::json2dict $arguments} decoded]
            && [dict exists $decoded code]} {
        set code [dict get $decoded code]
    } else {
        set code $arguments
    }
    ui_append role "Tool code\n"
    ui_append tool "$code\n\n"
}


proc ::featherweight::ui_tool {text} {
    ui_append role "Tool\n"
    ui_append tool "$text\n\n"
}


proc ::featherweight::replay_messages {} {
    variable config

    set pending_tool_calls {}
    foreach message [current_messages] {
        switch -- [dict get $message role] {
            user {
                ui_user [dict get $message content]
            }
            assistant {
                if {[dict exists $message content]} {
                    ui_assistant [dict get $message content]
                }
                set pending_tool_calls {}
                if {[dict exists $message tool_calls]} {
                    set pending_tool_calls [dict get $message tool_calls]
                }
            }
            tool {
                set id [dict get $message tool_call_id]
                foreach call $pending_tool_calls {
                    if {[dict get $call id] eq $id} {
                        ui_tool_code $call
                        break
                    }
                }
                ui_tool [dict get $message content]
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
        [dict get $W send] configure -text "Stop" -state normal
        [dict get $W status] configure -text "Working..."
    } else {
        [dict get $W send] configure -text "Send" -state normal
        [dict get $W status] configure -text "Ready"
        focus [dict get $W entry]
    }
}


proc ::featherweight::stop {} {
    variable busy
    variable curl_data
    variable request_channels

    if {!$busy} { return }
    set busy 0
    foreach ch [array names request_channels] {
        fileevent $ch readable {}
        unset -nocomplain curl_data($ch)
        if {$::tcl_platform(platform) eq {windows}} {
            catch {exec taskkill /PID [pid $ch] /F}
        } else {
            catch {exec kill [pid $ch]}
        }
        catch {close $ch}
        unset request_channels($ch)
    }
    set_ui_busy 0
    debug_log tool "tool-call chain stopped by user"
}




proc ::featherweight::submit_or_stop {} {
    variable busy
    if {$busy} {
        stop
    } else {
        submit
    }
}


proc ::featherweight::submit {} {
    variable W
    variable busy
    if {$busy} { return }
    set entry [dict get $W entry]
    set text [string trim [$entry get 1.0 end-1c]]
    if {$text eq {}} { return }
    $entry delete 1.0 end
    if {[handle_slash_command $text]} { return }
    append_message [dict create role user content $text]
    ui_user $text
    set_ui_busy 1
    request_async
}


proc ::featherweight::update_window_title {} {
    variable config
    variable W
    if {![dict exists $W chat]} { return }
    wm title . "Featherweight - [dict get $config model] - [dict get $config current_session]"
}


proc ::featherweight::refresh_session {} {
    variable W
    if {![dict exists $W chat]} { return }
    set chat [dict get $W chat]
    $chat configure -state normal
    $chat delete 1.0 end
    $chat configure -state disabled
    replay_messages
    update_window_title
}


proc ::featherweight::switch_session name {
    variable config

    if {$name eq {}} {
        error {session name cannot be empty}
    }
    if {![dict exists $config sessions $name]} {
        dict set config sessions $name [list \
            [dict create \
                role system \
                content [dict get $config system_prompt] \
            ] \
        ]
    }
    dict set config current_session $name
    save_config
    refresh_session
}


proc ::featherweight::handle_slash_command text {
    variable config
    variable W

    if {[string index $text 0] ne {/}} { return 0 }
    if {[regexp {^/([^[:space:]]+)(?:[[:space:]]+(.*))?$} $text -> command arguments]} {
        set command [string tolower $command]
    } else {
        return 0
    }

    switch -- $command {
        model {
            set model [string trim $arguments]
            if {$model eq {}} {
                debug_log tool "current model: [dict get $config model]"
                return 1
            }
            dict set config model $model
            save_config
            update_window_title
            debug_log tool "model set to $model"
        }
        eval {
            if {[string trim $arguments] eq {}} {
                debug_log error {usage: /eval Tcl-code}
                return 1
            }
            # Use the same evaluator and output format as the run_code tool.
            debug_log eval "/eval $arguments"
            debug_log eval [tool_run_code [dict create code $arguments]]
        }
        session {
            set name [string trim $arguments]
            if {$name eq {}} {
                set names [lsort [dict keys [dict get $config sessions]]]
                debug_log tool "current session: [dict get $config current_session]; sessions: $names"
                return 1
            }
            if {[llength $name] != 1} {
                debug_log error {usage: /session ?name?}
                return 1
            }
            if {[catch {switch_session $name} error]} {
                debug_log error "could not switch session: $error"
                return 1
            }
            debug_log tool "switched to session $name"
        }
        default {
            debug_log error "unknown command: /$command"
        }
    }
    return 1
}


proc ::featherweight::request_async {} {
    variable busy
    variable config
    variable curl_data
    variable json_tools
    variable request_channels

    if {!$busy} { return }
    set payload [json_payload [dict get $config model] $json_tools [current_messages]]
    debug_log request [pretty $payload]

    if {[catch {
        set ch [open |[list curl  --data-binary @- << $payload  --header "Authorization: Bearer [api_key]"  --header {Content-Type: application/json}  --request POST  --show-error  --silent  --write-out "\n%{http_code} %{exitcode} %{errormsg}"  [dict get $config endpoint]  ]]
    } error]} {
        debug_log error "could not start curl request: $error"
        set_ui_busy 0
        return
    }

    set curl_data($ch) {}
    set request_channels($ch) 1
    fconfigure $ch -blocking 0
    fileevent $ch readable [list [namespace current]::request_readable $ch]
}


proc ::featherweight::request_readable ch {
    variable busy
    variable curl_data
    variable request_channels

    if {!$busy || ![info exists request_channels($ch)]} { return }

    # Accumulate available output. Wait for EOF before parsing the response.
    if {[catch {read $ch} chunk]} {
        debug_log error "could not read curl response: $chunk"
        fileevent $ch readable {}
        unset -nocomplain curl_data($ch)
        unset request_channels($ch)
        catch {close $ch}
        set_ui_busy 0
        return
    }
    append curl_data($ch) $chunk
    if {![eof $ch]} {
        return
    }

    fileevent $ch readable {}
    set output $curl_data($ch)
    unset curl_data($ch)
    unset request_channels($ch)

    if {[catch {close $ch} error options]} {
        if {!$busy} { return }
        debug_log error "curl request failed: $error"
        set_ui_busy 0
        return
    }
    if {!$busy} { return }

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

    if {[catch {json::json2dict $data} response]} {
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
            if {!$busy} { return }
            debug_log tool "call: $call"
            ui_tool_code $call
            set result [call_tool $call]
            if {!$busy} { return }
            append_message $result
            ui_tool [dict get $result content]
        }
        request_async
        return
    }

    set_ui_busy 0


}


proc ::featherweight::on_close {} {
    variable busy
    variable done
    if {$busy} { stop }
    set done 1
}




proc ::featherweight::text_has_selection {w} {
    return [expr {[$w tag nextrange sel 1.0] ne {}}]
}


proc ::featherweight::text_copy w {
    if {![text_has_selection $w]} { return }
    clipboard clear -displayof $w
    clipboard append -displayof $w [$w get sel.first sel.last]
}


proc ::featherweight::text_cut w {
    if {![text_has_selection $w]} { return }
    text_copy $w
    $w delete sel.first sel.last
}


proc ::featherweight::text_paste w {
    if {[catch {clipboard get -displayof $w -type UTF8_STRING} text]} {
        if {[catch {clipboard get -displayof $w} text]} { return }
    }
    if {[text_has_selection $w]} {
        $w delete sel.first sel.last
    }
    $w insert insert $text
    $w see insert
}


proc ::featherweight::text_select_all w {
    $w tag remove sel 1.0 end
    $w tag add sel 1.0 end-1c
    $w mark set insert end-1c
    $w see insert
}


proc ::featherweight::show_text_context_menu {w x y editable} {
    variable W
    if {![dict exists $W context_menu]} {
        set menu .context_menu
        menu $menu -tearoff 0
        dict set W context_menu $menu
    } else {
        set menu [dict get $W context_menu]
    }
    $menu delete 0 end

    if {$editable} {
        $menu add command -label "Cut" -command [list [namespace current]::text_cut $w]
        $menu entryconfigure end -state [expr {[text_has_selection $w] ? "normal" : "disabled"}]
    }
    $menu add command -label "Copy" -command [list [namespace current]::text_copy $w]
    $menu entryconfigure end -state [expr {[text_has_selection $w] ? "normal" : "disabled"}]
    if {$editable} {
        $menu add command -label "Paste" -command [list [namespace current]::text_paste $w]
        if {[catch {clipboard get -displayof $w}]} {
            $menu entryconfigure end -state disabled
        } else {
            $menu entryconfigure end -state normal
        }
    }
    $menu add command -label "Select All" -command [list [namespace current]::text_select_all $w]
    $menu entryconfigure end -state [expr {[$w get 1.0 end-1c] eq {} ? "disabled" : "normal"}]

    $w mark set insert @$x,$y
    focus $w
    tk_popup $menu [expr {[winfo rootx $w] + $x}] [expr {[winfo rooty $w] + $y}]
}


proc ::featherweight::install_text_context_menu {w {editable 0}} {
    set command [list [namespace current]::show_text_context_menu $w %x %y $editable]
    bind $w <Button-3> $command
    bind $w <Control-Button-1> $command
}


proc ::featherweight::build_ui {} {
    variable W
    variable config

    catch {ttk::style theme use clam}

    update_window_title
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
    text .root.pane.chatf.body.t -wrap word -height 18 -width 80 -state disabled\
        -yscrollcommand {.root.pane.chatf.body.sb set}
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
    text .root.pane.dbgf.body.t -wrap word -height 8 -width 80 -state disabled\
        -font TkFixedFont -background #11161c -foreground #d6d6d6\
        -yscrollcommand {.root.pane.dbgf.body.sb set}
    ttk::scrollbar .root.pane.dbgf.body.sb -command {.root.pane.dbgf.body.t yview}
    grid .root.pane.dbgf.body.t .root.pane.dbgf.body.sb -sticky nsew
    grid rowconfigure .root.pane.dbgf.body 0 -weight 1
    grid columnconfigure .root.pane.dbgf.body 0 -weight 1
    .root.pane add .root.pane.dbgf -weight 2

    ttk::frame .root.input
    pack .root.input -fill x -pady {6 0}
    text .root.input.e -wrap word -height 4 -width 40 -undo 1
    bind .root.input.e <Control-Return> {::featherweight::submit; break}
    bind .root.input.e <Control-KP_Enter> {::featherweight::submit; break}
    ttk::button .root.input.send -text "Send" -command ::featherweight::submit_or_stop
    pack .root.input.send -side right -anchor n -padx {4 0}
    pack .root.input.e -side left -fill both -expand 1

    ttk::label .root.status -text "Ready" -anchor w
    pack .root.status -fill x

    set W [dict create\
        chat .root.pane.chatf.body.t\
        debug .root.pane.dbgf.body.t\
        entry .root.input.e\
        send .root.input.send\
        status .root.status]

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

    install_text_context_menu [dict get $W chat]
    install_text_context_menu [dict get $W debug]
    install_text_context_menu [dict get $W entry] 1
    focus [dict get $W entry]
}




proc ::featherweight::console_main {} {
    variable config
    variable json_tools
    variable tools_available

    set json_tools [lmap tool_args [dict values $tools_available]] {
        json_tool {*}$tool_args
    }]
    ::puts "Featherweight console mode (type a message; Ctrl-D to exit)"
    while {[gets stdin line] >= 0} {
        if {[string trim $line] eq {}} { continue }
        if {[handle_slash_command $line]} { continue }
        append_message [dict create role user content $line]
        console_turn
    }
}


proc ::featherweight::console_turn {} {
    variable config
    variable json_tools
    variable tok
    while 1 {
        set payload [json_payload [dict get $config model] $json_tools [current_messages]]
        debug_log request [pretty $payload]
        if {[catch {
            set tok [::http::geturl [dict get $config endpoint]\
                -method POST\
                -type application/json\
                -headers [list Authorization "Bearer [api_key]"]\
                -query $payload]
            set status [::http::ncode $tok]
            set data [::http::data $tok]
        } err]} {
            ::puts "Error: $err"
            return
        }
        catch {::http::cleanup $tok}
        if {$status != 200} {
            ::puts "Error: HTTP $status"
            debug_log error "HTTP $status: $data"
            return
        }
        if {[catch {json::json2dict $data} response]} {
            ::puts "Error: response was not valid JSON"
            return
        }
        if {![dict exists $response choices] || [llength [dict get $response choices]] == 0} {
            ::puts "Error: response had no choices"
            return
        }
        set choice [lindex [dict get $response choices] 0]
        set cleaned [clean_assistant_message [dict get $choice message]]
        if {[dict exists $cleaned content]} {
            ::puts "Assistant: [dict get $cleaned content]"
        }
        append_message $cleaned
        if {![dict exists $cleaned tool_calls]} { return }
        foreach call [dict get $cleaned tool_calls] {
            debug_log tool "call: $call"
            set result [call_tool $call]
            ::puts "Tool: [dict get $result content]"
            append_message $result
        }
    }
}


proc ::featherweight::main {argv0 argv} {
    variable config
    variable done
    variable json_tools
    variable tools_available

    init_config

    if {[catch {package require Tk} err]} {
        ::puts "Tk/display unavailable ($err); falling back to console mode."
        console_main
        return
    }

    set json_tools [lmap tool_args [dict values $tools_available] {
        json_tool {*}$tool_args
    }]

    if {[catch {build_ui} err]} {
        ::puts "Could not create UI ($err); falling back to console mode."
        catch {destroy .}
        console_main
        return
    }

    replay_messages
    debug_log tool "model: [dict get $config model]"
    debug_log tool "endpoint: [dict get $config endpoint]"

    vwait ::featherweight::done
    catch {destroy .}
}


# If this is the main script...
if {[info exists argv0] && ([file tail [info script]] eq [file tail $argv0])} {
    ::featherweight::main $argv0 $argv
}
