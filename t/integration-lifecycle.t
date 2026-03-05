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
    mock_api::mock_response('GET', '/ipam/subnet/sub-24/nextavailableip', {
        results => [{ address => '10.0.0.5', id => 'ipam/address/vm1-addr' }],
    });
    mock_api::mock_response('POST', '/ipam/address', {
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
    mock_api::mock_response('DELETE', '/dns/record/ptr-rec-1', {});

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
    mock_api::mock_response('DELETE', '/dns/record/a-rec-1', {});

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
    mock_api::mock_response('DELETE', '/ipam/address/vm1-addr', undef);

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
    mock_api::mock_response('GET', '/ipam/subnet/sub-24/nextavailableip', {
        results => [{ address => '10.0.0.5', id => 'ipam/address/vm1-addr' }],
    });
    mock_api::mock_response('POST', '/ipam/address', {
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
    mock_api::mock_response('GET', '/ipam/subnet/sub-24/nextavailableip', {
        results => [{ address => '10.0.0.6', id => 'ipam/address/vm2-addr' }],
    });
    mock_api::mock_response('POST', '/ipam/address', {
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
    mock_api::mock_response('DELETE', '/ipam/address/vm1-addr', undef);

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
    # add_subnet (verify-only)
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
    # add_subnet (verify-only)
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
    mock_api::mock_response('PATCH', '/ipam/address/ip-existing', {
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
    mock_api::mock_response('GET', '/ipam/subnet/sub-22/nextavailableip', {
        results => [{ address => '10.1.2.50', id => 'ipam/address/vm-22-addr' }],
    });
    mock_api::mock_response('POST', '/ipam/address', {
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
    mock_api::mock_response('GET', '/ipam/subnet/sub-16/nextavailableip', {
        results => [{ address => '172.16.5.10', id => 'ipam/address/vm-16-addr' }],
    });
    mock_api::mock_response('POST', '/ipam/address', {
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

# ============================================================================
# PITFALL 1: eval return bug - add_next_freeip returns IP not undef
# ============================================================================

subtest 'PITFALL 1: eval return bug - add_next_freeip returns IP not undef' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/ipam/ip_space', {
        results => [{ id => 'ipam/ip_space/space-1', name => 'TestSpace' }],
    });
    mock_api::mock_response('GET', '/ipam/subnet', {
        results => [{ id => 'ipam/subnet/sub-24', address => '10.0.0.0/24' }],
    });
    mock_api::mock_response('GET', '/ipam/subnet/sub-24/nextavailableip', {
        results => [{ address => '10.0.0.42', id => 'ipam/address/eval-test' }],
    });
    mock_api::mock_response('POST', '/ipam/address', {
        result => {},
    });

    my $ip = PVE::Network::SDN::Ipams::InfobloxPlugin->add_next_freeip(
        $ipam_config, 'simple1-10.0.0.0-24', $subnet_24,
        'vm-eval-test', undef, 500, 0,
    );
    ok(defined $ip, 'return value is defined (not silently lost by eval)');
    like($ip, qr/^\d+\.\d+\.\d+\.\d+$/, 'return value is an IP address string');
    is($ip, '10.0.0.42', 'returns the exact IP from API response');
};

# ============================================================================
# PITFALL 1b: eval return bug - add_range_next_freeip returns IP not undef
# ============================================================================

subtest 'PITFALL 1b: eval return bug - add_range_next_freeip returns IP not undef' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/ipam/ip_space', {
        results => [{ id => 'ipam/ip_space/space-1', name => 'TestSpace' }],
    });
    mock_api::mock_response('GET', '/ipam/range', {
        results => [{ id => 'ipam/range/range-1', start => '10.0.0.50', end => '10.0.0.100' }],
    });
    mock_api::mock_response('GET', '/ipam/range/range-1/nextavailableip', {
        results => [{ address => '10.0.0.55', id => 'ipam/address/eval-range-test' }],
    });
    mock_api::mock_response('POST', '/ipam/address', {
        result => {},
    });

    my $range = {
        'start-address' => '10.0.0.50',
        'end-address'   => '10.0.0.100',
    };
    my $data = {
        hostname => 'vm-range-eval',
        mac      => 'AA:BB:CC:DD:EE:FF',
        vmid     => 501,
    };

    my $ip = PVE::Network::SDN::Ipams::InfobloxPlugin->add_range_next_freeip(
        $ipam_config, $subnet_24, $range, $data, 0,
    );
    ok(defined $ip, 'return value is defined');
    is($ip, '10.0.0.55', 'returns exact IP from range allocation');
};

# ============================================================================
# PITFALL 2: CIDR format - address param never contains slash
# ============================================================================

subtest 'PITFALL 2: CIDR format - address param never contains slash' => sub {
    # Test add_ip: the POST address param must be bare IP (no /24 suffix)
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/ipam/ip_space', {
        results => [{ id => 'ipam/ip_space/space-1', name => 'TestSpace' }],
    });
    mock_api::mock_response('GET', '/ipam/address', { results => [] });
    mock_api::mock_response('POST', '/ipam/address', {
        result => { id => 'ipam/address/cidr-test', address => '10.0.0.5' },
    });

    eval {
        PVE::Network::SDN::Ipams::InfobloxPlugin->add_ip(
            $ipam_config, 'simple1-10.0.0.0-24', $subnet_24,
            '10.0.0.5', 'vm-cidr', undef, 600, 0, 0,
        );
    };
    is($@, '', 'add_ip succeeds');

    my $calls = mock_api::get_all_calls();
    my @posts = grep { $_->{method} eq 'POST' } @$calls;
    ok(scalar @posts > 0, 'POST call was made');
    ok($posts[0]->{params}->{address} !~ /\//, 'address has no slash (bare IP, not CIDR)');

    # Test add_next_freeip: the PATCH params should not contain slash in any address field
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/ipam/ip_space', {
        results => [{ id => 'ipam/ip_space/space-1', name => 'TestSpace' }],
    });
    mock_api::mock_response('GET', '/ipam/subnet', {
        results => [{ id => 'ipam/subnet/sub-24', address => '10.0.0.0/24' }],
    });
    mock_api::mock_response('GET', '/ipam/subnet/sub-24/nextavailableip', {
        results => [{ address => '10.0.0.7', id => 'ipam/address/cidr-alloc-test' }],
    });
    mock_api::mock_response('POST', '/ipam/address', {
        result => {},
    });

    my $ip = PVE::Network::SDN::Ipams::InfobloxPlugin->add_next_freeip(
        $ipam_config, 'simple1-10.0.0.0-24', $subnet_24,
        'vm-cidr-alloc', undef, 601, 0,
    );
    is($ip, '10.0.0.7', 'IP allocated');

    # Verify the POST call address param does not contain a slash-delimited CIDR
    my $alloc_calls = mock_api::get_all_calls();
    my @alloc_posts = grep { $_->{method} eq 'POST' } @$alloc_calls;
    ok(scalar @alloc_posts > 0, 'POST call was made for address creation');
    ok($alloc_posts[0]->{params}->{address} !~ /\//, 'address param is bare IP, not CIDR');

    note('Existing unit test in ipam-infoblox.t already asserts this; this integration-level check confirms the pattern holds in context.');
};

# ============================================================================
# PITFALL 3: overwrite on upgrade - README documents re-patching mechanism
# ============================================================================

subtest 'PITFALL 3: overwrite on upgrade - README documents re-patching mechanism' => sub {
    # Non-code pitfall: verified via documentation. Phase 3 install script + .deb
    # postinst handles the actual re-patching.

    my $readme_path = 't/../README.md';
    open(my $fh, '<', $readme_path) or die "Cannot open README.md: $!\n";
    my $readme_content = do { local $/; <$fh> };
    close($fh);

    like($readme_content, qr/apt.*upgrade.*overwrite|overwrite.*apt.*upgrade|upgrade.*overwritten/i,
        'README mentions overwrite on upgrade');
    like($readme_content, qr/dpkg.*trigger|trigger.*dpkg/i,
        'README mentions dpkg trigger re-patching');
    like($readme_content, qr/re-run.*install\.sh|install\.sh.*re-run|Re-run.*install\.sh/i,
        'README mentions re-running install script as fallback');

    note('Non-code pitfall: verified via documentation. Phase 3 install script + .deb postinst handles the actual re-patching.');
};

# ============================================================================
# PITFALL 4: Simple zone limit - README documents the constraint
# ============================================================================

subtest 'PITFALL 4: Simple zone limit - README documents the constraint' => sub {
    # Non-code pitfall: PVE 8.x architecture constraint.

    my $readme_path = 't/../README.md';
    open(my $fh, '<', $readme_path) or die "Cannot open README.md: $!\n";
    my $readme_content = do { local $/; <$fh> };
    close($fh);

    like($readme_content, qr/Simple Zones? only/i, 'README states Simple Zones only');
    like($readme_content, qr/VLAN.*EVPN.*do not trigger|VLAN.*EVPN.*hooks|VLAN and EVPN zone/i,
        'README explains VLAN/EVPN limitation');

    note('Non-code pitfall: PVE 8.x architecture constraint. Plugin handles this by design (only runs when called by SDN framework for Simple zones).');
};

# ============================================================================
# PITFALL 5: PTR prefix lengths - /24, /22, /16 reverse zones compute correctly
# ============================================================================

subtest 'PITFALL 5: PTR prefix lengths - /24, /22, /16 reverse zones compute correctly' => sub {

    # /24: IP 10.0.0.5, zone 0.0.10.in-addr.arpa. found
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/dns/view', {
        results => [{ id => 'dns/view/view-1', name => 'TestView' }],
    });
    mock_api::mock_response('GET', 'fqdn=="0.0.10.in-addr.arpa."', {
        results => [{ id => 'dns/auth_zone/rev-24', fqdn => '0.0.10.in-addr.arpa.' }],
    });

    my $zone_24 = PVE::Network::SDN::Dns::InfobloxPlugin->get_reversedns_zone(
        $dns_config, 'simple1-10.0.0.0-24', $subnet_24, '10.0.0.5',
    );
    is($zone_24, '0.0.10.in-addr.arpa.', '/24: correct reverse zone found');

    # /22: IP 10.1.2.50, zone 2.1.10.in-addr.arpa. found
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/dns/view', {
        results => [{ id => 'dns/view/view-1', name => 'TestView' }],
    });
    mock_api::mock_response('GET', 'fqdn=="2.1.10.in-addr.arpa."', {
        results => [{ id => 'dns/auth_zone/rev-22', fqdn => '2.1.10.in-addr.arpa.' }],
    });

    my $zone_22 = PVE::Network::SDN::Dns::InfobloxPlugin->get_reversedns_zone(
        $dns_config, 'simple1-10.1.0.0-22', $subnet_22, '10.1.2.50',
    );
    is($zone_22, '2.1.10.in-addr.arpa.', '/22: correct reverse zone for non-base /24');

    # Create PTR for /22 and verify name_in_zone is '50'
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/dns/view', {
        results => [{ id => 'dns/view/view-1', name => 'TestView' }],
    });
    mock_api::mock_response('GET', '/dns/auth_zone', {
        results => [{ id => 'dns/auth_zone/rev-22', fqdn => '2.1.10.in-addr.arpa.' }],
    });
    mock_api::mock_response('GET', '/dns/record', { results => [] });
    mock_api::mock_response('POST', '/dns/record', {
        result => { id => 'dns/record/ptr-pit5-22' },
    });

    eval {
        PVE::Network::SDN::Dns::InfobloxPlugin->add_ptr_record(
            $dns_config, '2.1.10.in-addr.arpa.', 'vm-pit5.example.com', '10.1.2.50', 0,
        );
    };
    is($@, '', 'PTR record created for /22 IP');
    my $calls_22 = mock_api::get_all_calls();
    my @posts_22 = grep { $_->{method} eq 'POST' } @$calls_22;
    is($posts_22[0]->{params}->{name_in_zone}, '50', '/22: name_in_zone is "50"');

    # /16: IP 172.16.5.10, /24 zone not found, /16 zone found
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/dns/view', {
        results => [{ id => 'dns/view/view-1', name => 'TestView' }],
    });
    mock_api::mock_response('GET', 'fqdn=="5.16.172.in-addr.arpa."', { results => [] });
    mock_api::mock_response('GET', 'fqdn=="16.172.in-addr.arpa."', {
        results => [{ id => 'dns/auth_zone/rev-16', fqdn => '16.172.in-addr.arpa.' }],
    });

    my $zone_16 = PVE::Network::SDN::Dns::InfobloxPlugin->get_reversedns_zone(
        $dns_config, 'simple1-172.16.0.0-16', $subnet_16, '172.16.5.10',
    );
    is($zone_16, '16.172.in-addr.arpa.', '/16: correct reverse zone after /24 fallback');

    # Create PTR for /16 and verify name_in_zone is '10.5'
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/dns/view', {
        results => [{ id => 'dns/view/view-1', name => 'TestView' }],
    });
    mock_api::mock_response('GET', '/dns/auth_zone', {
        results => [{ id => 'dns/auth_zone/rev-16', fqdn => '16.172.in-addr.arpa.' }],
    });
    mock_api::mock_response('GET', '/dns/record', { results => [] });
    mock_api::mock_response('POST', '/dns/record', {
        result => { id => 'dns/record/ptr-pit5-16' },
    });

    eval {
        PVE::Network::SDN::Dns::InfobloxPlugin->add_ptr_record(
            $dns_config, '16.172.in-addr.arpa.', 'vm-pit5.example.com', '172.16.5.10', 0,
        );
    };
    is($@, '', 'PTR record created for /16 IP');
    my $calls_16 = mock_api::get_all_calls();
    my @posts_16 = grep { $_->{method} eq 'POST' } @$calls_16;
    is($posts_16[0]->{params}->{name_in_zone}, '10.5', '/16: name_in_zone is "10.5"');

    # /25 (sub-octet): IP 10.0.0.200 in 10.0.0.128/25
    # Should find 0.0.10.in-addr.arpa. (same /24 zone since /25 is sub-octet)
    my $subnet_25 = {
        cidr    => '10.0.0.128/25',
        mask    => '25',
        zone    => 'simple1',
        network => '10.0.0.128',
    };
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/dns/view', {
        results => [{ id => 'dns/view/view-1', name => 'TestView' }],
    });
    mock_api::mock_response('GET', 'fqdn=="0.0.10.in-addr.arpa."', {
        results => [{ id => 'dns/auth_zone/rev-25', fqdn => '0.0.10.in-addr.arpa.' }],
    });

    my $zone_25 = PVE::Network::SDN::Dns::InfobloxPlugin->get_reversedns_zone(
        $dns_config, 'simple1-10.0.0.128-25', $subnet_25, '10.0.0.200',
    );
    is($zone_25, '0.0.10.in-addr.arpa.', '/25: finds /24 reverse zone (sub-octet)');

    # Create PTR for /25 and verify name_in_zone is '200'
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/dns/view', {
        results => [{ id => 'dns/view/view-1', name => 'TestView' }],
    });
    mock_api::mock_response('GET', '/dns/auth_zone', {
        results => [{ id => 'dns/auth_zone/rev-25', fqdn => '0.0.10.in-addr.arpa.' }],
    });
    mock_api::mock_response('GET', '/dns/record', { results => [] });
    mock_api::mock_response('POST', '/dns/record', {
        result => { id => 'dns/record/ptr-pit5-25' },
    });

    eval {
        PVE::Network::SDN::Dns::InfobloxPlugin->add_ptr_record(
            $dns_config, '0.0.10.in-addr.arpa.', 'vm-pit5.example.com', '10.0.0.200', 0,
        );
    };
    is($@, '', 'PTR record created for /25 IP');
    my $calls_25 = mock_api::get_all_calls();
    my @posts_25 = grep { $_->{method} eq 'POST' } @$calls_25;
    is($posts_25[0]->{params}->{name_in_zone}, '200', '/25: name_in_zone is "200"');
};

