#!/usr/bin/perl

use strict;
use warnings;

use lib 't/lib';
use lib 'src';
use lib 't';

use Test::More;
use mock_api;

# Load both plugins
use_ok('PVE::Network::SDN::Ipams::InfobloxPlugin')
    or BAIL_OUT('Cannot load IPAM InfobloxPlugin');
use_ok('PVE::Network::SDN::Dns::InfobloxPlugin')
    or BAIL_OUT('Cannot load DNS InfobloxPlugin');

# --- Shared config ---

my $ipam_config = {
    url      => 'https://csp.infoblox.com',
    token    => 'test-api-token-12345',
    ip_space => 'TestSpace',
};

my $dns_config = {
    url      => 'https://csp.infoblox.com',
    token    => 'test-api-token-12345',
    dns_view => 'TestView',
};

my $subnet_24 = {
    cidr    => '10.0.0.0/24',
    mask    => '24',
    zone    => 'simple1',
    network => '10.0.0.0',
};

my $subnet_22 = {
    cidr    => '10.1.0.0/22',
    mask    => '22',
    zone    => 'simple1',
    network => '10.1.0.0',
};

my $subnet_16 = {
    cidr    => '172.16.0.0/16',
    mask    => '16',
    zone    => 'simple1',
    network => '172.16.0.0',
};

# ============================================================================
# Subtest 1: Full VM lifecycle
# ============================================================================

