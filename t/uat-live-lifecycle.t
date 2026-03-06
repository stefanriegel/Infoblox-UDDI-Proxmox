#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

# Skip entire test unless explicitly enabled -- this hits the REAL Infoblox API
plan skip_all => 'Set INFOBLOX_LIVE_TEST=1 to run live UAT tests'
    unless $ENV{INFOBLOX_LIVE_TEST};

# --- Credentials (env vars with hardcoded test-environment fallbacks) ---

my $INFOBLOX_URL   = $ENV{INFOBLOX_URL}      // 'https://csp.eu.infoblox.com';
my $INFOBLOX_TOKEN = $ENV{INFOBLOX_TOKEN}     // '9d69628b27041350d4bc8b01b7d80f1e6f6543a02c874b38ac6c13064b7a0165';
my $INFOBLOX_SPACE = $ENV{INFOBLOX_IP_SPACE}  // 'proxmox';

# --- Real HTTP implementation (replaces mock) ---

use HTTP::Tiny;
use JSON::PP;

my $http = HTTP::Tiny->new(verify_SSL => 1);

use lib 't/lib';
use lib 'src';

# Load the SDN stub first (provides the api_request sub we'll override)
require PVE::Network::SDN;

# Override api_request with real HTTP calls BEFORE loading plugins
{
    no warnings 'redefine';
    *PVE::Network::SDN::api_request = sub {
        my ($method, $url, $headers, $params) = @_;

        my %header_hash;
        for (my $i = 0; $i < scalar(@$headers); $i += 2) {
            $header_hash{$headers->[$i]} = $headers->[$i + 1];
        }

        my %options = (headers => \%header_hash);
        if ($params && ($method eq 'POST' || $method eq 'PATCH' || $method eq 'PUT')) {
            $options{content} = encode_json($params);
        }

        my $response = $http->request($method, $url, \%options);
        if (!$response->{success}) {
            die "HTTP $response->{status}: $response->{content}\n";
        }

        return $response->{content} ? decode_json($response->{content}) : undef;
    };
}

# Now load the plugins (they call 'use base' which triggers SDN loading)
use_ok('PVE::Network::SDN::Ipams::InfobloxPlugin')
    or BAIL_OUT('Cannot load IPAM InfobloxPlugin');
use_ok('PVE::Network::SDN::Dns::InfobloxPlugin')
    or BAIL_OUT('Cannot load DNS InfobloxPlugin');

# --- Configs ---

my $ipam_config = {
    url      => $INFOBLOX_URL,
    token    => $INFOBLOX_TOKEN,
    ip_space => $INFOBLOX_SPACE,
};

my $dns_config = {
    url      => $INFOBLOX_URL,
    token    => $INFOBLOX_TOKEN,
    dns_view => undef,  # will be set during discovery
};

# --- Helper: URL-encode a string ---

sub _uri_encode {
    my ($str) = @_;
    $str =~ s/([^A-Za-z0-9\-._~])/ sprintf("%%%02X", ord($1)) /ge;
    return $str;
}

# --- Helper: direct API call (bypasses plugin, used for verification + cleanup) ---

sub raw_api {
    my ($method, $path, $params) = @_;

    # URL-encode query parameter values (same fix as the plugins)
    if ($path =~ /^([^?]*)\?(.+)$/) {
        my ($base, $query) = ($1, $2);
        my @encoded;
        for my $pair (split(/&/, $query)) {
            if ($pair =~ /^([^=]+)=(.*)$/) {
                push @encoded, "$1=" . _uri_encode($2);
            } else {
                push @encoded, $pair;
            }
        }
        $path = $base . '?' . join('&', @encoded);
    }

    my $url = "${INFOBLOX_URL}/api/ddi/v1${path}";
    my %headers = (
        'Content-Type'  => 'application/json; charset=UTF-8',
        'Authorization' => "Token $INFOBLOX_TOKEN",
    );

    my %options = (headers => \%headers);
    if ($params && ($method eq 'POST' || $method eq 'PATCH' || $method eq 'PUT')) {
        $options{content} = encode_json($params);
    }

    my $response = $http->request($method, $url, \%options);
    if (!$response->{success}) {
        die "raw_api $method $path: HTTP $response->{status}: $response->{content}\n";
    }

    return $response->{content} ? decode_json($response->{content}) : undef;
}

# --- State to track for cleanup ---

