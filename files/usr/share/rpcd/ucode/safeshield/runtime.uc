'use strict';

let core = require('core');
let fs = require('fs');

let PKG_NAME = core.PKG_NAME;
let STATUS_FILE = core.STATUS_FILE;
let SERVICE_INIT = core.SERVICE_INIT;
let read_json_file = core.read_json_file;
let to_bool = core.to_bool;
let reload_uci = core.reload_uci;
let cfg = core.cfg;

// Do not call ubus synchronously from an rpcd handler.  In particular,
// service.list may require the same event loop currently serving the caller.
// Use an independent ubus client with an upper time bound instead.
function service_instances(name) {
    // These are the only procd services queried by this module. Keeping the
    // argument allowlisted also prevents shell command injection.
    if (name != PKG_NAME && name != 'dnsmasq') {
        return null;
    }

    let pipe = fs.popen(sprintf("timeout 2 ubus call service list '{\"name\":\"%s\"}' 2>/dev/null", name), 'r');
    if (!pipe) {
        return null;
    }

    let output = pipe.read('all');
    pipe.close();
    if (!output) {
        return null;
    }

    let result = json(output);
    return result && result[name] && result[name].instances || null;
}

function service_running(name) {
    let instances = service_instances(name);
    if (!instances) {
        return false;
    }

    for (let inst_name, inst in instances) {
        if (inst.running) {
            return true;
        }
    }
    return false;
}

function service_instance_running(name, instance_name) {
    let instances = service_instances(name);
    return !!(instances && instances[instance_name] && instances[instance_name].running);
}

function dnsmasq_running() {
    return service_running('dnsmasq');
}

function run_service_action(action, timeout_ms) {
    let rc = system([ SERVICE_INIT, action ], timeout_ms || 60000);

    return {
        ok: rc == 0,
        rc: rc
    };
}

function refresh_running() {
    let state = read_json_file(STATUS_FILE, {});
    let data = state.data || {};

    return data.status == 'running';
}

function reset_statistics_upload_state() {
    fs.unlink('/tmp/safeshield/statistics/upload.credentials');
    fs.unlink('/tmp/safeshield/statistics/upload.entitlement');
    fs.unlink('/tmp/safeshield/statistics/upload.pending.json');
    fs.unlink('/tmp/safeshield/statistics/upload.pending.meta');
    fs.unlink('/tmp/safeshield/statistics/upload.state');
}

function start_refresh_async() {
    reload_uci();

    if (!to_bool(cfg('enabled', '0'), false)) {
        return {
            accepted: false,
            reason: 'disabled'
        };
    }

    if (!service_running(PKG_NAME)) {
        return {
            accepted: false,
            reason: 'service_stopped'
        };
    }

    if (refresh_running()) {
        return {
            accepted: false,
            reason: 'already_running'
        };
    }

    let rc = system([
        '/bin/sh',
        '-c',
        '/etc/init.d/safeshield refresh_once </dev/null >/dev/null 2>&1 &'
    ], 5000);

    return {
        accepted: rc == 0,
        reason: (rc == 0) ? '' : 'spawn_failed',
        rc: rc
    };
}

function start_local_apply_async() {
    reload_uci();

    if (!to_bool(cfg('enabled', '0'), false)) {
        return {
            accepted: false,
            reason: 'disabled'
        };
    }

    if (!to_bool(cfg('apply_local_overrides', '1'), true)) {
        return {
            accepted: false,
            reason: 'local_overrides_disabled'
        };
    }

    if (!service_running(PKG_NAME)) {
        return {
            accepted: false,
            reason: 'service_stopped'
        };
    }

    // The shell worker shares the refresh lock with full artifact refreshes.
    // It waits for an in-flight refresh and then merges the newest local rule
    // files against the retained api.block.txt cache. Duplicate workers are
    // harmless because the engine fingerprints the normalized local state.
    let rc = system([
        '/bin/sh',
        '-c',
        '/etc/init.d/safeshield apply_local_rules </dev/null >/dev/null 2>&1 &'
    ], 5000);

    return {
        accepted: rc == 0,
        reason: (rc == 0) ? '' : 'spawn_failed',
        rc: rc
    };
}

return {
    service_running: service_running,
    service_instance_running: service_instance_running,
    dnsmasq_running: dnsmasq_running,
    run_service_action: run_service_action,
    refresh_running: refresh_running,
    reset_statistics_upload_state: reset_statistics_upload_state,
    start_refresh_async: start_refresh_async,
    start_local_apply_async: start_local_apply_async
};