subtest 'VM lifecycle: gateway reservation + allocate IP + A record + PTR record + cleanup' => sub {

    # -- Phase A: Reserve gateway IP --
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/ipam/ip_space', {
        results => [{ id => 'ipam/ip_space/space-1', name => 'TestSpace' }],
    });
    mock_api::mock_response('GET', '/ipam/address', {
        results => [],
    });
    mock_api::mock_response('POST', '/ipam/address', {
        result => { id => 'ipam/address/gw-addr', address => '10.0.0.1' },
    });

    eval {
        PVE::Network::SDN::Ipams::InfobloxPlugin->add_ip(
            $ipam_config, 'simple1-10.0.0.0-24', $subnet_24,
            '10.0.0.1', 'gateway', undef, undef, 1, 0,
        );
    };
    is($@, '', 'Phase A: gateway IP reserved without error');

    my $phase_a_calls = mock_api::get_all_calls();
    my @phase_a_posts = grep { $_->{method} eq 'POST' } @$phase_a_calls;
    is(scalar @phase_a_posts, 1, 'Phase A: exactly one POST for gateway creation');
    is($phase_a_posts[0]->{params}->{comment}, 'gateway', 'Phase A: comment is "gateway"');
    is($phase_a_posts[0]->{params}->{tags}->{gateway}, 'true', 'Phase A: tags.gateway is "true"');

    # -- Phase B: Verify subnet exists --
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/ipam/ip_space', {
        results => [{ id => 'ipam/ip_space/space-1', name => 'TestSpace' }],
    });
    mock_api::mock_response('GET', '/ipam/subnet', {
        results => [{ id => 'ipam/subnet/sub-24', address => '10.0.0.0/24' }],
    });

    eval {
        PVE::Network::SDN::Ipams::InfobloxPlugin->add_subnet(
            $ipam_config, 'simple1-10.0.0.0-24', $subnet_24, 0,
        );
    };
    is($@, '', 'Phase B: subnet verification succeeds');

    # -- Phase C: Allocate VM IP --
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/ipam/ip_space', {
        results => [{ id => 'ipam/ip_space/space-1', name => 'TestSpace' }],
    });
    mock_api::mock_response('GET', '/ipam/subnet', {
        results => [{ id => 'ipam/subnet/sub-24', address => '10.0.0.0/24' }],
    });
    mock_api::mock_response('POST', '/ipam/subnet/ipam/subnet/sub-24/nextavailableip', {
        results => [{ address => '10.0.0.5', id => 'ipam/address/vm1-addr' }],
    });
    mock_api::mock_response('PATCH', '/ipam/address/ipam/address/vm1-addr', {
        result => {},
    });

    my $vm_ip = PVE::Network::SDN::Ipams::InfobloxPlugin->add_next_freeip(
        $ipam_config, 'simple1-10.0.0.0-24', $subnet_24,
        'vm-web', 'AA:BB:CC:DD:EE:FF', 100, 0,
    );
    is($vm_ip, '10.0.0.5', 'Phase C: allocated IP is 10.0.0.5');

    # -- Phase D: Create A record --
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/dns/view', {
        results => [{ id => 'dns/view/view-1', name => 'TestView' }],
    });
    mock_api::mock_response('GET', '/dns/auth_zone', {
        results => [{ id => 'dns/auth_zone/fwd-zone-1', fqdn => 'example.com.' }],
    });
    mock_api::mock_response('GET', '/dns/record', {
        results => [],
    });
    mock_api::mock_response('POST', '/dns/record', {
        result => { id => 'dns/record/a-rec-1' },
    });

    eval {
        PVE::Network::SDN::Dns::InfobloxPlugin->add_a_record(
            $dns_config, 'example.com', 'vm-web', '10.0.0.5', 0,
        );
    };
    is($@, '', 'Phase D: A record created without error');

    my $phase_d_calls = mock_api::get_all_calls();
    my @phase_d_posts = grep { $_->{method} eq 'POST' } @$phase_d_calls;
    is(scalar @phase_d_posts, 1, 'Phase D: exactly one POST for A record');
    is($phase_d_posts[0]->{params}->{type}, 'A', 'Phase D: POST type is A');
    is($phase_d_posts[0]->{params}->{rdata}->{address}, '10.0.0.5', 'Phase D: rdata.address is 10.0.0.5');

    # -- Phase E: Create PTR record --
    # First, find the reverse zone
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/dns/view', {
        results => [{ id => 'dns/view/view-1', name => 'TestView' }],
    });
    mock_api::mock_response('GET', 'fqdn=="0.0.10.in-addr.arpa."', {
        results => [{ id => 'dns/auth_zone/rev-zone-24', fqdn => '0.0.10.in-addr.arpa.' }],
    });

    my $rev_zone = PVE::Network::SDN::Dns::InfobloxPlugin->get_reversedns_zone(
        $dns_config, 'simple1-10.0.0.0-24', $subnet_24, '10.0.0.5',
    );
    is($rev_zone, '0.0.10.in-addr.arpa.', 'Phase E: reverse zone found for /24');

    # Then create the PTR record
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/dns/view', {
        results => [{ id => 'dns/view/view-1', name => 'TestView' }],
    });
    mock_api::mock_response('GET', '/dns/auth_zone', {
        results => [{ id => 'dns/auth_zone/rev-zone-24', fqdn => '0.0.10.in-addr.arpa.' }],
    });
    mock_api::mock_response('GET', '/dns/record', {
        results => [],
    });
    mock_api::mock_response('POST', '/dns/record', {
        result => { id => 'dns/record/ptr-rec-1' },
    });

    eval {
        PVE::Network::SDN::Dns::InfobloxPlugin->add_ptr_record(
            $dns_config, '0.0.10.in-addr.arpa.', 'vm-web.example.com', '10.0.0.5', 0,
        );
    };
    is($@, '', 'Phase E: PTR record created without error');

    my $phase_e_calls = mock_api::get_all_calls();
    my @phase_e_posts = grep { $_->{method} eq 'POST' } @$phase_e_calls;
    is(scalar @phase_e_posts, 1, 'Phase E: exactly one POST for PTR record');
    is($phase_e_posts[0]->{params}->{type}, 'PTR', 'Phase E: POST type is PTR');

    # -- Phase F: Destroy VM (reverse order: del PTR, del A, del IP) --

    # Delete PTR
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/dns/view', {
        results => [{ id => 'dns/view/view-1', name => 'TestView' }],
    });
    mock_api::mock_response('GET', '/dns/record', {
        results => [{ id => 'dns/record/ptr-rec-1', type => 'PTR' }],
    });
    mock_api::mock_response('DELETE', '/dns/record/dns/record/ptr-rec-1', {});

    eval {
        PVE::Network::SDN::Dns::InfobloxPlugin->del_ptr_record(
            $dns_config, '0.0.10.in-addr.arpa.', '10.0.0.5', 0,
        );
    };
    is($@, '', 'Phase F: PTR record deleted without error');

    my $ptr_del_calls = mock_api::get_all_calls();
    my @ptr_deletes = grep { $_->{method} eq 'DELETE' } @$ptr_del_calls;
    is(scalar @ptr_deletes, 1, 'Phase F: exactly one DELETE for PTR');

    # Delete A record
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/dns/view', {
        results => [{ id => 'dns/view/view-1', name => 'TestView' }],
    });
    mock_api::mock_response('GET', '/dns/record', {
        results => [{ id => 'dns/record/a-rec-1', type => 'A' }],
    });
    mock_api::mock_response('DELETE', '/dns/record/dns/record/a-rec-1', {});

    eval {
        PVE::Network::SDN::Dns::InfobloxPlugin->del_a_record(
            $dns_config, 'example.com', 'vm-web', '10.0.0.5', 0,
        );
    };
    is($@, '', 'Phase F: A record deleted without error');

    my $a_del_calls = mock_api::get_all_calls();
    my @a_deletes = grep { $_->{method} eq 'DELETE' } @$a_del_calls;
    is(scalar @a_deletes, 1, 'Phase F: exactly one DELETE for A record');

    # Delete IP
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/ipam/ip_space', {
        results => [{ id => 'ipam/ip_space/space-1', name => 'TestSpace' }],
    });
    mock_api::mock_response('GET', '/ipam/address', {
        results => [{ id => 'ipam/address/vm1-addr', address => '10.0.0.5' }],
    });
    mock_api::mock_response('DELETE', '/ipam/address/ipam/address/vm1-addr', undef);

    eval {
        PVE::Network::SDN::Ipams::InfobloxPlugin->del_ip(
            $ipam_config, 'simple1-10.0.0.0-24', $subnet_24, '10.0.0.5', 0,
        );
    };
    is($@, '', 'Phase F: IP deleted without error');

    my $ip_del_calls = mock_api::get_all_calls();
    my @ip_deletes = grep { $_->{method} eq 'DELETE' } @$ip_del_calls;
    is(scalar @ip_deletes, 1, 'Phase F: exactly one DELETE for IP address');
};