my $allocated_ip;
my $space_id;
my $forward_zone;
my $reverse_zone;

# --- Cleanup handler: runs even if test dies mid-way ---

END {
    if ($allocated_ip && $space_id) {
        diag("=== CLEANUP: ensuring no leftover test data ===");

        # Clean up DNS A record (use name+type filter only -- view EQ not allowed)
        if ($forward_zone) {
            eval {
                my $fqdn = "uat-test-vm.${forward_zone}.";
                my $result = raw_api('GET',
                    "/dns/record?_filter="
                    . "absolute_name_spec==\"$fqdn\""
                    . " and type==\"A\"");
                if ($result && $result->{results} && @{$result->{results}}) {
                    my $id = $result->{results}->[0]->{id};
                    raw_api('DELETE', "/$id");
                    diag("  Cleaned up A record: $fqdn");
                }
            };
            warn "  Cleanup A record failed: $@" if $@;
        }

        # Clean up DNS PTR record
        if ($reverse_zone && $allocated_ip) {
            eval {
                require Net::IP;
                my $reverse_ip = Net::IP->new($allocated_ip)->reverse_ip();
                my $result = raw_api('GET',
                    "/dns/record?_filter="
                    . "absolute_name_spec==\"$reverse_ip\""
                    . " and type==\"PTR\"");
                if ($result && $result->{results} && @{$result->{results}}) {
                    my $id = $result->{results}->[0]->{id};
                    raw_api('DELETE', "/$id");
                    diag("  Cleaned up PTR record: $reverse_ip");
                }
            };
            warn "  Cleanup PTR record failed: $@" if $@;
        }

        # Clean up IPAM address
        eval {
            my $result = raw_api('GET',
                "/ipam/address?_filter=address==\"$allocated_ip\" and space==\"$space_id\"");
            if ($result && $result->{results} && @{$result->{results}}) {
                my $id = $result->{results}->[0]->{id};
                raw_api('DELETE', "/$id");
                diag("  Cleaned up IPAM address: $allocated_ip");
            }
        };
        warn "  Cleanup IPAM address failed: $@" if $@;

        diag("=== CLEANUP complete ===");
    }
}

# ============================================================================
# Phase 0: Connectivity pre-checks and discovery
# ============================================================================

