#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# Generate full configs, including independent URLTest and Priority selectors.
# The second section must keep the default even when the first opts out.
for value in absent empty 0 1 false true; do
  fixture="$WORK_DIR/$value.json"
  output="$WORK_DIR/$value-config.json"
  ucode -e '
let fs = require("fs");
let section = {
    ".name": "proxy", ".type": "section", enabled: "1", action: "connection",
    selector_proxy_links: ["socks5://example.com:1080#first"]
};
let value = ARGV[0];
if (value != "absent")
    section.selector_interrupt_exist_connections = value == "empty" ? "" : value;
let fixture = {
    settings: { ".name": "settings", ".type": "settings", log_level: "warn" },
    section: [section, {
        ".name": "other", ".type": "section", enabled: "1", action: "connection",
        selector_proxy_links: ["socks5://example.org:1080#second"]
    }],
    urltest: [{
        ".name": "fast", ".type": "urltest", section: "proxy", name: "Fast",
        interrupt_exist_connections: "0"
    }, {
        ".name": "stable", ".type": "urltest", section: "proxy", name: "Stable",
        interrupt_exist_connections: "1"
    }],
    priority_group: [{
        ".name": "fallback", ".type": "priority_group", section: "proxy",
        name: "Fallback", interrupt_exist_connections: "0"
    }],
    priority_level: [{
        ".name": "primary", ".type": "priority_level", group: "fallback",
        name: "Primary", order: "10", filter_mode: "disabled"
    }]
};
fs.writefile(ARGV[1], sprintf("%J", fixture));
' "$value" "$fixture"
  mkdir -p "$output.section-cache"
  ucode -L "$FORKOP_LIB" "$FORKOP_LIB/singbox/generator.uc" generate-config-fixture \
    "$fixture" "$output" "127.0.0.1"
  ucode -e '
let fs = require("fs");
let cfg = json(fs.readfile(ARGV[0]));
let by_tag = {};
for (let outbound in cfg.outbounds || [])
    by_tag[outbound.tag] = outbound;
let value = ARGV[1];
let expected = value != "0" && value != "false";
function assert_flag(tag, flag) {
    if (!by_tag[tag] || by_tag[tag].interrupt_exist_connections !== flag)
        die(sprintf("%s: unexpected interrupt flag for %s\n", value, tag));
}
assert_flag("proxy-out", expected);
assert_flag("other-out", true);
assert_flag("proxy-urltest-fast-out", false);
assert_flag("proxy-urltest-stable-out", true);
assert_flag("proxy-priority-fallback-out", false);
if (by_tag["proxy-out"].default != "proxy-urltest-fast-out")
    die("selector default changed\n");
if (index(by_tag["proxy-out"].outbounds, "proxy-priority-fallback-out") < 0)
    die("priority group missing from section selector\n");
' "$output" "$value"
done

printf 'Section selector interrupt checks passed\n'