# ============================================================================
# Subtest 2: Multi-VM non-contamination
# ============================================================================

subtest 'multi-VM: create VM1, create VM2, delete VM1, verify VM2 unaffected' => sub {

    # -- Phase A: Allocate VM1 at 10.0.0.5 --
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/ipam/ip_space', {
        results => [{ id => 'ipam/ip_space/space-1', name => 'TestSpace' }],
    });
    mock_api::mock_response('GET', '/ipam/subnet', {
        results => [{ id => 'ipam/subnet/sub-24', address => '10.0.0.0/24' }],
    });
    mock_api::mock_response('POST', '/ipam/subnet/ipam/subnet/sub-24/nextavailableip', {
        results => [{ address => '10.0.0.5', id => 'ipam/address/vm1-addr' }],
    });
    mock_api::mock_response('PATCH', '/ipam/address/ipam/address/vm1-addr', {
        result => {},
    });

    my $vm1_ip = PVE::Network::SDN::Ipams::InfobloxPlugin->add_next_freeip(
        $ipam_config, 'simple1-10.0.0.0-24', $subnet_24,
        'vm-web-1', 'AA:BB:CC:DD:EE:01', 101, 0,
    );
    is($vm1_ip, '10.0.0.5', 'Phase A: VM1 allocated at 10.0.0.5');

    # -- Phase B: Allocate VM2 at 10.0.0.6 --
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/ipam/ip_space', {
        results => [{ id => 'ipam/ip_space/space-1', name => 'TestSpace' }],
    });
    mock_api::mock_response('GET', '/ipam/subnet', {
        results => [{ id => 'ipam/subnet/sub-24', address => '10.0.0.0/24' }],
    });
    mock_api::mock_response('POST', '/ipam/subnet/ipam/subnet/sub-24/nextavailableip', {
        results => [{ address => '10.0.0.6', id => 'ipam/address/vm2-addr' }],
    });
    mock_api::mock_response('PATCH', '/ipam/address/ipam/address/vm2-addr', {
        result => {},
    });

    my $vm2_ip = PVE::Network::SDN::Ipams::InfobloxPlugin->add_next_freeip(
        $ipam_config, 'simple1-10.0.0.0-24', $subnet_24,
        'vm-web-2', 'AA:BB:CC:DD:EE:02', 102, 0,
    );
    is($vm2_ip, '10.0.0.6', 'Phase B: VM2 allocated at 10.0.0.6');

    # -- Phase C: Delete VM1's IP only --
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/ipam/ip_space', {
        results => [{ id => 'ipam/ip_space/space-1', name => 'TestSpace' }],
    });
    mock_api::mock_response('GET', '/ipam/address', {
        results => [{ id => 'ipam/address/vm1-addr', address => '10.0.0.5' }],
    });
    mock_api::mock_response('DELETE', '/ipam/address/ipam/address/vm1-addr', undef);

    eval {
        PVE::Network::SDN::Ipams::InfobloxPlugin->del_ip(
            $ipam_config, 'simple1-10.0.0.0-24', $subnet_24, '10.0.0.5', 0,
        );
    };
    is($@, '', 'Phase C: VM1 IP deleted without error');

    my $phase_c_calls = mock_api::get_all_calls();
    my @phase_c_deletes = grep { $_->{method} eq 'DELETE' } @$phase_c_calls;
    is(scalar @phase_c_deletes, 1, 'Phase C: exactly one DELETE call');
    like($phase_c_deletes[0]->{url}, qr/vm1-addr/, 'Phase C: DELETE targets vm1-addr only');

    # -- Phase D: Verify VM2 still queryable --
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/ipam/ip_space', {
        results => [{ id => 'ipam/ip_space/space-1', name => 'TestSpace' }],
    });
    mock_api::mock_response('GET', '/ipam/address', {
        results => [{ id => 'ipam/address/vm2-addr', address => '10.0.0.6' }],
    });

    my $vm2_id = PVE::Network::SDN::Ipams::InfobloxPlugin::get_address_id(
        $ipam_config, '10.0.0.6', 'ipam/ip_space/space-1',
    );
    is($vm2_id, 'ipam/address/vm2-addr', 'Phase D: VM2 address still exists and queryable');
};

