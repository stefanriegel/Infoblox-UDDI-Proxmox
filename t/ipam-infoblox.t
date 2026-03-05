#!/usr/bin/perl

use strict;
use warnings;

use lib 't/lib';
use lib 'src';
use lib 't';

use Test::More;
use mock_api;

# Load the plugin module
use_ok('PVE::Network::SDN::Ipams::InfobloxPlugin')
    or BAIL_OUT('Cannot load InfobloxPlugin');

# Test config used across subtests
my $config = {
    url      => 'https://csp.infoblox.com',
    token    => 'test-api-token-12345',
    ip_space => 'TestSpace',
};

# -- Registration tests --

subtest 'type returns infobloxuddi' => sub {
    is(PVE::Network::SDN::Ipams::InfobloxPlugin->type(), 'infobloxuddi',
       'type() returns infobloxuddi');
};

subtest 'properties has required fields' => sub {
    my $props = PVE::Network::SDN::Ipams::InfobloxPlugin->properties();
    ok(ref $props eq 'HASH', 'properties() returns a hashref');
    for my $field (qw(url token ip_space)) {
        ok(exists $props->{$field}, "properties has '$field' field");
        is($props->{$field}->{type}, 'string', "'$field' has type => string");
    }
};

subtest 'options marks all required' => sub {
    my $opts = PVE::Network::SDN::Ipams::InfobloxPlugin->options();
    ok(ref $opts eq 'HASH', 'options() returns a hashref');
    for my $field (qw(url token ip_space)) {
        ok(exists $opts->{$field}, "options has '$field' field");
        is($opts->{$field}->{optional}, 0, "'$field' is required (optional => 0)");
    }
};

# -- ID resolution helper tests --

subtest 'get_ip_space_id found' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/ipam/ip_space', {
        results => [{ id => 'ipam/ip_space/test-uuid-123', name => 'TestSpace' }],
    });

    my $id = PVE::Network::SDN::Ipams::InfobloxPlugin::get_ip_space_id($config, 'TestSpace');
    is($id, 'ipam/ip_space/test-uuid-123', 'returns the IP Space id');
};

subtest 'get_ip_space_id not found' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/ipam/ip_space', {
        results => [],
    });

    my $id = PVE::Network::SDN::Ipams::InfobloxPlugin::get_ip_space_id($config, 'NonExistent');
    is($id, undef, 'returns undef for non-existent IP Space');
};

subtest 'get_subnet_id found' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/ipam/subnet', {
        results => [{ id => 'ipam/subnet/subnet-uuid-456', address => '10.0.0.0/24' }],
    });

    my $id = PVE::Network::SDN::Ipams::InfobloxPlugin::get_subnet_id(
        $config, '10.0.0.0/24', 'ipam/ip_space/test-uuid-123',
    );
    is($id, 'ipam/subnet/subnet-uuid-456', 'returns the subnet id');
};

subtest 'get_subnet_id not found' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/ipam/subnet', {
        results => [],
    });

    my $id = PVE::Network::SDN::Ipams::InfobloxPlugin::get_subnet_id(
        $config, '10.99.99.0/24', 'ipam/ip_space/test-uuid-123',
    );
    is($id, undef, 'returns undef for non-existent subnet');
};

subtest 'get_address_id found' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/ipam/address', {
        results => [{ id => 'ipam/address/addr-uuid-789', address => '10.0.0.5' }],
    });

    my $id = PVE::Network::SDN::Ipams::InfobloxPlugin::get_address_id(
        $config, '10.0.0.5', 'ipam/ip_space/test-uuid-123',
    );
    is($id, 'ipam/address/addr-uuid-789', 'returns the address id');
};

subtest 'get_address_id not found' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/ipam/address', {
        results => [],
    });

    my $id = PVE::Network::SDN::Ipams::InfobloxPlugin::get_address_id(
        $config, '10.0.0.99', 'ipam/ip_space/test-uuid-123',
    );
    is($id, undef, 'returns undef for non-existent address');
};