# ============================================================================
# PITFALL 6: non-idempotent creates - repeated add uses PATCH not POST
# ============================================================================

subtest 'PITFALL 6: non-idempotent creates - repeated add uses PATCH not POST' => sub {

    # --- add_subnet: called twice, both succeed (verify-only, no writes) ---
    for my $pass (1, 2) {
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
        is($@, '', "add_subnet pass $pass succeeds");
        my $calls = mock_api::get_all_calls();
        my @posts = grep { $_->{method} eq 'POST' } @$calls;
        is(scalar @posts, 0, "add_subnet pass $pass: zero POST calls (verify only)");
    }

    # --- add_ip: first call POST (new), second call PATCH (existing) ---
    # First pass: address doesn't exist -> POST
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/ipam/ip_space', {
        results => [{ id => 'ipam/ip_space/space-1', name => 'TestSpace' }],
    });
    mock_api::mock_response('GET', '/ipam/address', { results => [] });
    mock_api::mock_response('POST', '/ipam/address', {
        result => { id => 'ipam/address/pit6-ip', address => '10.0.0.20' },
    });

    eval {
        PVE::Network::SDN::Ipams::InfobloxPlugin->add_ip(
            $ipam_config, 'simple1-10.0.0.0-24', $subnet_24,
            '10.0.0.20', 'vm-pit6', undef, 700, 0, 0,
        );
    };
    is($@, '', 'add_ip first pass succeeds');
    my $ip1_calls = mock_api::get_all_calls();
    my @ip1_posts = grep { $_->{method} eq 'POST' } @$ip1_calls;
    is(scalar @ip1_posts, 1, 'add_ip first pass: used POST');

    # Second pass: address exists -> PATCH
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/ipam/ip_space', {
        results => [{ id => 'ipam/ip_space/space-1', name => 'TestSpace' }],
    });
    mock_api::mock_response('GET', '/ipam/address', {
        results => [{ id => 'ipam/address/pit6-ip', address => '10.0.0.20' }],
    });
    mock_api::mock_response('PATCH', '/ipam/address/pit6-ip', {
        result => { id => 'ipam/address/pit6-ip' },
    });

    eval {
        PVE::Network::SDN::Ipams::InfobloxPlugin->add_ip(
            $ipam_config, 'simple1-10.0.0.0-24', $subnet_24,
            '10.0.0.20', 'vm-pit6', undef, 700, 0, 0,
        );
    };
    is($@, '', 'add_ip second pass succeeds');
    my $ip2_calls = mock_api::get_all_calls();
    my @ip2_posts = grep { $_->{method} eq 'POST' } @$ip2_calls;
    my @ip2_patches = grep { $_->{method} eq 'PATCH' } @$ip2_calls;
    is(scalar @ip2_posts, 0, 'add_ip second pass: zero POST calls');
    is(scalar @ip2_patches, 1, 'add_ip second pass: used PATCH instead');

    # --- add_a_record: first call POST, second call PATCH ---
    # First pass
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/dns/view', {
        results => [{ id => 'dns/view/view-1', name => 'TestView' }],
    });
    mock_api::mock_response('GET', '/dns/auth_zone', {
        results => [{ id => 'dns/auth_zone/fwd-zone-1', fqdn => 'example.com.' }],
    });
    mock_api::mock_response('GET', '/dns/record', { results => [] });
    mock_api::mock_response('POST', '/dns/record', {
        result => { id => 'dns/record/pit6-a' },
    });

    eval {
        PVE::Network::SDN::Dns::InfobloxPlugin->add_a_record(
            $dns_config, 'example.com', 'vm-pit6', '10.0.0.20', 0,
        );
    };
    is($@, '', 'add_a_record first pass succeeds');
    my $a1_calls = mock_api::get_all_calls();
    my @a1_posts = grep { $_->{method} eq 'POST' } @$a1_calls;
    is(scalar @a1_posts, 1, 'add_a_record first pass: used POST');

    # Second pass
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/dns/view', {
        results => [{ id => 'dns/view/view-1', name => 'TestView' }],
    });
    mock_api::mock_response('GET', '/dns/auth_zone', {
        results => [{ id => 'dns/auth_zone/fwd-zone-1', fqdn => 'example.com.' }],
    });
    mock_api::mock_response('GET', '/dns/record', {
        results => [{ id => 'dns/record/pit6-a', type => 'A' }],
    });
    mock_api::mock_response('PATCH', '/dns/record', {
        result => { id => 'dns/record/pit6-a' },
    });

    eval {
        PVE::Network::SDN::Dns::InfobloxPlugin->add_a_record(
            $dns_config, 'example.com', 'vm-pit6', '10.0.0.20', 0,
        );
    };
    is($@, '', 'add_a_record second pass succeeds');
    my $a2_calls = mock_api::get_all_calls();
    my @a2_posts = grep { $_->{method} eq 'POST' } @$a2_calls;
    my @a2_patches = grep { $_->{method} eq 'PATCH' } @$a2_calls;
    is(scalar @a2_posts, 0, 'add_a_record second pass: zero POST calls');
    is(scalar @a2_patches, 1, 'add_a_record second pass: used PATCH instead');

    # --- add_ptr_record: first call POST, second call PATCH ---
    # First pass
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/dns/view', {
        results => [{ id => 'dns/view/view-1', name => 'TestView' }],
    });
    mock_api::mock_response('GET', '/dns/auth_zone', {
        results => [{ id => 'dns/auth_zone/rev-zone', fqdn => '0.0.10.in-addr.arpa.' }],
    });
    mock_api::mock_response('GET', '/dns/record', { results => [] });
    mock_api::mock_response('POST', '/dns/record', {
        result => { id => 'dns/record/pit6-ptr' },
    });

    eval {
        PVE::Network::SDN::Dns::InfobloxPlugin->add_ptr_record(
            $dns_config, '0.0.10.in-addr.arpa.', 'vm-pit6.example.com', '10.0.0.20', 0,
        );
    };
    is($@, '', 'add_ptr_record first pass succeeds');
    my $ptr1_calls = mock_api::get_all_calls();
    my @ptr1_posts = grep { $_->{method} eq 'POST' } @$ptr1_calls;
    is(scalar @ptr1_posts, 1, 'add_ptr_record first pass: used POST');

    # Second pass
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/dns/view', {
        results => [{ id => 'dns/view/view-1', name => 'TestView' }],
    });
    mock_api::mock_response('GET', '/dns/auth_zone', {
        results => [{ id => 'dns/auth_zone/rev-zone', fqdn => '0.0.10.in-addr.arpa.' }],
    });
    mock_api::mock_response('GET', '/dns/record', {
        results => [{ id => 'dns/record/pit6-ptr', type => 'PTR' }],
    });
    mock_api::mock_response('PATCH', '/dns/record', {
        result => { id => 'dns/record/pit6-ptr' },
    });

    eval {
        PVE::Network::SDN::Dns::InfobloxPlugin->add_ptr_record(
            $dns_config, '0.0.10.in-addr.arpa.', 'vm-pit6.example.com', '10.0.0.20', 0,
        );
    };
    is($@, '', 'add_ptr_record second pass succeeds');
    my $ptr2_calls = mock_api::get_all_calls();
    my @ptr2_posts = grep { $_->{method} eq 'POST' } @$ptr2_calls;
    my @ptr2_patches = grep { $_->{method} eq 'PATCH' } @$ptr2_calls;
    is(scalar @ptr2_posts, 0, 'add_ptr_record second pass: zero POST calls');
    is(scalar @ptr2_patches, 1, 'add_ptr_record second pass: used PATCH instead');
};

done_testing;
