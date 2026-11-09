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
        model xiaomi/mimo-v2.6-flash \
        context_size 1048576 \
        system_prompt {You are an expert software developer working with a user on their code.
The user will ask for changes to the code, or ask questions about it.
If a request is ambiguous, ask clarifying questions before making changes.

You have tools for reading and editing files, running Tcl code, and learning about this process.
Prefer read_file, write_file, and edit_file for file operations.
Use run_code for other operations in the user's environment.} \
        \
        current_session default \
    ]

    # The sessions this process has read from disk: name -> messages. A session
    # not in here has not been looked at yet; see load_session.
    variable sessions [dict create]

    variable run_code_output {}
    variable tools_available [subst {
        run_code {
            -name run_code
            -description {Evaluate code in a stateful Tcl [info patchlevel] interp that the harness runs in. State persists between calls. Tcllib is available. You receive the return value plus whatever the code writes to stdout/stderr.}
            -param {code string {The code to evaluate.}}
            -required code
            -command ::featherweight::tool_run_code
        }
        read_file {
            -name read_file
            -description {Read a text file's contents with line numbers. Returns a window of the file; use offset and limit to page through a long one.}
            -param {path string {The file's path, relative to the project root. An absolute path also works; relative is preferred for project files.}}
            -param {offset integer {The first line to return, 1-based. Omit to start at the beginning.}}
            -param {limit integer {How many lines to return. Omit for a default window of 2000 lines.}}
            -required path
            -command ::featherweight::tool_read_file
        }
        write_file {
            -name write_file
            -description {Write a file with the given full contents, creating it or completely overwriting it if it already exists. Applies immediately. To change part of an existing file use edit_file instead; use this only when you are providing the whole file.}
            -param {path string {The file's path, relative to the project root. An absolute path also works; relative is preferred for project files.}}
            -param {content string {The complete contents of the file.}}
            -required {path content}
            -command ::featherweight::tool_write_file
        }
        edit_file {
            -name edit_file
            -description {Replace an exact span of text in a file. The edit applies immediately. Make one call per change; call it several times to make several changes.}
            -param {path string {The file's path, relative to the project root. An absolute path also works; relative is preferred for project files.}}
            -param {old_string string {The exact existing text to replace, character for character, including all whitespace, comments, and docstrings. It must match exactly once: include enough surrounding lines to pick out the one place you mean, and make a separate call for each place if you mean several.}}
            -param {new_string string {The text to put in its place.}}
            -param {replace_all boolean {Replace every occurrence of old_string instead of requiring exactly one. Default false. Use it when the same text should change everywhere in the file.}}
            -required {path old_string new_string}
            -command ::featherweight::tool_edit_file
        }
        about {
            -name about
            -description {Report facts about this Featherweight process: its version and script, when the process started, the current date and time, the Tcl and Tk versions, the platform, and this session's model and project root. Use it instead of inferring any of these.}
            -command ::featherweight::tool_about
        }
    }]
    variable process_started [clock seconds]
}


# The directory that holds the configuration and the sessions, relative to the
# project root (the launch directory).
proc ::featherweight::state_dir {} {
    return [file join [pwd] featherweight]
}


proc ::featherweight::config_path {} {
    return [file join [state_dir] config]
}


proc ::featherweight::sessions_dir {} {
    return [file join [state_dir] sessions]
}


# The file that holds one session. A session name doubles as its file name, so
# a name that is not a plain file name is refused here rather than escaping the
# sessions directory.
proc ::featherweight::session_path {name} {
    if {$name eq {}
            || $name in {. ..}
            || [file tail $name] ne $name
            || [string first "\\" $name] >= 0} {
        error "invalid session name \"$name\": a session name must be a plain file name, without path separators"
    }
    return [file join [sessions_dir] $name]
}


# Whether the session has a file. An unusable name has no session.
proc ::featherweight::session_exists {name} {
    if {[catch {session_path $name} path]} {
        return 0
    }
    return [file exists $path]
}


# The names of every session that has a file, sorted.
proc ::featherweight::session_names {} {
    set directory [sessions_dir]
    if {![file isdirectory $directory]} {
        return {}
    }

    set names {}
    foreach path [glob -nocomplain -directory $directory *] {
        if {![file isfile $path]} {
            continue
        }
        set name [file tail $path]
        if {![catch {session_path $name}]} {
            lappend names $name
        }
    }
    return [lsort $names]
}


# Read one session from its file, which holds a Tcl list of message dicts. A
# session with no file yet has no messages; a file that cannot be read or
# understood is an error rather than an empty session, so that a later save
# never overwrites it.
proc ::featherweight::read_session {name} {
    set path [session_path $name]
    if {![file exists $path]} {
        return {}
    }
    if {[catch {::fileutil::cat -encoding utf-8 $path} content options]} {
        error "could not load [list $path]: $content" {} [dict get $options -errorinfo]
    }
    if {[catch {llength $content} count]} {
        error "session in [list $path] is not a Tcl list"
    }
    for {set index 0} {$index < $count} {incr index} {
        set message [lindex $content $index]
        if {[catch {dict get $message role}]} {
            set shown [string range [list $message] 0 79]
            error "message $index in [list $path] is not a message dict: $shown"
        }
    }
    return $content
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

    if {![dict exists $config context_size]} {
        dict set config context_size 1048576
    }
    set context_size [dict get $config context_size]
    if {![string is integer -strict $context_size]
            || ($context_size != 0 && $context_size < 4096)} {
        error {context_size must be 0 (off) or an integer of at least 4096 tokens}
    }

    # The current session must name a session file; anything else starts over
    # at the default session.
    if {![dict exists $config current_session]
            || ![session_exists [dict get $config current_session]]} {
        dict set config current_session default
    }

    set system_message [dict create role system content [dict get $config system_prompt]]
    if {[llength [current_messages]] == 0} {
        set_current_messages [list $system_message]
    }
    save_config
}


# The session's messages, read from its file the first time this process needs
# them and kept in memory after that.
proc ::featherweight::load_session {name} {
    variable sessions

    if {![dict exists $sessions $name]} {
        dict set sessions $name [read_session $name]
    }
    return [dict get $sessions $name]
}


proc ::featherweight::current_session_name {} {
    variable config
    return [dict get $config current_session]
}


proc ::featherweight::current_messages {} {
    return [load_session [current_session_name]]
}


# Write one session back to its own file. A session this process has not read
# has nothing in memory to write, so it is left alone.
proc ::featherweight::save_session {name} {
    variable sessions

    if {![dict exists $sessions $name]} {
        return
    }

    set text {}
    foreach message [dict get $sessions $name] {
        append text [list $message] \n
    }

    set path [session_path $name]
    if {[catch {write_text_file $path $text} error]} {
        debug_log error "could not save [list $path]: $error"
    }
}


# Approximate tokens the same way Strument's RuneCounter does: Unicode code
# points divided by four. Count the wire representation so tool arguments and
# per-message overhead are not invisible to the context budget.
proc ::featherweight::estimate_tokens {text} {
    return [expr {[string length $text] / 4}]
}


proc ::featherweight::messages_tokens messages {
    set total 0
    foreach message $messages {
        incr total [estimate_tokens [json_message $message]]
    }
    return $total
}


proc ::featherweight::tools_tokens json_tools {
    return [estimate_tokens [::json::write array {*}$json_tools]]
}


proc ::featherweight::history_budget {} {
    variable config
    if {![dict exists $config context_size]} {
        return 0
    }
    set context_size [dict get $config context_size]
    if {![string is integer -strict $context_size] || $context_size <= 0} {
        return 0
    }
    return [expr {max($context_size / 2, 2048)}]
}


proc ::featherweight::context_report {} {
    variable config
    variable json_tools

    set size [dict get $config context_size]
    set history [messages_tokens [current_messages]]
    set tools [tools_tokens $json_tools]
    set total [expr {$history + $tools}]
    set report [format {Approximate request usage: %d tokens (%d history + %d tool schemas).} $total $history $tools]
    if {$size > 0} {
        append report [format "\nContext window: %d tokens; automatic compaction at %d history tokens." $size [history_budget]]
        append report [format "\nEstimated total usage: %.1f%% of the window." [expr {100.0 * $total / $size}]]
    } else {
        append report "\nAutomatic compaction is disabled."
    }
    return $report
}


proc ::featherweight::harness_note {text} {
    return [dict create role user content "\[featherweight\] $text"]
}


proc ::featherweight::is_harness_note message {
    return [expr {[dict get $message role] eq {user}
        && [string match {\[featherweight\]*} [dict get $message content]]}]
}


proc ::featherweight::user_texts messages {
    set texts {}
    foreach message $messages {
        if {[dict get $message role] eq {user} && ![is_harness_note $message]} {
            set text [string trim [dict get $message content]]
            if {$text ne {}} {
                lappend texts $text
            }
        }
    }
    return $texts
}


proc ::featherweight::roll_note texts {
    set text {Earlier turns of this session were dropped to keep it inside the context window. What the user said in them is kept below, word for word, oldest first. The work those turns did is not kept: where it matters, check the files or run the commands again.}
    foreach message $texts {
        append text "\n\n> [string map [list "\n" "\n> "] $message]"
    }
    return [harness_note $text]
}


proc ::featherweight::set_current_messages messages {
    variable config
    variable sessions

    set name [dict get $config current_session]
    dict set sessions $name $messages
    save_session $name
}


# Fold the current session's history so it fits the context budget; called
# before every request. With $force (/compact) it folds even when the history
# already fits, aiming at half of what is there instead of at half the budget,
# and never higher than the automatic target -- so a forced fold cannot leave
# the session over a window the automatic rule would have respected.
proc ::featherweight::compact_context {{force 0}} {
    set messages [current_messages]
    set before [messages_tokens $messages]
    set budget [history_budget]
    if {!$force && ($budget == 0 || $before <= $budget)} {
        return 0
    }

    if {$force} {
        set target [expr {$before / 2}]
        if {$budget > 0} {
            set target [expr {min($target, $budget / 2)}]
        }
    } else {
        set target [expr {$budget / 2}]
    }

    # Keep the system prompt outside the fold. Every other genuine user message
    # begins a turn, so cutting there cannot orphan a tool call from its result.
    set starts {}
    for {set index 1} {$index < [llength $messages]} {incr index} {
        set message [lindex $messages $index]
        if {[dict get $message role] eq {user} && ![is_harness_note $message]} {
            lappend starts $index
        }
    }

    set said {}
    set cut -1
    set note {}
    foreach index $starts {
        set candidate_said [concat $said [user_texts [lrange $messages 1 $index-1]]]
        set candidate_note [roll_note $candidate_said]
        set tail [lrange $messages $index end]
        if {[messages_tokens [list $candidate_note {*}$tail]] <= $target} {
            set cut $index
            set said $candidate_said
            set note $candidate_note
            break
        }
    }
    if {$cut < 0 && [llength $starts] > 0} {
        # Even one turn may exceed the target. Keep the latest turn whole rather
        # than destroying its context or repeatedly folding on every request.
        set cut [lindex $starts end]
        set said [user_texts [lrange $messages 1 $cut-1]]
        set note [roll_note $said]
    }
    if {$cut < 0} {
        if {$force} {
            debug_log tool {context not folded: the session has no user turn to cut at}
        }
        return 0
    }

    set before_count [llength $messages]
    set compacted [list [lindex $messages 0] $note {*}[lrange $messages $cut end]]
    set after [messages_tokens $compacted]
    if {$after >= $before} {
        if {$force} {
            debug_log tool "context not folded: keeping the latest turn whole\
                and quoting the user's words verbatim would leave approximately\
                $after tokens, at least as many as the $before it has now"
        }
        return 0
    }
    set_current_messages $compacted
    set label {compacted history}
    if {$force} {
        set label {folded on request}
    }
    debug_log tool "$label: dropped [expr {$cut - 1}] of [expr {$before_count - 1}] messages ($before -> $after tokens); user messages kept verbatim"
    refresh_session
    return 1
}


proc ::featherweight::prepare_request {} {
    variable config
    variable json_tools

    compact_context
    set size [dict get $config context_size]
    set history [messages_tokens [current_messages]]
    set tools [tools_tokens $json_tools]
    set total [expr {$history + $tools}]
    if {$size > 0 && $total > $size} {
        error "estimated request is $total tokens, over the configured context_size of $size; start a new session or increase /context-size"
    }
    return [current_messages]
}


# Write the configuration. Sessions are not part of it: each one is written to
# its own file by save_session, so this file stays small however long the
# conversations grow.
proc ::featherweight::save_config {} {
    variable config

    set path [config_path]
    set text {}
    dict for {key value} $config {
        append text [list $key $value] \n
    }

    if {[catch {write_text_file $path $text} error]} {
        debug_log error "could not save [list $path]: $error"
    }
}


proc ::featherweight::append_message message {
    variable config
    variable sessions

    set name [dict get $config current_session]
    load_session $name
    dict lappend sessions $name $message

    save_session $name
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
        || [lsort [dict keys $args]] ni {
            {-command -description -name}
            {-command -description -name -param}
            {-command -description -name -param -required}
        }} {
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


proc ::featherweight::require_tool_arguments {arguments names} {
    foreach name $names {
        if {![dict exists $arguments $name]} {
            return -code error "The required \"$name\" argument was missing."
        }
    }
}


proc ::featherweight::read_text_file path {
    set channel [open $path r]
    if {[catch {
        fconfigure $channel -encoding utf-8 -translation lf
        read $channel
    } result]} {
        catch {close $channel}
        return -code error $result
    }
    close $channel
    return $result
}


proc ::featherweight::write_text_file {path content} {
    file mkdir [file dirname $path]
    set temporary "$path.[pid].[clock clicks].tmp"
    set channel {}

    if {[catch {
        set channel [open $temporary w]
        fconfigure $channel -encoding utf-8 -translation lf
        puts -nonewline $channel $content
        close $channel
        set channel {}
        if {$::tcl_platform(platform) ne {windows} && [file exists $path]} {
            file attributes $temporary -permissions [file attributes $path -permissions]
        }
        file rename -force $temporary $path
    } error options]} {
        if {$channel ne {}} {
            catch {close $channel}
        }
        catch {file delete -force $temporary}
        return -options $options $error
    }
}


proc ::featherweight::tool_read_file arguments {
    require_tool_arguments $arguments path
    set path [dict get $arguments path]
    if {[string trim $path] eq {}} {
        return {The required "path" argument was missing.}
    }

    set offset 1
    if {[dict exists $arguments offset]} {
        set offset [dict get $arguments offset]
    }
    if {![string is integer -strict $offset] || $offset < 1} {
        return {The "offset" argument must be a positive line number.}
    }

    set limit 2000
    if {[dict exists $arguments limit]} {
        set limit [dict get $arguments limit]
    }
    if {![string is integer -strict $limit] || $limit < 1} {
        return {The "limit" argument must be a positive number of lines.}
    }

    if {[catch {read_text_file $path} content]} {
        return "Could not read \"$path\": $content"
    }

    set content [string map {"\r\n" "\n"} $content]
    if {$content eq {}} {
        set lines {}
    } else {
        set lines [split $content \n]
        if {[string index $content end] eq "\n"} {
            set lines [lrange $lines 0 end-1]
        }
    }

    set total [llength $lines]
    set output "$path ($total lines)\n"
    if {$offset > $total} {
        append output "\nLine $offset is past the end of the file.\n"
        return $output
    }

    set first [expr {$offset - 1}]
    set last [expr {min($first + $limit - 1, $total - 1)}]
    set width [string length [expr {$last + 1}]]
    for {set index $first} {$index <= $last} {incr index} {
        append output [format "%*d\u2192%s\n" $width [expr {$index + 1}] [lindex $lines $index]]
    }

    if {$last < $total - 1} {
        set next [expr {$last + 2}]
        append output "\n(Lines $offset-[expr {$last + 1}] of $total. Read from offset $next for more.)\n"
    }
    return $output
}


proc ::featherweight::tool_write_file arguments {
    require_tool_arguments $arguments {path content}
    set path [dict get $arguments path]
    if {[string trim $path] eq {}} {
        return {The required "path" argument was missing.}
    }

    set existed [file exists $path]
    if {[catch {write_text_file $path [dict get $arguments content]} error]} {
        return "Could not write \"$path\": $error"
    }
    return "[expr {$existed ? {Overwrote} : {Created}}] \"$path\"."
}


proc ::featherweight::tool_edit_file arguments {
    require_tool_arguments $arguments {path old_string new_string}
    set path [dict get $arguments path]
    if {[string trim $path] eq {}} {
        return {The required "path" argument was missing.}
    }

    set replace_all 0
    if {[dict exists $arguments replace_all]} {
        set replace_all [dict get $arguments replace_all]
        if {![string is boolean -strict $replace_all]} {
            return {The "replace_all" argument must be a boolean.}
        }
    }
    set old [dict get $arguments old_string]
    if {$old eq {}} {
        return {The "old_string" argument must not be empty; use write_file to replace the whole file.}
    }

    if {[catch {read_text_file $path} content]} {
        return "Could not read \"$path\": $content"
    }
    set count [expr {[string length $content] - [string length [string map [list $old {}] $content]]}]
    set count [expr {$count / [string length $old]}]

    if {$count == 0} {
        return "The search text was not found in \"$path\", so no change was made. It must match the current file contents exactly, character for character, including all whitespace, comments, and docstrings."
    }
    if {!$replace_all && $count != 1} {
        return "The text to replace appears $count times in \"$path\", so it is ambiguous and nothing was changed. Include enough surrounding text to match exactly once, or use \"replace_all\": true."
    }

    set content [string map [list $old [dict get $arguments new_string]] $content]
    if {[catch {write_text_file $path $content} error]} {
        return "Could not write \"$path\": $error"
    }
    if {$replace_all} {
        return "Replaced $count occurrence[expr {$count == 1 ? {} : {s}}] in \"$path\"."
    }
    return "Applied the edit to \"$path\"."
}


proc ::featherweight::tool_about arguments {
    variable version
    variable process_started
    variable config

    set now [clock seconds]
    set script [file normalize [info script]]
    set tk_version [expr {[catch {package present Tk} version] ? {unavailable} : $version}]
    set lines [list  Featherweight  "Version: $version"  "Script: $script"  "Script modified: [clock format [file mtime $script] -format {%Y-%m-%d %H:%M:%S UTC} -gmt 1]"  "Process started: [clock format $process_started -format {%Y-%m-%d %H:%M:%S UTC} -gmt 1]"  {}  Time  "Now (UTC): [clock format $now -format {%Y-%m-%d %H:%M:%S UTC, %A} -gmt 1]"  "Now (local): [clock format $now -format {%Y-%m-%d %H:%M:%S %Z}]"  {}  System  "Tcl: [info patchlevel]"  "Tk: $tk_version"  "OS: $::tcl_platform(os)"  "OS version: $::tcl_platform(osVersion)"  "Architecture: $::tcl_platform(machine)"  "Platform: $::tcl_platform(platform)"  {}  Session  "Model: [dict get $config model]"  "Current session: [dict get $config current_session]"  "Project root: [pwd]"  ]
    return [join $lines \n]\n
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
    variable sessions

    if {$name eq {}} {
        error {session name cannot be empty}
    }
    # Validates the name before anything is created or written.
    session_path $name

    # An existing session is loaded only now that it is about to be shown.
    if {[llength [load_session $name]] == 0} {
        dict set sessions $name [list \
            [dict create \
                role system \
                content [dict get $config system_prompt] \
            ] \
        ]
        save_session $name
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
        context-size {
            set value [string tolower [string trim $arguments]]
            if {$value eq {}} {
                debug_log tool [context_report]
                return 1
            }
            if {$value ni {off} && (![string is integer -strict $value] || $value < 4096)} {
                debug_log error {usage: /context-size ?tokens|off? (tokens must be at least 4096)}
                return 1
            }
            if {$value ne {off} && [llength $value] != 1} {
                debug_log error {usage: /context-size ?tokens|off? (tokens must be at least 4096)}
                return 1
            }
            if {$value eq {off}} {
                set value 0
            }
            dict set config context_size $value
            save_config
            debug_log tool [context_report]
        }
        compact {
            if {[string trim $arguments] ne {}} {
                debug_log error {usage: /compact}
                return 1
            }
            # Folds now, even when the history already fits the context budget.
            compact_context 1
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
                set names [session_names]
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
    if {[catch {prepare_request} messages]} {
        debug_log error $messages
        set_ui_busy 0
        return
    }
    set payload [json_payload [dict get $config model] $json_tools $messages]
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
        if {[catch {prepare_request} messages]} {
            ::puts "Error: $messages"
            return
        }
        set payload [json_payload [dict get $config model] $json_tools $messages]
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

    set json_tools {}
    dict for {_name tool_args} $tools_available {
        lappend json_tools [json_tool {*}$tool_args]
    }

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