subtest 'api_request_headers' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/ipam/ip_space', {
        results => [{ id => 'ipam/ip_space/hdr-test', name => 'TestSpace' }],
    });

    PVE::Network::SDN::Ipams::InfobloxPlugin::infoblox_api_request(
        $config, 'GET', '/ipam/ip_space', undef,
    );

    my $call = mock_api::get_last_call();
    ok(defined $call, 'api call was captured');
    is($call->{method}, 'GET', 'method is GET');
    like($call->{url}, qr{https://csp\.infoblox\.com/api/ddi/v1/ipam/ip_space},
         'URL includes base URL and /api/ddi/v1 prefix');

    # Headers are an arrayref: [key, val, key, val, ...]
    my $headers = $call->{headers};
    ok(ref $headers eq 'ARRAY', 'headers is an arrayref');

    # Find Authorization header
    my %header_map;
    for (my $i = 0; $i < scalar(@$headers); $i += 2) {
        $header_map{$headers->[$i]} = $headers->[$i + 1];
    }

    is($header_map{'Authorization'}, 'Token test-api-token-12345',
       'Authorization header uses Token format');
    is($header_map{'Content-Type'}, 'application/json; charset=UTF-8',
       'Content-Type header is set correctly');
};

# -- Subnet lifecycle tests --

my $subnet = {
    cidr    => '10.0.0.0/24',
    mask    => '24',
    zone    => 'simple1',
    network => '10.0.0.0',
};

subtest 'add_subnet with valid subnet in correct IP Space' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/ipam/ip_space', {
        results => [{ id => 'ipam/ip_space/test-uuid-123', name => 'TestSpace' }],
    });
    mock_api::mock_response('GET', '/ipam/subnet', {
        results => [{ id => 'ipam/subnet/subnet-uuid-456', address => '10.0.0.0/24' }],
    });

    my $err;
    eval {
        PVE::Network::SDN::Ipams::InfobloxPlugin->add_subnet(
            $config, 'simple1-10.0.0.0-24', $subnet, 0,
        );
    };
    $err = $@;
    is($err, '', 'add_subnet succeeds for existing subnet');
};

subtest 'add_subnet with missing subnet' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/ipam/ip_space', {
        results => [{ id => 'ipam/ip_space/test-uuid-123', name => 'TestSpace' }],
    });
    mock_api::mock_response('GET', '/ipam/subnet', {
        results => [],
    });

    eval {
        PVE::Network::SDN::Ipams::InfobloxPlugin->add_subnet(
            $config, 'simple1-10.0.0.0-24', $subnet, 0,
        );
    };
    like($@, qr/subnet.*not found.*IP Space/, 'dies with subnet not found message');
};

subtest 'add_subnet with missing IP Space' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/ipam/ip_space', {
        results => [],
    });

    eval {
        PVE::Network::SDN::Ipams::InfobloxPlugin->add_subnet(
            $config, 'simple1-10.0.0.0-24', $subnet, 0,
        );
    };
    like($@, qr/IP Space.*not found/, 'dies with IP Space not found message');
};

subtest 'add_subnet with noerr=1 and missing subnet' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/ipam/ip_space', {
        results => [],
    });

    my $result;
    eval {
        $result = PVE::Network::SDN::Ipams::InfobloxPlugin->add_subnet(
            $config, 'simple1-10.0.0.0-24', $subnet, 1,
        );
    };
    is($@, '', 'does not die with noerr=1');
    is($result, undef, 'returns undef with noerr=1');
};

subtest 'add_subnet idempotent - two calls succeed' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/ipam/ip_space', {
        results => [{ id => 'ipam/ip_space/test-uuid-123', name => 'TestSpace' }],
    });
    mock_api::mock_response('GET', '/ipam/subnet', {
        results => [{ id => 'ipam/subnet/subnet-uuid-456', address => '10.0.0.0/24' }],
    });

    my ($err1, $err2);
    eval {
        PVE::Network::SDN::Ipams::InfobloxPlugin->add_subnet(
            $config, 'simple1-10.0.0.0-24', $subnet, 0,
        );
    };
    $err1 = $@;

    eval {
        PVE::Network::SDN::Ipams::InfobloxPlugin->add_subnet(
            $config, 'simple1-10.0.0.0-24', $subnet, 0,
        );
    };
    $err2 = $@;

    is($err1, '', 'first call succeeds');
    is($err2, '', 'second call also succeeds (idempotent)');
};

subtest 'del_subnet is a no-op' => sub {
    mock_api::clear_mocks();

    my $err;
    eval {
        PVE::Network::SDN::Ipams::InfobloxPlugin->del_subnet(
            $config, 'simple1-10.0.0.0-24', $subnet, 0,
        );
    };
    $err = $@;
    is($err, '', 'del_subnet returns without error');

    my $calls = mock_api::get_all_calls();
    is(scalar(@$calls), 0, 'del_subnet makes no API calls');
};