# ============================================================================
# Subtest 3: Repeated apply idempotency (second pass uses PATCH not POST)
# ============================================================================

subtest 'repeated pvesh apply: second pass uses PATCH not POST for existing resources' => sub {

    # -- First pass: fresh creation (POST paths) --
    # add_subnet (verify-only, no writes)
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/ipam/ip_space', {
        results => [{ id => 'ipam/ip_space/space-1', name => 'TestSpace' }],
    });
    mock_api::mock_response('GET', '/ipam/subnet', {
        results => [{ id => 'ipam/subnet/sub-24', address => '10.0.0.0/24' }],
    });

    eval {
        PVE::Network::SDN::Ipams::InfobloxPlugin->add_subnet(
            $ipam_config, 'simple1-10.0.0.0-24', $subnet_24, 0,
        );
    };
    is($@, '', 'First pass: add_subnet succeeds');

    # add_ip for 10.0.0.5 (POST path since address doesn't exist)
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/ipam/ip_space', {
        results => [{ id => 'ipam/ip_space/space-1', name => 'TestSpace' }],
    });
    mock_api::mock_response('GET', '/ipam/address', {
        results => [],
    });
    mock_api::mock_response('POST', '/ipam/address', {
        result => { id => 'ipam/address/ip-fresh', address => '10.0.0.5' },
    });

    eval {
        PVE::Network::SDN::Ipams::InfobloxPlugin->add_ip(
            $ipam_config, 'simple1-10.0.0.0-24', $subnet_24,
            '10.0.0.5', 'vm-web', 'AA:BB:CC:DD:EE:FF', 100, 0, 0,
        );
    };
    is($@, '', 'First pass: add_ip succeeds with POST');

    my $first_ip_calls = mock_api::get_all_calls();
    my @first_ip_posts = grep { $_->{method} eq 'POST' } @$first_ip_calls;
    is(scalar @first_ip_posts, 1, 'First pass: add_ip used POST (new address)');

    # add_a_record (POST path since record doesn't exist)
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/dns/view', {
        results => [{ id => 'dns/view/view-1', name => 'TestView' }],
    });
    mock_api::mock_response('GET', '/dns/auth_zone', {
        results => [{ id => 'dns/auth_zone/fwd-zone-1', fqdn => 'example.com.' }],
    });
    mock_api::mock_response('GET', '/dns/record', {
        results => [],
    });
    mock_api::mock_response('POST', '/dns/record', {
        result => { id => 'dns/record/a-rec-fresh' },
    });

    eval {
        PVE::Network::SDN::Dns::InfobloxPlugin->add_a_record(
            $dns_config, 'example.com', 'vm-web', '10.0.0.5', 0,
        );
    };
    is($@, '', 'First pass: add_a_record succeeds with POST');

    my $first_a_calls = mock_api::get_all_calls();
    my @first_a_posts = grep { $_->{method} eq 'POST' } @$first_a_calls;
    is(scalar @first_a_posts, 1, 'First pass: add_a_record used POST (new record)');

    # -- Second pass: existing resources (PATCH paths) --
    # add_subnet: same verify-only (no writes)
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/ipam/ip_space', {
        results => [{ id => 'ipam/ip_space/space-1', name => 'TestSpace' }],
    });
    mock_api::mock_response('GET', '/ipam/subnet', {
        results => [{ id => 'ipam/subnet/sub-24', address => '10.0.0.0/24' }],
    });

    eval {
        PVE::Network::SDN::Ipams::InfobloxPlugin->add_subnet(
            $ipam_config, 'simple1-10.0.0.0-24', $subnet_24, 0,
        );
    };
    is($@, '', 'Second pass: add_subnet still succeeds');

    # add_ip for 10.0.0.5: GET finds existing -> uses PATCH
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/ipam/ip_space', {
        results => [{ id => 'ipam/ip_space/space-1', name => 'TestSpace' }],
    });
    mock_api::mock_response('GET', '/ipam/address', {
        results => [{ id => 'ipam/address/ip-existing', address => '10.0.0.5' }],
    });
    mock_api::mock_response('PATCH', '/ipam/address/ipam/address/ip-existing', {
        result => { id => 'ipam/address/ip-existing' },
    });

    eval {
        PVE::Network::SDN::Ipams::InfobloxPlugin->add_ip(
            $ipam_config, 'simple1-10.0.0.0-24', $subnet_24,
            '10.0.0.5', 'vm-web', 'AA:BB:CC:DD:EE:FF', 100, 0, 0,
        );
    };
    is($@, '', 'Second pass: add_ip succeeds with PATCH');

    my $second_ip_calls = mock_api::get_all_calls();
    my @second_ip_posts = grep { $_->{method} eq 'POST' } @$second_ip_calls;
    my @second_ip_patches = grep { $_->{method} eq 'PATCH' } @$second_ip_calls;
    is(scalar @second_ip_posts, 0, 'Second pass: add_ip used zero POST calls');
    is(scalar @second_ip_patches, 1, 'Second pass: add_ip used PATCH instead');

    # add_a_record: GET finds existing -> uses PATCH
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/dns/view', {
        results => [{ id => 'dns/view/view-1', name => 'TestView' }],
    });
    mock_api::mock_response('GET', '/dns/auth_zone', {
        results => [{ id => 'dns/auth_zone/fwd-zone-1', fqdn => 'example.com.' }],
    });
    mock_api::mock_response('GET', '/dns/record', {
        results => [{ id => 'dns/record/a-rec-existing', type => 'A' }],
    });
    mock_api::mock_response('PATCH', '/dns/record', {
        result => { id => 'dns/record/a-rec-existing' },
    });

    eval {
        PVE::Network::SDN::Dns::InfobloxPlugin->add_a_record(
            $dns_config, 'example.com', 'vm-web', '10.0.0.5', 0,
        );
    };
    is($@, '', 'Second pass: add_a_record succeeds with PATCH');

    my $second_a_calls = mock_api::get_all_calls();
    my @second_a_posts = grep { $_->{method} eq 'POST' } @$second_a_calls;
    my @second_a_patches = grep { $_->{method} eq 'PATCH' } @$second_a_calls;
    is(scalar @second_a_posts, 0, 'Second pass: add_a_record used zero POST calls');
    is(scalar @second_a_patches, 1, 'Second pass: add_a_record used PATCH instead');
};

