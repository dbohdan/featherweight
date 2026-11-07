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
    variable config {
        apiKeyEnvVar OPENROUTER_API_KEY
        endpoint https://openrouter.ai/api/v1/chat/completions
        model xiaomi/mimo-v2.6-flash
        systemPrompt {You are a helpful assistant.}
    }
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


proc ::featherweight::json-payload {model messages} {
    set jsonMessages [lmap message $messages {
        ::json::write object-strings {*}$message
    }]

    return [::json::write object \
        model [::json::write string $model] \
        messages [::json::write array {*}$jsonMessages] \
    ]
}


proc ::featherweight::main {argv0 argv} {
    variable config

    ::tls::init -tls1 1
    ::autoproxy::init

    ::http::register https 443 autoproxy::tls_socket

    set messages [list \
        [dict create role system content [dict get $config systemPrompt]] \
    ]

    while true {
        puts -nonewline {> }
        flush stdout

        gets stdin prompt

        lappend messages [dict create role user content $prompt]

        set payload [json-payload [dict get $config model] $messages]
        lassign [request $payload] status jsonResponse

        if {$status != 200} {
            puts "Error: Status $status"
        }

        try {
            set response [json::json2dict $jsonResponse]
        } on error e {
            puts "Error: Failed to decode JSON: [list $e]"
        }

        set responseMessage [dict get [lindex [dict get $response choices] 0] message]

        puts "Assistant: [dict get $responseMessage content]"

        lappend messages $responseMessage
    }
}


# If this is the main script...
if {[info exists argv0] && ([file tail [info script]] eq [file tail $argv0])} {
    ::featherweight::main $argv0 $argv
}