subtest 'update_subnet is a no-op' => sub {
    mock_api::clear_mocks();

    my $err;
    eval {
        PVE::Network::SDN::Ipams::InfobloxPlugin->update_subnet(
            $config, 'simple1-10.0.0.0-24', $subnet, $subnet, 0,
        );
    };
    $err = $@;
    is($err, '', 'update_subnet returns without error');

    my $calls = mock_api::get_all_calls();
    is(scalar(@$calls), 0, 'update_subnet makes no API calls');
};

# -- on_update_hook tests --

subtest 'on_update_hook with valid config succeeds' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/ipam/ip_space', {
        results => [{ id => 'ipam/ip_space/test-uuid-123', name => 'TestSpace' }],
    });

    my $err;
    eval {
        PVE::Network::SDN::Ipams::InfobloxPlugin->on_update_hook($config);
    };
    $err = $@;
    is($err, '', 'on_update_hook succeeds with valid config');
};

subtest 'on_update_hook with unreachable API' => sub {
    mock_api::clear_mocks();
    mock_api::mock_error('GET', '/ipam/ip_space', "connection refused\n");

    eval {
        PVE::Network::SDN::Ipams::InfobloxPlugin->on_update_hook($config);
    };
    like($@, qr/Cannot reach Infoblox API at/, 'dies with unreachable API message');
};

subtest 'on_update_hook with invalid token' => sub {
    mock_api::clear_mocks();
    mock_api::mock_error('GET', '/ipam/ip_space', "401 Unauthorized\n");

    eval {
        PVE::Network::SDN::Ipams::InfobloxPlugin->on_update_hook($config);
    };
    like($@, qr/Authentication failed: invalid API token/, 'dies with auth failure message');
};

subtest 'on_update_hook with missing IP Space' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/ipam/ip_space', {
        results => [],
    });

    eval {
        PVE::Network::SDN::Ipams::InfobloxPlugin->on_update_hook($config);
    };
    like($@, qr/IP Space.*not found in Infoblox/, 'dies with IP Space not found message');
};

# -- add_next_freeip tests --

subtest 'add_next_freeip allocates IP with correct metadata' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/ipam/ip_space', {
        results => [{ id => 'ipam/ip_space/test-uuid-123', name => 'TestSpace' }],
    });
    mock_api::mock_response('GET', '/ipam/subnet', {
        results => [{ id => 'ipam/subnet/sub1', address => '10.0.0.0/24' }],
    });
    mock_api::mock_response('POST', '/ipam/subnet/ipam/subnet/sub1/nextavailableip', {
        results => [{ address => '10.0.0.5', id => 'ipam/address/addr1' }],
    });
    mock_api::mock_response('PATCH', '/ipam/address/ipam/address/addr1', {
        result => {},
    });

    my $ip = PVE::Network::SDN::Ipams::InfobloxPlugin->add_next_freeip(
        $config, 'simple1-10.0.0.0-24', $subnet,
        'vm-web', 'AA:BB:CC:DD:EE:FF', 100, 0,
    );

    is($ip, '10.0.0.5', 'returns allocated IP address');

    # Verify the PATCH call has correct metadata
    my $calls = mock_api::get_all_calls();
    my @patch_calls = grep { $_->{method} eq 'PATCH' } @$calls;
    is(scalar @patch_calls, 1, 'exactly one PATCH call made');

    my $patch_params = $patch_calls[0]->{params};
    is($patch_params->{comment}, 'vm-web', 'comment is hostname');
    is_deeply($patch_params->{names}, [{ name => 'vm-web', type => 'user' }],
              'names contains hostname with type user');
    is($patch_params->{tags}->{source}, 'proxmox', 'tags has source=proxmox');
    is($patch_params->{tags}->{vmid}, '100', 'tags has vmid as string');
    is($patch_params->{hwaddr}, 'AA:BB:CC:DD:EE:FF', 'hwaddr is set when MAC provided');
};