# ============================================================================
# Subtest 4: Lifecycle with /22 subnet - correct reverse zone for non-base /24
# ============================================================================

subtest 'lifecycle with /22 subnet: correct reverse zone for IP in non-base /24' => sub {

    # Allocate IP 10.1.2.50 via add_next_freeip with $subnet_22
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/ipam/ip_space', {
        results => [{ id => 'ipam/ip_space/space-1', name => 'TestSpace' }],
    });
    mock_api::mock_response('GET', '/ipam/subnet', {
        results => [{ id => 'ipam/subnet/sub-22', address => '10.1.0.0/22' }],
    });
    mock_api::mock_response('POST', '/ipam/subnet/ipam/subnet/sub-22/nextavailableip', {
        results => [{ address => '10.1.2.50', id => 'ipam/address/vm-22-addr' }],
    });
    mock_api::mock_response('PATCH', '/ipam/address/ipam/address/vm-22-addr', {
        result => {},
    });

    my $ip_22 = PVE::Network::SDN::Ipams::InfobloxPlugin->add_next_freeip(
        $ipam_config, 'simple1-10.1.0.0-22', $subnet_22,
        'vm-in-22', undef, 200, 0,
    );
    is($ip_22, '10.1.2.50', 'allocated IP 10.1.2.50 from /22 subnet');

    # get_reversedns_zone for 10.1.2.50: IP falls in 10.1.2.0/24 range
    # so reverse zone should be 2.1.10.in-addr.arpa.
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/dns/view', {
        results => [{ id => 'dns/view/view-1', name => 'TestView' }],
    });
    mock_api::mock_response('GET', 'fqdn=="2.1.10.in-addr.arpa."', {
        results => [{ id => 'dns/auth_zone/rev-zone-22', fqdn => '2.1.10.in-addr.arpa.' }],
    });

    my $rev_zone_22 = PVE::Network::SDN::Dns::InfobloxPlugin->get_reversedns_zone(
        $dns_config, 'simple1-10.1.0.0-22', $subnet_22, '10.1.2.50',
    );
    is($rev_zone_22, '2.1.10.in-addr.arpa.', 'reverse zone is 2.1.10.in-addr.arpa. for IP in non-base /24 of /22');

    # Create PTR record and verify name_in_zone is '50' (single component for /24 zone)
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/dns/view', {
        results => [{ id => 'dns/view/view-1', name => 'TestView' }],
    });
    mock_api::mock_response('GET', '/dns/auth_zone', {
        results => [{ id => 'dns/auth_zone/rev-zone-22', fqdn => '2.1.10.in-addr.arpa.' }],
    });
    mock_api::mock_response('GET', '/dns/record', {
        results => [],
    });
    mock_api::mock_response('POST', '/dns/record', {
        result => { id => 'dns/record/ptr-22' },
    });

    eval {
        PVE::Network::SDN::Dns::InfobloxPlugin->add_ptr_record(
            $dns_config, '2.1.10.in-addr.arpa.', 'vm-in-22.example.com', '10.1.2.50', 0,
        );
    };
    is($@, '', 'PTR record created for /22 subnet IP');

    my $ptr_22_calls = mock_api::get_all_calls();
    my @ptr_22_posts = grep { $_->{method} eq 'POST' } @$ptr_22_calls;
    is($ptr_22_posts[0]->{params}->{name_in_zone}, '50',
       'name_in_zone is "50" (single component relative to /24 zone)');
};