subtest 'Phase 0: Connectivity and discovery' => sub {

    # Test IPAM plugin reachability + auth + IP Space
    eval {
        PVE::Network::SDN::Ipams::InfobloxPlugin->on_update_hook($ipam_config);
    };
    ok(!$@, 'IPAM on_update_hook succeeds (API reachable, auth valid, IP Space exists)')
        or BAIL_OUT("IPAM connectivity failed: $@");

    # Resolve IP Space name to ID
    my $space_result = raw_api('GET',
        "/ipam/ip_space?_filter=name==\"$INFOBLOX_SPACE\"");
    ok($space_result && $space_result->{results} && @{$space_result->{results}},
        'IP Space resolved')
        or BAIL_OUT("Cannot resolve IP Space '$INFOBLOX_SPACE'");

    $space_id = $space_result->{results}->[0]->{id};
    diag("IP Space: $INFOBLOX_SPACE => $space_id");

    # Discover subnets in this IP Space
    my $subnet_result = raw_api('GET',
        "/ipam/subnet?_filter=space==\"$space_id\"");
    ok($subnet_result && $subnet_result->{results} && @{$subnet_result->{results}},
        'At least one subnet exists in IP Space')
        or BAIL_OUT("No subnets found in IP Space '$INFOBLOX_SPACE'");

    my $test_subnet = $subnet_result->{results}->[0];
    my $subnet_address = $test_subnet->{address};
    my $subnet_cidr_prefix = $test_subnet->{cidr};
    my $subnet_cidr = "${subnet_address}/${subnet_cidr_prefix}";
    diag("Using subnet: $subnet_cidr (id: $test_subnet->{id})");

    # Store subnet info for later phases
    $main::test_subnet_cidr    = $subnet_cidr;
    $main::test_subnet_address = $subnet_address;
    $main::test_subnet_prefix  = $subnet_cidr_prefix;

    # Discover DNS views -- prefer "default" view, then try others
    my $view_result = raw_api('GET', '/dns/view');
    ok($view_result && $view_result->{results} && @{$view_result->{results}},
        'At least one DNS view exists')
        or BAIL_OUT("No DNS views found");

    my $chosen_view;
    my $chosen_view_id;
    for my $v (@{$view_result->{results}}) {
        if ($v->{name} eq 'default') {
            $chosen_view    = $v->{name};
            $chosen_view_id = $v->{id};
            last;
        }
    }
    # Fallback: use first view if "default" not found
    if (!$chosen_view) {
        $chosen_view    = $view_result->{results}->[0]->{name};
        $chosen_view_id = $view_result->{results}->[0]->{id};
    }
    diag("DNS View: $chosen_view => $chosen_view_id");

    # Update dns_config with discovered view name
    $dns_config->{dns_view} = $chosen_view;

    # Discover writable forward zone in this view
    my $zone_result = raw_api('GET',
        "/dns/auth_zone?_filter=view==\"$chosen_view_id\"");
    ok($zone_result && $zone_result->{results} && @{$zone_result->{results}},
        'At least one auth zone exists in chosen view')
        or BAIL_OUT("No auth zones found in view '$chosen_view'");

    # Find first writable forward zone (skip reverse zones and read-only zones)
    for my $z (@{$zone_result->{results}}) {
        my $fqdn = $z->{fqdn};
        next if $fqdn =~ /in-addr\.arpa|ip6\.arpa/i;
        # Skip read-only zones (synced from cloud providers)
        if ($z->{external_providers_metadata}
            && ref($z->{external_providers_metadata}) eq 'HASH'
            && $z->{external_providers_metadata}->{sync_read_only}) {
            diag("  Skipping read-only zone: $fqdn");
            next;
        }
        $forward_zone = $fqdn;
        # Strip trailing dot for plugin methods
        $forward_zone =~ s/\.$//;
        last;
    }
    ok($forward_zone, "Found writable forward zone: $forward_zone")
        or BAIL_OUT("No writable forward DNS zone found");
    diag("Forward zone: $forward_zone");

    # Test DNS plugin reachability
    eval {
        PVE::Network::SDN::Dns::InfobloxPlugin->on_update_hook($dns_config);
    };
    ok(!$@, 'DNS on_update_hook succeeds')
        or BAIL_OUT("DNS connectivity failed: $@");

    # Verify zone
    eval {
        PVE::Network::SDN::Dns::InfobloxPlugin->verify_zone($dns_config, $forward_zone, 0);
    };
    ok(!$@, "verify_zone succeeds for $forward_zone")
        or BAIL_OUT("verify_zone failed: $@");

    diag("--- Phase 0 discovery complete ---");
};

# ============================================================================
# Phase 1: Allocate IP (simulating VM creation)
# ============================================================================

subtest 'Phase 1: Allocate IP via add_next_freeip' => sub {

    my $subnet = {
        cidr    => $main::test_subnet_cidr,
        mask    => $main::test_subnet_prefix,
        network => $main::test_subnet_address,
        zone    => $forward_zone,
    };

    # Verify subnet first (plugin method)
    eval {
        PVE::Network::SDN::Ipams::InfobloxPlugin->add_subnet(
            $ipam_config, 'test-subnetid', $subnet, 0);
    };
    ok(!$@, "add_subnet verification passes for $main::test_subnet_cidr")
        or BAIL_OUT("add_subnet failed: $@");

    # Allocate next free IP
    $allocated_ip = eval {
        PVE::Network::SDN::Ipams::InfobloxPlugin->add_next_freeip(
            $ipam_config, 'test-subnetid', $subnet,
            'uat-test-vm', 'AA:BB:CC:DD:EE:01', 99999, 0);
    };
    ok(!$@, 'add_next_freeip succeeded without error')
        or BAIL_OUT("add_next_freeip failed: $@");
    ok(defined $allocated_ip, "Allocated IP is defined: $allocated_ip")
        or BAIL_OUT("No IP allocated");
    diag("Allocated IP: $allocated_ip");

    # Verify via direct API query
    my $addr_result = raw_api('GET',
        "/ipam/address?_filter=address==\"$allocated_ip\" and space==\"$space_id\"");
    ok($addr_result && $addr_result->{results} && @{$addr_result->{results}},
        'IPAM address exists in Infoblox after allocation');

    my $addr = $addr_result->{results}->[0];

    # Verify tags
    my $tags = $addr->{tags} || {};
    is($tags->{source}, 'proxmox', 'Tag source=proxmox');
    is($tags->{vmid}, '99999', 'Tag vmid=99999');
    is($tags->{hostname}, 'uat-test-vm', 'Tag hostname=uat-test-vm');
    is($tags->{mac}, 'AA:BB:CC:DD:EE:01', 'Tag mac=AA:BB:CC:DD:EE:01');

    # Verify hwaddr (Infoblox normalizes MAC to lowercase)
    is(lc($addr->{hwaddr}), lc('AA:BB:CC:DD:EE:01'), 'hwaddr matches MAC (case-insensitive)');

    diag("--- Phase 1 complete: IP $allocated_ip allocated ---");
};