subtest 'add_next_freeip without MAC omits hwaddr' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/ipam/ip_space', {
        results => [{ id => 'ipam/ip_space/test-uuid-123', name => 'TestSpace' }],
    });
    mock_api::mock_response('GET', '/ipam/subnet', {
        results => [{ id => 'ipam/subnet/sub1', address => '10.0.0.0/24' }],
    });
    mock_api::mock_response('POST', '/ipam/subnet/ipam/subnet/sub1/nextavailableip', {
        results => [{ address => '10.0.0.6', id => 'ipam/address/addr2' }],
    });
    mock_api::mock_response('PATCH', '/ipam/address/ipam/address/addr2', {
        result => {},
    });

    my $ip = PVE::Network::SDN::Ipams::InfobloxPlugin->add_next_freeip(
        $config, 'simple1-10.0.0.0-24', $subnet,
        'vm-web', undef, 100, 0,
    );

    is($ip, '10.0.0.6', 'returns allocated IP address');

    my $calls = mock_api::get_all_calls();
    my @patch_calls = grep { $_->{method} eq 'PATCH' } @$calls;
    my $patch_params = $patch_calls[0]->{params};
    ok(!exists $patch_params->{hwaddr}, 'hwaddr is NOT set when MAC is undef');
};

subtest 'add_next_freeip with noerr returns undef on failure' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/ipam/ip_space', {
        results => [],
    });

    my $result;
    eval {
        $result = PVE::Network::SDN::Ipams::InfobloxPlugin->add_next_freeip(
            $config, 'simple1-10.0.0.0-24', $subnet,
            'vm-web', undef, 100, 1,
        );
    };
    is($@, '', 'does not die with noerr=1');
    is($result, undef, 'returns undef with noerr=1');
};

subtest 'add_next_freeip dies on API error without noerr' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/ipam/ip_space', {
        results => [{ id => 'ipam/ip_space/test-uuid-123', name => 'TestSpace' }],
    });
    mock_api::mock_response('GET', '/ipam/subnet', {
        results => [{ id => 'ipam/subnet/sub1', address => '10.0.0.0/24' }],
    });
    mock_api::mock_error('POST', '/ipam/subnet/ipam/subnet/sub1/nextavailableip',
        "no available IPs\n");

    eval {
        PVE::Network::SDN::Ipams::InfobloxPlugin->add_next_freeip(
            $config, 'simple1-10.0.0.0-24', $subnet,
            'vm-web', undef, 100, 0,
        );
    };
    like($@, qr/can't find free ip in subnet 10\.0\.0\.0\/24/,
         'dies with descriptive error including subnet CIDR');
};

# -- add_range_next_freeip tests --

subtest 'add_range_next_freeip allocates from range' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/ipam/ip_space', {
        results => [{ id => 'ipam/ip_space/test-uuid-123', name => 'TestSpace' }],
    });
    mock_api::mock_response('GET', '/ipam/range', {
        results => [{ id => 'ipam/range/r1' }],
    });
    mock_api::mock_response('POST', '/ipam/range/ipam/range/r1/nextavailableip', {
        results => [{ address => '10.0.0.55', id => 'ipam/address/addr2' }],
    });
    mock_api::mock_response('PATCH', '/ipam/address/ipam/address/addr2', {
        result => {},
    });

    my $range = { 'start-address' => '10.0.0.50', 'end-address' => '10.0.0.200' };
    my $data = { hostname => 'vm-db', vmid => '101' };

    my $ip = PVE::Network::SDN::Ipams::InfobloxPlugin->add_range_next_freeip(
        $config, $subnet, $range, $data, 0,
    );

    is($ip, '10.0.0.55', 'returns allocated IP from range');

    # Verify metadata on PATCH
    my $calls = mock_api::get_all_calls();
    my @patch_calls = grep { $_->{method} eq 'PATCH' } @$calls;
    is(scalar @patch_calls, 1, 'exactly one PATCH call');
    my $patch_params = $patch_calls[0]->{params};
    is($patch_params->{comment}, 'vm-db', 'comment is hostname from $data');
    is($patch_params->{tags}->{vmid}, '101', 'vmid from $data');
};

subtest 'add_range_next_freeip dies when range not found' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/ipam/ip_space', {
        results => [{ id => 'ipam/ip_space/test-uuid-123', name => 'TestSpace' }],
    });
    mock_api::mock_response('GET', '/ipam/range', {
        results => [],
    });

    my $range = { 'start-address' => '10.0.0.50', 'end-address' => '10.0.0.200' };
    my $data = { hostname => 'vm-db', vmid => '101' };

    eval {
        PVE::Network::SDN::Ipams::InfobloxPlugin->add_range_next_freeip(
            $config, $subnet, $range, $data, 0,
        );
    };
    like($@, qr/range.*not found/, 'dies with range not found message');
};