# ============================================================================
# Subtest 5: Lifecycle with /16 subnet - two-component name_in_zone
# ============================================================================

subtest 'lifecycle with /16 subnet: two-component name_in_zone' => sub {

    # Allocate IP 172.16.5.10 via add_next_freeip with $subnet_16
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/ipam/ip_space', {
        results => [{ id => 'ipam/ip_space/space-1', name => 'TestSpace' }],
    });
    mock_api::mock_response('GET', '/ipam/subnet', {
        results => [{ id => 'ipam/subnet/sub-16', address => '172.16.0.0/16' }],
    });
    mock_api::mock_response('POST', '/ipam/subnet/ipam/subnet/sub-16/nextavailableip', {
        results => [{ address => '172.16.5.10', id => 'ipam/address/vm-16-addr' }],
    });
    mock_api::mock_response('PATCH', '/ipam/address/ipam/address/vm-16-addr', {
        result => {},
    });

    my $ip_16 = PVE::Network::SDN::Ipams::InfobloxPlugin->add_next_freeip(
        $ipam_config, 'simple1-172.16.0.0-16', $subnet_16,
        'vm-in-16', undef, 300, 0,
    );
    is($ip_16, '172.16.5.10', 'allocated IP 172.16.5.10 from /16 subnet');

    # get_reversedns_zone for 172.16.5.10:
    # /24 zone 5.16.172.in-addr.arpa. NOT found, then /16 zone 16.172.in-addr.arpa. found
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/dns/view', {
        results => [{ id => 'dns/view/view-1', name => 'TestView' }],
    });
    # /24 zone does NOT exist
    mock_api::mock_response('GET', 'fqdn=="5.16.172.in-addr.arpa."', {
        results => [],
    });
    # /16 zone exists
    mock_api::mock_response('GET', 'fqdn=="16.172.in-addr.arpa."', {
        results => [{ id => 'dns/auth_zone/rev-zone-16', fqdn => '16.172.in-addr.arpa.' }],
    });

    my $rev_zone_16 = PVE::Network::SDN::Dns::InfobloxPlugin->get_reversedns_zone(
        $dns_config, 'simple1-172.16.0.0-16', $subnet_16, '172.16.5.10',
    );
    is($rev_zone_16, '16.172.in-addr.arpa.', 'reverse zone is 16.172.in-addr.arpa. for /16 subnet');

    # Create PTR record and verify name_in_zone is '10.5' (two components relative to /16 zone)
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/dns/view', {
        results => [{ id => 'dns/view/view-1', name => 'TestView' }],
    });
    mock_api::mock_response('GET', '/dns/auth_zone', {
        results => [{ id => 'dns/auth_zone/rev-zone-16', fqdn => '16.172.in-addr.arpa.' }],
    });
    mock_api::mock_response('GET', '/dns/record', {
        results => [],
    });
    mock_api::mock_response('POST', '/dns/record', {
        result => { id => 'dns/record/ptr-16' },
    });

    eval {
        PVE::Network::SDN::Dns::InfobloxPlugin->add_ptr_record(
            $dns_config, '16.172.in-addr.arpa.', 'vm-in-16.example.com', '172.16.5.10', 0,
        );
    };
    is($@, '', 'PTR record created for /16 subnet IP');

    my $ptr_16_calls = mock_api::get_all_calls();
    my @ptr_16_posts = grep { $_->{method} eq 'POST' } @$ptr_16_calls;
    is($ptr_16_posts[0]->{params}->{name_in_zone}, '10.5',
       'name_in_zone is "10.5" (two components relative to /16 zone)');
};