# ============================================================================
# Phase 2: Create DNS records
# ============================================================================

subtest 'Phase 2: Create DNS records (A + PTR)' => sub {

    # Discover reverse zone for the allocated IP
    my $subnet = {
        cidr    => $main::test_subnet_cidr,
        mask    => $main::test_subnet_prefix,
        network => $main::test_subnet_address,
        zone    => $forward_zone,
    };

    $reverse_zone = eval {
        PVE::Network::SDN::Dns::InfobloxPlugin->get_reversedns_zone(
            $dns_config, 'test-subnetid', $subnet, $allocated_ip);
    };
    ok(!$@, 'get_reversedns_zone succeeded')
        or diag("get_reversedns_zone error: $@");

    if ($reverse_zone) {
        (my $rz_display = $reverse_zone) =~ s/\.$//;
        diag("Reverse zone: $rz_display");
    } else {
        diag("No reverse zone found -- PTR tests will be skipped");
    }

    # Create A record
    eval {
        PVE::Network::SDN::Dns::InfobloxPlugin->add_a_record(
            $dns_config, $forward_zone, 'uat-test-vm', $allocated_ip, 0);
    };
    ok(!$@, "add_a_record succeeded for uat-test-vm.$forward_zone -> $allocated_ip")
        or BAIL_OUT("add_a_record failed: $@");

    # Verify A record exists via direct API query (no view filter -- not supported)
    my $a_fqdn = "uat-test-vm.${forward_zone}.";
    my $a_result = raw_api('GET',
        "/dns/record?_filter="
        . "absolute_name_spec==\"$a_fqdn\""
        . " and type==\"A\"");
    ok($a_result && $a_result->{results} && @{$a_result->{results}},
        'A record exists in Infoblox DNS');
    if ($a_result && $a_result->{results} && @{$a_result->{results}}) {
        diag("A record: $a_fqdn -> " . encode_json($a_result->{results}->[0]->{rdata}));
    }

    # Create PTR record (if reverse zone found)
    if ($reverse_zone) {
        (my $rz_clean = $reverse_zone) =~ s/\.$//;
        my $ptr_hostname = "uat-test-vm.${forward_zone}";

        eval {
            PVE::Network::SDN::Dns::InfobloxPlugin->add_ptr_record(
                $dns_config, $rz_clean, $ptr_hostname, $allocated_ip, 0);
        };
        ok(!$@, "add_ptr_record succeeded for $allocated_ip -> $ptr_hostname")
            or diag("add_ptr_record failed: $@");

        # Verify PTR record via direct API query
        require Net::IP;
        my $reverse_ip = Net::IP->new($allocated_ip)->reverse_ip();
        my $ptr_result = raw_api('GET',
            "/dns/record?_filter="
            . "absolute_name_spec==\"$reverse_ip\""
            . " and type==\"PTR\"");
        ok($ptr_result && $ptr_result->{results} && @{$ptr_result->{results}},
            'PTR record exists in Infoblox DNS');
        if ($ptr_result && $ptr_result->{results} && @{$ptr_result->{results}}) {
            diag("PTR record: $reverse_ip -> " . encode_json($ptr_result->{results}->[0]->{rdata}));
        }
    } else {
        pass('PTR test skipped -- no reverse zone');
    }

    diag("--- Phase 2 complete: DNS records created ---");
};

# ============================================================================
# Phase 3: Delete DNS records (simulating VM deletion)
# ============================================================================