# -- add_ip tests --

subtest 'add_ip creates new address with correct metadata' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/ipam/ip_space', {
        results => [{ id => 'ipam/ip_space/test-uuid-123', name => 'TestSpace' }],
    });
    mock_api::mock_response('GET', '/ipam/address', {
        results => [],
    });
    mock_api::mock_response('POST', '/ipam/address', {
        result => { id => 'ipam/address/new1', address => '10.0.0.5' },
    });

    my $err;
    eval {
        PVE::Network::SDN::Ipams::InfobloxPlugin->add_ip(
            $config, 'simple1-10.0.0.0-24', $subnet,
            '10.0.0.5', 'vm-web', 'AA:BB:CC:DD:EE:FF', 100, 0, 0,
        );
    };
    $err = $@;
    is($err, '', 'add_ip succeeds for new address');

    # Verify POST was called with correct params
    my $calls = mock_api::get_all_calls();
    my @post_calls = grep { $_->{method} eq 'POST' } @$calls;
    is(scalar @post_calls, 1, 'exactly one POST call made');

    my $post_params = $post_calls[0]->{params};
    is($post_params->{address}, '10.0.0.5', 'address is bare IP (no CIDR)');
    ok($post_params->{address} !~ /\//, 'address has no slash (bare IP, not CIDR)');
    is($post_params->{space}, 'ipam/ip_space/test-uuid-123', 'space is set to space_id');
    is($post_params->{comment}, 'vm-web', 'comment is hostname');
    is_deeply($post_params->{names}, [{ name => 'vm-web', type => 'user' }],
              'names contains hostname');
    is($post_params->{tags}->{source}, 'proxmox', 'tags has source=proxmox');
    is($post_params->{tags}->{vmid}, '100', 'tags has vmid as string');
    is($post_params->{hwaddr}, 'AA:BB:CC:DD:EE:FF', 'hwaddr is set');
};

subtest 'add_ip updates existing address (idempotent)' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/ipam/ip_space', {
        results => [{ id => 'ipam/ip_space/test-uuid-123', name => 'TestSpace' }],
    });
    mock_api::mock_response('GET', '/ipam/address', {
        results => [{ id => 'ipam/address/existing1', address => '10.0.0.5' }],
    });
    mock_api::mock_response('PATCH', '/ipam/address/ipam/address/existing1', {
        result => { id => 'ipam/address/existing1' },
    });

    my $err;
    eval {
        PVE::Network::SDN::Ipams::InfobloxPlugin->add_ip(
            $config, 'simple1-10.0.0.0-24', $subnet,
            '10.0.0.5', 'vm-web', 'AA:BB:CC:DD:EE:FF', 100, 0, 0,
        );
    };
    $err = $@;
    is($err, '', 'add_ip succeeds for existing address');

    # Verify PATCH was called (not POST)
    my $calls = mock_api::get_all_calls();
    my @patch_calls = grep { $_->{method} eq 'PATCH' } @$calls;
    my @post_calls = grep { $_->{method} eq 'POST' } @$calls;
    is(scalar @patch_calls, 1, 'exactly one PATCH call made');
    is(scalar @post_calls, 0, 'no POST call made (idempotent update)');

    my $patch_params = $patch_calls[0]->{params};
    is($patch_params->{comment}, 'vm-web', 'PATCH has correct comment');
};

subtest 'add_ip with gateway sets comment to gateway and adds gateway tag' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/ipam/ip_space', {
        results => [{ id => 'ipam/ip_space/test-uuid-123', name => 'TestSpace' }],
    });
    mock_api::mock_response('GET', '/ipam/address', {
        results => [],
    });
    mock_api::mock_response('POST', '/ipam/address', {
        result => { id => 'ipam/address/gw1', address => '10.0.0.1' },
    });

    my $err;
    eval {
        PVE::Network::SDN::Ipams::InfobloxPlugin->add_ip(
            $config, 'simple1-10.0.0.0-24', $subnet,
            '10.0.0.1', 'vm-web', undef, undef, 1, 0,
        );
    };
    $err = $@;
    is($err, '', 'add_ip succeeds for gateway');

    my $calls = mock_api::get_all_calls();
    my @post_calls = grep { $_->{method} eq 'POST' } @$calls;
    my $post_params = $post_calls[0]->{params};
    is($post_params->{comment}, 'gateway', 'comment is "gateway" not hostname');
    is($post_params->{tags}->{gateway}, 'true', 'tags has gateway=true');
};

