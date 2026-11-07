#! /usr/bin/env tclsh

package require Tcl 8.6 9

package require autoproxy
package require http
package require json
package require json::write
package require tls 1.7


namespace eval ::featherweight {
    variable version 0.0.0

    # Configuration is embedded.
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
        tools [subst {
            run_code {
                -name run_code
                -description {Evaluate code in a stateless Tcl [info patchlevel] interp.\
                    Tcllib is available. You receive whatever the code writes to stdout/stderr; use puts to return results.}
                -param {code string {The code to evaluate.}}
                -required code
                -command ::featherweight::tool_run_code
            }
        }]
    ]
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


proc ::featherweight::tool_run_code arguments {
    variable config

    if {[dict get $config debug]} {
        debug_log tool "run_code $arguments"
    }

    try {
        set result [exec [info nameofexecutable] << [dict get $arguments code] 2>@1]
    } on error e {
        set result [list Error evaluating code: $e]
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
    variable msg_list {}
    variable json_tools {}
    variable user_input {}
    variable busy 0
    variable tok {}
    variable done 0
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
    variable msg_list
    variable busy
    variable user_input
    if {$busy} { return }
    set text [string trim $user_input]
    if {$text eq {}} { return }
    set user_input {}
    lappend msg_list [dict create role user content $text]
    ui_user $text
    set_ui_busy 1
    request_async
}


proc ::featherweight::clear {} {
    variable W
    variable config
    variable msg_list
    variable busy
    if {$busy} { return }
    set msg_list [list [dict create role system content [dict get $config system_prompt]]]
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
    variable msg_list
    variable json_tools
    variable tok
    set payload [json_payload [dict get $config model] $json_tools $msg_list]
    debug_log request [pretty $payload]
    set tok [::http::geturl [dict get $config endpoint]\
        -method POST\
        -type application/json\
        -headers [list Authorization "Bearer [api_key]"]\
        -query $payload\
        -command ::featherweight::on_response]
}


proc ::featherweight::on_response {token} {
    variable msg_list
    set status [::http::ncode $token]
    set data [::http::data $token]
    set tstatus [::http::status $token]
    catch {::http::cleanup $token}

    if {$tstatus ne {complete}} {
        debug_log error "request failed: status=$tstatus"
        set_ui_busy 0
        return
    }
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
        debug_log error "response has no choices"
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
    lappend msg_list $cleaned
    if {[dict exists $cleaned tool_calls]} {
        foreach call [dict get $cleaned tool_calls] {
            debug_log tool "call: $call"
            set result [call_tool $call]
            lappend msg_list $result
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

    focus [dict get $W entry]
}




proc ::featherweight::console_main {} {
    variable config
    variable msg_list
    variable json_tools
    ::tls::init -tls1 1
    ::autoproxy::init
    ::http::register https 443 autoproxy::tls_socket
    set json_tools [lmap tool_args [dict values [dict get $config tools]] {
        json_tool {*}$tool_args
    }]
    set msg_list [list [dict create role system content [dict get $config system_prompt]]]
    puts "featherweight console mode (type a message; Ctrl-D to exit)"
    while {[gets stdin line] >= 0} {
        if {[string trim $line] eq {}} { continue }
        lappend msg_list [dict create role user content $line]
        console_turn
    }
}


proc ::featherweight::console_turn {} {
    variable config
    variable msg_list
    variable json_tools
    variable tok
    while 1 {
        set payload [json_payload [dict get $config model] $json_tools $msg_list]
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
            puts "Error: $err"
            return
        }
        catch {::http::cleanup $tok}
        if {$status != 200} {
            puts "Error: HTTP $status"
            debug_log error "HTTP $status: $data"
            return
        }
        if {[catch {json::json2dict $data} response]} {
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
        lappend msg_list $cleaned
        if {![dict exists $cleaned tool_calls]} { return }
        foreach call [dict get $cleaned tool_calls] {
            debug_log tool "call: $call"
            set result [call_tool $call]
            puts "Tool: [dict get $result content]"
            lappend msg_list $result
        }
    }
}


proc ::featherweight::main {argv0 argv} {
    variable config
    variable msg_list
    variable json_tools
    variable done

    if {[catch {package require Tk} err]} {
        puts "Tk/display unavailable ($err); falling back to console mode."
        console_main
        return
    }

    ::tls::init -tls1 1
    ::autoproxy::init
    ::http::register https 443 autoproxy::tls_socket

    set json_tools [lmap tool_args [dict values [dict get $config tools]] {
        json_tool {*}$tool_args
    }]

    set msg_list [list [dict create role system content [dict get $config system_prompt]]]

    if {[catch {build_ui} err]} {
        puts "Could not create UI ($err); falling back to console mode."
        catch {destroy .}
        console_main
        return
    }

    debug_log tool "model: [dict get $config model]"
    debug_log tool "endpoint: [dict get $config endpoint]"

    vwait ::featherweight::done
    catch {destroy .}
}


# If this is the main script...
if {[info exists argv0] && ([file tail [info script]] eq [file tail $argv0])} {
    ::featherweight::main $argv0 $argv
}