subtest 'Phase 3: Delete DNS records' => sub {

    # Delete A record
    eval {
        PVE::Network::SDN::Dns::InfobloxPlugin->del_a_record(
            $dns_config, $forward_zone, 'uat-test-vm', $allocated_ip, 0);
    };
    ok(!$@, 'del_a_record succeeded')
        or diag("del_a_record error: $@");

    # Verify A record is gone
    my $a_fqdn = "uat-test-vm.${forward_zone}.";
    my $a_result = raw_api('GET',
        "/dns/record?_filter="
        . "absolute_name_spec==\"$a_fqdn\""
        . " and type==\"A\"");
    my $a_gone = !$a_result || !$a_result->{results} || !@{$a_result->{results}};
    ok($a_gone, 'A record removed from Infoblox DNS');

    # Delete PTR record (if reverse zone was found)
    if ($reverse_zone) {
        (my $rz_clean = $reverse_zone) =~ s/\.$//;

        eval {
            PVE::Network::SDN::Dns::InfobloxPlugin->del_ptr_record(
                $dns_config, $rz_clean, $allocated_ip, 0);
        };
        ok(!$@, 'del_ptr_record succeeded')
            or diag("del_ptr_record error: $@");

        # Verify PTR record is gone
        require Net::IP;
        my $reverse_ip = Net::IP->new($allocated_ip)->reverse_ip();
        my $ptr_result = raw_api('GET',
            "/dns/record?_filter="
            . "absolute_name_spec==\"$reverse_ip\""
            . " and type==\"PTR\"");
        my $ptr_gone = !$ptr_result || !$ptr_result->{results} || !@{$ptr_result->{results}};
        ok($ptr_gone, 'PTR record removed from Infoblox DNS');
    } else {
        pass('PTR delete skipped -- no reverse zone');
    }

    diag("--- Phase 3 complete: DNS records deleted ---");
};

# ============================================================================
# Phase 4: Delete IP (simulating IPAM cleanup)
# ============================================================================

subtest 'Phase 4: Delete IP reservation' => sub {

    my $subnet = {
        cidr    => $main::test_subnet_cidr,
        mask    => $main::test_subnet_prefix,
        network => $main::test_subnet_address,
        zone    => $forward_zone,
    };

    eval {
        PVE::Network::SDN::Ipams::InfobloxPlugin->del_ip(
            $ipam_config, 'test-subnetid', $subnet, $allocated_ip, 0);
    };
    ok(!$@, "del_ip succeeded for $allocated_ip")
        or diag("del_ip error: $@");

    # Verify address is gone
    my $addr_result = raw_api('GET',
        "/ipam/address?_filter=address==\"$allocated_ip\" and space==\"$space_id\"");
    my $ip_gone = !$addr_result || !$addr_result->{results} || !@{$addr_result->{results}};
    ok($ip_gone, 'IPAM address removed from Infoblox');

    diag("--- Phase 4 complete: IP $allocated_ip deleted ---");
};

# ============================================================================
# Phase 5: Idempotency
# ============================================================================

subtest 'Phase 5: Idempotent re-deletion' => sub {

    my $subnet = {
        cidr    => $main::test_subnet_cidr,
        mask    => $main::test_subnet_prefix,
        network => $main::test_subnet_address,
        zone    => $forward_zone,
    };

    # del_ip again should succeed silently (address already gone)
    eval {
        PVE::Network::SDN::Ipams::InfobloxPlugin->del_ip(
            $ipam_config, 'test-subnetid', $subnet, $allocated_ip, 0);
    };
    ok(!$@, 'Idempotent del_ip succeeds (no error on already-deleted IP)')
        or diag("Idempotent del_ip error: $@");

    # del_a_record again should succeed silently
    eval {
        PVE::Network::SDN::Dns::InfobloxPlugin->del_a_record(
            $dns_config, $forward_zone, 'uat-test-vm', $allocated_ip, 0);
    };
    ok(!$@, 'Idempotent del_a_record succeeds (no error on already-deleted record)')
        or diag("Idempotent del_a_record error: $@");

    # del_ptr_record again should succeed silently (if reverse zone exists)
    if ($reverse_zone) {
        (my $rz_clean = $reverse_zone) =~ s/\.$//;
        eval {
            PVE::Network::SDN::Dns::InfobloxPlugin->del_ptr_record(
                $dns_config, $rz_clean, $allocated_ip, 0);
        };
        ok(!$@, 'Idempotent del_ptr_record succeeds')
            or diag("Idempotent del_ptr_record error: $@");
    }

    # Mark cleanup as done (END block will skip if address already removed)
    $allocated_ip = undef;

    diag("--- Phase 5 complete: Idempotency verified ---");
};

diag("=== FULL UAT LIFECYCLE COMPLETE ===");
done_testing;
