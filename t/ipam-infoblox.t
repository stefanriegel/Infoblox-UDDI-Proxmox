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

done_testing;