# ============================================================================
# Subtest 6: IPAM auth failure identifies the problem
# ============================================================================

subtest 'error messages: IPAM auth failure identifies the problem' => sub {
    mock_api::clear_mocks();
    mock_api::mock_error('GET', '/ipam/ip_space', "401 Unauthorized\n");

    eval {
        PVE::Network::SDN::Ipams::InfobloxPlugin->on_update_hook($ipam_config);
    };
    like($@, qr/Authentication failed/, 'identifies auth failure');
    like($@, qr/invalid API token/, 'mentions token is invalid');
};

# ============================================================================
# Subtest 7: IPAM connectivity failure identifies URL
# ============================================================================

subtest 'error messages: IPAM connectivity failure identifies URL' => sub {
    mock_api::clear_mocks();
    mock_api::mock_error('GET', '/ipam/ip_space', "connection refused\n");

    eval {
        PVE::Network::SDN::Ipams::InfobloxPlugin->on_update_hook($ipam_config);
    };
    like($@, qr/Cannot reach Infoblox API/, 'identifies connectivity issue');
    like($@, qr/csp\.infoblox\.com/, 'includes the API URL');
};

# ============================================================================
# Subtest 8: IPAM server error propagates context
# ============================================================================

subtest 'error messages: IPAM server error propagates context' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/ipam/ip_space', {
        results => [{ id => 'ipam/ip_space/space-1', name => 'TestSpace' }],
    });
    mock_api::mock_response('GET', '/ipam/subnet', {
        results => [{ id => 'ipam/subnet/sub-24', address => '10.0.0.0/24' }],
    });
    mock_api::mock_error('POST', 'nextavailableip', "500 Internal Server Error\n");

    eval {
        PVE::Network::SDN::Ipams::InfobloxPlugin->add_next_freeip(
            $ipam_config, 'simple1-10.0.0.0-24', $subnet_24,
            'vm-err-test', undef, 999, 0,
        );
    };
    like($@, qr/can't find free ip/, 'wraps error with context');
    like($@, qr/10\.0\.0\.0\/24/, 'includes subnet CIDR in error');
};

# ============================================================================
# Subtest 9: DNS auth failure identifies the problem
# ============================================================================

subtest 'error messages: DNS auth failure identifies the problem' => sub {
    mock_api::clear_mocks();
    mock_api::mock_error('GET', '/dns/view', "401 Unauthorized\n");

    eval {
        PVE::Network::SDN::Dns::InfobloxPlugin->on_update_hook($dns_config);
    };
    like($@, qr/Authentication failed/, 'identifies auth failure');
    like($@, qr/invalid API token/, 'mentions token is invalid');
};

# ============================================================================
# Subtest 10: DNS View not found is actionable
# ============================================================================

subtest 'error messages: DNS View not found is actionable' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/dns/view', { results => [] });

    eval {
        PVE::Network::SDN::Dns::InfobloxPlugin->on_update_hook($dns_config);
    };
    like($@, qr/DNS View/, 'mentions DNS View');
    like($@, qr/not found/, 'says not found');
    like($@, qr/TestView/, 'includes the view name that was searched for');
};

# ============================================================================
# Subtest 11: Token leak prevention across all major error paths
# ============================================================================