subtest 'add_ip with noerr returns undef on failure' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/ipam/ip_space', {
        results => [],
    });

    my $result;
    eval {
        $result = PVE::Network::SDN::Ipams::InfobloxPlugin->add_ip(
            $config, 'simple1-10.0.0.0-24', $subnet,
            '10.0.0.5', 'vm-web', undef, 100, 0, 1,
        );
    };
    is($@, '', 'does not die with noerr=1');
    is($result, undef, 'returns undef with noerr=1');
};

# -- del_ip tests --

subtest 'del_ip with existing address deletes by ID' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/ipam/ip_space', {
        results => [{ id => 'ipam/ip_space/test-uuid-123', name => 'TestSpace' }],
    });
    mock_api::mock_response('GET', '/ipam/address', {
        results => [{ id => 'ipam/address/addr1', address => '10.0.0.5' }],
    });
    mock_api::mock_response('DELETE', '/ipam/address/ipam/address/addr1', undef);

    my $err;
    eval {
        PVE::Network::SDN::Ipams::InfobloxPlugin->del_ip(
            $config, 'simple1-10.0.0.0-24', $subnet, '10.0.0.5', 0,
        );
    };
    $err = $@;
    is($err, '', 'del_ip succeeds for existing address');

    # Verify DELETE was called with correct path
    my $calls = mock_api::get_all_calls();
    my @delete_calls = grep { $_->{method} eq 'DELETE' } @$calls;
    is(scalar @delete_calls, 1, 'exactly one DELETE call made');
    like($delete_calls[0]->{url}, qr{/ipam/address/ipam/address/addr1},
         'DELETE uses correct address ID path');
};

subtest 'del_ip with address not found succeeds silently (idempotent)' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/ipam/ip_space', {
        results => [{ id => 'ipam/ip_space/test-uuid-123', name => 'TestSpace' }],
    });
    mock_api::mock_response('GET', '/ipam/address', {
        results => [],
    });

    my $err;
    eval {
        PVE::Network::SDN::Ipams::InfobloxPlugin->del_ip(
            $config, 'simple1-10.0.0.0-24', $subnet, '10.0.0.99', 0,
        );
    };
    $err = $@;
    is($err, '', 'del_ip succeeds when address not found');

    # Verify no DELETE call was made
    my $calls = mock_api::get_all_calls();
    my @delete_calls = grep { $_->{method} eq 'DELETE' } @$calls;
    is(scalar @delete_calls, 0, 'no DELETE call made when address not found');
};

subtest 'del_ip with noerr=1 returns undef on API error' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/ipam/ip_space', {
        results => [{ id => 'ipam/ip_space/test-uuid-123', name => 'TestSpace' }],
    });
    mock_api::mock_response('GET', '/ipam/address', {
        results => [{ id => 'ipam/address/addr1', address => '10.0.0.5' }],
    });
    mock_api::mock_error('DELETE', '/ipam/address/ipam/address/addr1',
        "internal server error\n");

    my $result;
    eval {
        $result = PVE::Network::SDN::Ipams::InfobloxPlugin->del_ip(
            $config, 'simple1-10.0.0.0-24', $subnet, '10.0.0.5', 1,
        );
    };
    is($@, '', 'does not die with noerr=1');
    is($result, undef, 'returns undef with noerr=1');
};

subtest 'del_ip dies on API error without noerr' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/ipam/ip_space', {
        results => [{ id => 'ipam/ip_space/test-uuid-123', name => 'TestSpace' }],
    });
    mock_api::mock_response('GET', '/ipam/address', {
        results => [{ id => 'ipam/address/addr1', address => '10.0.0.5' }],
    });
    mock_api::mock_error('DELETE', '/ipam/address/ipam/address/addr1',
        "internal server error\n");

    eval {
        PVE::Network::SDN::Ipams::InfobloxPlugin->del_ip(
            $config, 'simple1-10.0.0.0-24', $subnet, '10.0.0.5', 0,
        );
    };
    like($@, qr/error deleting IP 10\.0\.0\.5/, 'dies with descriptive error message');
};

