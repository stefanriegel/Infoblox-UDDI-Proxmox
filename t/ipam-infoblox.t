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

done_testing;