subtest 'token leak prevention: API tokens never appear in error messages' => sub {
    my $secret_token = 'SUPER-SECRET-TOKEN-abc123';

    my $ipam_secret_config = {
        url      => 'https://csp.infoblox.com',
        token    => $secret_token,
        ip_space => 'TestSpace',
    };
    my $dns_secret_config = {
        url      => 'https://csp.infoblox.com',
        token    => $secret_token,
        dns_view => 'TestView',
    };

    # List of error scenarios to test for token leaks
    my @scenarios = (
        {
            name  => 'IPAM on_update_hook auth error',
            setup => sub {
                mock_api::mock_error('GET', '/ipam/ip_space', "401 Unauthorized\n");
            },
            call => sub {
                PVE::Network::SDN::Ipams::InfobloxPlugin->on_update_hook($ipam_secret_config);
            },
        },
        {
            name  => 'IPAM on_update_hook connectivity error',
            setup => sub {
                mock_api::mock_error('GET', '/ipam/ip_space', "connection refused\n");
            },
            call => sub {
                PVE::Network::SDN::Ipams::InfobloxPlugin->on_update_hook($ipam_secret_config);
            },
        },
        {
            name  => 'IPAM on_update_hook IP Space not found',
            setup => sub {
                mock_api::mock_response('GET', '/ipam/ip_space', { results => [] });
            },
            call => sub {
                PVE::Network::SDN::Ipams::InfobloxPlugin->on_update_hook($ipam_secret_config);
            },
        },
        {
            name  => 'DNS on_update_hook auth error',
            setup => sub {
                mock_api::mock_error('GET', '/dns/view', "401 Unauthorized\n");
            },
            call => sub {
                PVE::Network::SDN::Dns::InfobloxPlugin->on_update_hook($dns_secret_config);
            },
        },
        {
            name  => 'DNS on_update_hook connectivity error',
            setup => sub {
                mock_api::mock_error('GET', '/dns/view', "connection refused\n");
            },
            call => sub {
                PVE::Network::SDN::Dns::InfobloxPlugin->on_update_hook($dns_secret_config);
            },
        },
        {
            name  => 'DNS on_update_hook DNS View not found',
            setup => sub {
                mock_api::mock_response('GET', '/dns/view', { results => [] });
            },
            call => sub {
                PVE::Network::SDN::Dns::InfobloxPlugin->on_update_hook($dns_secret_config);
            },
        },
        {
            name  => 'IPAM add_next_freeip allocation failure',
            setup => sub {
                mock_api::mock_response('GET', '/ipam/ip_space', {
                    results => [{ id => 'ipam/ip_space/space-1', name => 'TestSpace' }],
                });
                mock_api::mock_response('GET', '/ipam/subnet', {
                    results => [{ id => 'ipam/subnet/sub-24', address => '10.0.0.0/24' }],
                });
                mock_api::mock_error('POST', 'nextavailableip', "500 Internal Server Error\n");
            },
            call => sub {
                PVE::Network::SDN::Ipams::InfobloxPlugin->add_next_freeip(
                    $ipam_secret_config, 'simple1-10.0.0.0-24', $subnet_24,
                    'vm-leak-test', undef, 999, 0,
                );
            },
        },
        {
            name  => 'IPAM del_ip delete error',
            setup => sub {
                mock_api::mock_response('GET', '/ipam/ip_space', {
                    results => [{ id => 'ipam/ip_space/space-1', name => 'TestSpace' }],
                });
                mock_api::mock_response('GET', '/ipam/address', {
                    results => [{ id => 'ipam/address/del-test', address => '10.0.0.99' }],
                });
                mock_api::mock_error('DELETE', '/ipam/address', "500 Internal Server Error\n");
            },
            call => sub {
                PVE::Network::SDN::Ipams::InfobloxPlugin->del_ip(
                    $ipam_secret_config, 'simple1-10.0.0.0-24', $subnet_24, '10.0.0.99', 0,
                );
            },
        },
        {
            name  => 'DNS add_a_record zone not found',
            setup => sub {
                mock_api::mock_response('GET', '/dns/view', {
                    results => [{ id => 'dns/view/view-1', name => 'TestView' }],
                });
                mock_api::mock_response('GET', '/dns/auth_zone', { results => [] });
            },
            call => sub {
                PVE::Network::SDN::Dns::InfobloxPlugin->add_a_record(
                    $dns_secret_config, 'example.com', 'vm-leak', '10.0.0.99', 0,
                );
            },
        },
    );

    for my $scenario (@scenarios) {
        mock_api::clear_mocks();
        $scenario->{setup}->();
        eval { $scenario->{call}->() };
        unlike($@, qr/SUPER-SECRET-TOKEN/, "no token leak in $scenario->{name}");
    }
};

done_testing;