# -- update_ip tests --

subtest 'update_ip patches metadata on existing address' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/ipam/ip_space', {
        results => [{ id => 'ipam/ip_space/test-uuid-123', name => 'TestSpace' }],
    });
    mock_api::mock_response('GET', '/ipam/address', {
        results => [{ id => 'ipam/address/addr1', address => '10.0.0.5' }],
    });
    mock_api::mock_response('PATCH', '/ipam/address/ipam/address/addr1', {
        result => { id => 'ipam/address/addr1' },
    });

    my $err;
    eval {
        PVE::Network::SDN::Ipams::InfobloxPlugin->update_ip(
            $config, 'simple1-10.0.0.0-24', $subnet,
            '10.0.0.5', 'vm-web-new', 'FF:FF:FF:FF:FF:FF', 100, 0, 0,
        );
    };
    $err = $@;
    is($err, '', 'update_ip succeeds for existing address');

    # Verify PATCH was called with correct metadata
    my $calls = mock_api::get_all_calls();
    my @patch_calls = grep { $_->{method} eq 'PATCH' } @$calls;
    is(scalar @patch_calls, 1, 'exactly one PATCH call made');

    my $patch_params = $patch_calls[0]->{params};
    is($patch_params->{comment}, 'vm-web-new', 'comment is updated hostname');
    is_deeply($patch_params->{names}, [{ name => 'vm-web-new', type => 'user' }],
              'names updated with new hostname');
    is($patch_params->{hwaddr}, 'FF:FF:FF:FF:FF:FF', 'hwaddr updated');
    is($patch_params->{tags}->{source}, 'proxmox', 'tags has source=proxmox');
    is($patch_params->{tags}->{vmid}, '100', 'tags has vmid as string');
};

subtest 'update_ip with is_gateway sets comment to gateway and gateway tag' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/ipam/ip_space', {
        results => [{ id => 'ipam/ip_space/test-uuid-123', name => 'TestSpace' }],
    });
    mock_api::mock_response('GET', '/ipam/address', {
        results => [{ id => 'ipam/address/gw1', address => '10.0.0.1' }],
    });
    mock_api::mock_response('PATCH', '/ipam/address/ipam/address/gw1', {
        result => { id => 'ipam/address/gw1' },
    });

    my $err;
    eval {
        PVE::Network::SDN::Ipams::InfobloxPlugin->update_ip(
            $config, 'simple1-10.0.0.0-24', $subnet,
            '10.0.0.1', 'vm-web', undef, undef, 1, 0,
        );
    };
    $err = $@;
    is($err, '', 'update_ip succeeds for gateway');

    my $calls = mock_api::get_all_calls();
    my @patch_calls = grep { $_->{method} eq 'PATCH' } @$calls;
    my $patch_params = $patch_calls[0]->{params};
    is($patch_params->{comment}, 'gateway', 'comment is "gateway" not hostname');
    is($patch_params->{tags}->{gateway}, 'true', 'tags has gateway=true');
};

subtest 'update_ip with address not found dies' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/ipam/ip_space', {
        results => [{ id => 'ipam/ip_space/test-uuid-123', name => 'TestSpace' }],
    });
    mock_api::mock_response('GET', '/ipam/address', {
        results => [],
    });

    eval {
        PVE::Network::SDN::Ipams::InfobloxPlugin->update_ip(
            $config, 'simple1-10.0.0.0-24', $subnet,
            '10.0.0.5', 'vm-web', undef, 100, 0, 0,
        );
    };
    like($@, qr/address.*not found/, 'dies with address not found message');
};

subtest 'update_ip with noerr=1 returns undef on error' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/ipam/ip_space', {
        results => [{ id => 'ipam/ip_space/test-uuid-123', name => 'TestSpace' }],
    });
    mock_api::mock_response('GET', '/ipam/address', {
        results => [],
    });

    my $result;
    eval {
        $result = PVE::Network::SDN::Ipams::InfobloxPlugin->update_ip(
            $config, 'simple1-10.0.0.0-24', $subnet,
            '10.0.0.5', 'vm-web', undef, 100, 0, 1,
        );
    };
    is($@, '', 'does not die with noerr=1');
    is($result, undef, 'returns undef with noerr=1');
};

done_testing;
