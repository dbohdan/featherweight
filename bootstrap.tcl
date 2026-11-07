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
        apiKeyEnvVar OPENROUTER_API_KEY \
        endpoint https://openrouter.ai/api/v1/chat/completions \
        model xiaomi/mimo-v2.6-flash \
        systemPrompt {You are an expert software developer working with a user on their code.
The user will ask for changes to the code, or ask questions about it.
If a request is ambiguous, ask clarifying questions before making changes.

You have one tool available: run_code.
Use it as a window into the user's environment.} \
        \
        tools [subst {
            run_code {
                -name run_code
                -description {Evaluate code in a stateless Tcl [info patchlevel] interp.\
                    Tcllib is available. You will receive the return value of the code.}
                -param {code string {The code to evaluate.}}
                -required code
                -command ::featherweight::tool-run-code
            }
        }]
    ]
}


proc ::featherweight::get-env {name {default %UNSET%}} {
    if {![info exists ::env($name)]} {
        if {$default ne {%UNSET%}} {
            return $default
        }

        error "environment variable [list $name] unset"
    }

    return $::env($name)
}


proc ::featherweight::api-key {} {
    variable config

    return [get-env [dict get $config apiKeyEnvVar]]
}


proc ::featherweight::request payload {
    variable config

    try {
        set token [::http::geturl [dict get $config endpoint]  \
            -method POST \
            -type application/json \
            -headers [list Authorization "Bearer [api-key]"] \
            -query $payload \
        ]

        return [list [::http::ncode $token] [::http::data $token]]
    } finally {
        catch {
            ::http::cleanup $token
        }
    }
}


proc ::featherweight::json-tool args {
    if {[llength $args] % 2 != 0
        || [lsort [dict keys $args]] ne {-command -description -name -param -required}} {
        error {wrong # args: should be\
            "::featherweight::json-tool -command command -name name\
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

                lassign $value property type paramDescription

                if {[dict exists $properties $property]} {
                    error "duplicate parameter: $property"
                }

                dict set properties $property [list $type $paramDescription]
            }

            default {
                error "unknown option: $option"
            }
        }
    }

    set jsonProperties {}
    dict for {property schema} $properties {
        lassign $schema type paramDescription
        lappend jsonProperties $property [::json::write object \
            type [::json::write string $type] \
            description [::json::write string $paramDescription] \
        ]
    }

    set jsonRequired {}
    foreach property $required {
        lappend jsonRequired [::json::write string $property]
    }

    set parameters [::json::write object \
        type [::json::write string object] \
        properties [::json::write object {*}$jsonProperties] \
        required   [::json::write array {*}$jsonRequired] \
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

proc ::featherweight::json-payload {model jsonTools messages} {
    set jsonMessages [lmap message $messages {
        ::json::write object-strings {*}$message
    }]

    return [::json::write object \
        model [::json::write string $model] \
        messages [::json::write array {*}$jsonMessages] \
        tools [::json::write array {*}$jsonTools] \
        tool_choice auto \
    ]
}


proc ::featherweight::tool-run-code arguments {
    variable config

    if {[dict get $config debug]} {
        puts stderr [list $arguments]
    }

    try {
        set i [interp create]
        set result [interp eval $i [dict get $arguments code]]
        interp delete $i
    } on error e {
        set result [list Error evaluating code: $e]
    }

    return $result
}


proc ::featherweight::call-tool toolCall {
    variable config

    set type [dict get $toolCall type]
    if {$type ne {function}} {
        puts "Error: unknown tool call type: [list $type]"
        continue
    }

    set id [dict get $toolCall id]
    set function [dict get $toolCall function]
    set name [dict get $function name]
    set arguments [dict get $function arguments]

    if {![dict exists [dict get $config tools] $name]} {
        puts "Error: unknown tool name: [list $name]"
    }

    set command [dict get $config tools $name -command]
    set result [{*}$command [::json::json2dict $arguments]]

    return [dict create \
        role tool \
        tool_call_id $id \
        content $result \
    ]
}


proc ::featherweight::main {argv0 argv} {
    variable config

    ::tls::init -tls1 1
    ::autoproxy::init

    ::http::register https 443 autoproxy::tls_socket

    set jsonTools [lmap toolArgs [dict values [dict get $config tools]] {
        json-tool {*}$toolArgs
    }]

    set messages [list \
        [dict create role system content [dict get $config systemPrompt]] \
    ]

    set userInput true

    while true {
        if {$userInput} {
            puts -nonewline {User: }
            flush stdout

            gets stdin prompt

            lappend messages [dict create role user content $prompt]
        }
        set userInput true

        set payload [json-payload [dict get $config model] $jsonTools $messages]
        lassign [request $payload] status rawResponse

        if {$status != 200} {
            set errorMessage "Error: Status $status"
            if {[dict get $config debug]} {
                append errorMessage " ($rawResponse)"
            }

            continue
        }

        if {[dict get $config debug]} {
            puts stderr [exec jq . << $rawResponse]
        }

        try {
            set response [json::json2dict $rawResponse]
        } on error e {
            puts "Error: Failed to decode JSON: [list $e]"

            continue
        }

        set responseMessage [dict get [lindex [dict get $response choices] 0] message]
        set answer [dict get $responseMessage content]

        if {$answer ne {null}} {
            puts "Assistant: [dict get $responseMessage content]"
        }

        lappend messages $responseMessage

        if {[dict exists $responseMessage tool_calls]} {
            set toolCalls [dict get $responseMessage tool_calls]

            foreach toolCall $toolCalls {
                lappend messages [call-tool $toolCall]

                if {[dict get $config debug]} {
                    puts stderr $messages
                }

                set userInput false
            }
        }
    }
}


# If this is the main script...
if {[info exists argv0] && ([file tail [info script]] eq [file tail $argv0])} {
    ::featherweight::main $argv0 $argv
}
