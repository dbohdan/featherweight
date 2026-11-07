#! /usr/bin/env tclsh

package require Tcl 8.6 9

package require autoproxy
package require http
package require json::write
package require tls 1.7


namespace eval ::featherweight {
    variable version 0.0.0

    # Configuration is embedded.
    variable config {
        apiKeyEnvVar OPENROUTER_API_KEY
        endpoint https://openrouter.ai/api/v1/responses
        model openai/gpt-5.2
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


proc ::featherweight::main {argv0 argv} {
    variable config

    ::tls::init -tls1 1
    ::autoproxy::init

    ::http::register https 443 autoproxy::tls_socket

    set payload [::json::write object \
        model [::json::write string [dict get $config model]] \
        instructions [::json::write string {You are a helpful assistant.}] \
        input [::json::write string Hello!] \
    ]

    puts [request $payload]
}


# If this is the main script...
if {[info exists argv0] && ([file tail [info script]] eq [file tail $argv0])} {
    ::featherweight::main $argv0 $argv
}
