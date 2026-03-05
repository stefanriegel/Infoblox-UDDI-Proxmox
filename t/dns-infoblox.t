#!/usr/bin/perl

use strict;
use warnings;

use lib 't/lib';
use lib 'src';
use lib 't';

use Test::More;
use mock_api;

# Load the DNS plugin module
use_ok('PVE::Network::SDN::Dns::InfobloxPlugin')
    or BAIL_OUT('Cannot load DNS InfobloxPlugin');

# Test config used across subtests
my $config = {
    url      => 'https://csp.infoblox.com',
    token    => 'test-api-token-12345',
    dns_view => 'TestView',
};

# -- Registration tests --

subtest 'type returns infobloxuddi' => sub {
    is(PVE::Network::SDN::Dns::InfobloxPlugin->type(), 'infobloxuddi',
       'type() returns infobloxuddi');
};

subtest 'properties has required fields' => sub {
    my $props = PVE::Network::SDN::Dns::InfobloxPlugin->properties();
    ok(ref $props eq 'HASH', 'properties() returns a hashref');
    for my $field (qw(url token)) {
        ok(exists $props->{$field}, "properties has '$field' field");
        is($props->{$field}->{type}, 'string', "'$field' has type => string");
    }
    ok(exists $props->{dns_view}, "properties has 'dns_view' field");
    is($props->{dns_view}->{type}, 'string', "'dns_view' has type => string");
    ok(exists $props->{ttl}, "properties has 'ttl' field");
    is($props->{ttl}->{type}, 'integer', "'ttl' has type => integer");
};

subtest 'options marks url/token required and dns_view/ttl optional' => sub {
    my $opts = PVE::Network::SDN::Dns::InfobloxPlugin->options();
    ok(ref $opts eq 'HASH', 'options() returns a hashref');
    for my $field (qw(url token)) {
        ok(exists $opts->{$field}, "options has '$field' field");
        is($opts->{$field}->{optional}, 0, "'$field' is required (optional => 0)");
    }
    for my $field (qw(dns_view ttl)) {
        ok(exists $opts->{$field}, "options has '$field' field");
        is($opts->{$field}->{optional}, 1, "'$field' is optional (optional => 1)");
    }
};

# -- API request helper tests --

subtest 'infoblox_api_request builds correct URL and headers' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/dns/view', {
        results => [{ id => 'dns/view/test-uuid', name => 'TestView' }],
    });

    PVE::Network::SDN::Dns::InfobloxPlugin::infoblox_api_request(
        $config, 'GET', '/dns/view', undef,
    );

    my $call = mock_api::get_last_call();
    ok(defined $call, 'api call was captured');
    is($call->{method}, 'GET', 'method is GET');
    like($call->{url}, qr{https://csp\.infoblox\.com/api/ddi/v1/dns/view},
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

# -- get_dns_view_id tests --

subtest 'get_dns_view_id found' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/dns/view', {
        results => [{ id => 'dns/view/view-uuid-123', name => 'TestView' }],
    });

    my $id = PVE::Network::SDN::Dns::InfobloxPlugin::get_dns_view_id($config);
    is($id, 'dns/view/view-uuid-123', 'returns the DNS View id');
};

subtest 'get_dns_view_id not found' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/dns/view', {
        results => [],
    });

    my $id = PVE::Network::SDN::Dns::InfobloxPlugin::get_dns_view_id($config);
    is($id, undef, 'returns undef for non-existent DNS View');
};

subtest 'get_dns_view_id defaults to default when dns_view not in config' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/dns/view', {
        results => [{ id => 'dns/view/default-uuid', name => 'default' }],
    });

    my $config_no_view = {
        url   => 'https://csp.infoblox.com',
        token => 'test-api-token-12345',
    };

    my $id = PVE::Network::SDN::Dns::InfobloxPlugin::get_dns_view_id($config_no_view);
    is($id, 'dns/view/default-uuid', 'returns the default view id');

    # Verify the query used "default" as view name
    my $call = mock_api::get_last_call();
    like($call->{url}, qr/name=="default"/, 'query uses "default" as view name');
};

# -- get_auth_zone_id tests --

subtest 'get_auth_zone_id found' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/dns/auth_zone', {
        results => [{ id => 'dns/auth_zone/zone-uuid-456', fqdn => 'example.com.' }],
    });

    my $id = PVE::Network::SDN::Dns::InfobloxPlugin::get_auth_zone_id(
        $config, 'example.com', 'dns/view/view-uuid-123',
    );
    is($id, 'dns/auth_zone/zone-uuid-456', 'returns the auth zone id');
};

subtest 'get_auth_zone_id not found' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/dns/auth_zone', {
        results => [],
    });

    my $id = PVE::Network::SDN::Dns::InfobloxPlugin::get_auth_zone_id(
        $config, 'nonexistent.com', 'dns/view/view-uuid-123',
    );
    is($id, undef, 'returns undef for non-existent auth zone');
};

subtest 'get_auth_zone_id appends trailing dot if missing' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/dns/auth_zone', {
        results => [{ id => 'dns/auth_zone/zone-uuid-789', fqdn => 'example.com.' }],
    });

    PVE::Network::SDN::Dns::InfobloxPlugin::get_auth_zone_id(
        $config, 'example.com', 'dns/view/view-uuid-123',
    );

    my $call = mock_api::get_last_call();
    like($call->{url}, qr/fqdn=="example\.com\."/, 'query includes trailing dot in FQDN');
};

# -- find_dns_record_id tests --

subtest 'find_dns_record_id found A record' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/dns/record', {
        results => [{ id => 'dns/record/rec-a-uuid', type => 'A' }],
    });

    my $id = PVE::Network::SDN::Dns::InfobloxPlugin::find_dns_record_id(
        $config, 'webserver.example.com', 'A', 'dns/view/view-uuid-123',
    );
    is($id, 'dns/record/rec-a-uuid', 'returns the A record id');
};

subtest 'find_dns_record_id found PTR record' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/dns/record', {
        results => [{ id => 'dns/record/rec-ptr-uuid', type => 'PTR' }],
    });

    my $id = PVE::Network::SDN::Dns::InfobloxPlugin::find_dns_record_id(
        $config, '5.0.0.10.in-addr.arpa', 'PTR', 'dns/view/view-uuid-123',
    );
    is($id, 'dns/record/rec-ptr-uuid', 'returns the PTR record id');
};

subtest 'find_dns_record_id not found' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/dns/record', {
        results => [],
    });

    my $id = PVE::Network::SDN::Dns::InfobloxPlugin::find_dns_record_id(
        $config, 'missing.example.com', 'A', 'dns/view/view-uuid-123',
    );
    is($id, undef, 'returns undef for non-existent record');
};

subtest 'find_dns_record_id appends trailing dot if missing' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/dns/record', {
        results => [{ id => 'dns/record/rec-dot-uuid', type => 'A' }],
    });

    PVE::Network::SDN::Dns::InfobloxPlugin::find_dns_record_id(
        $config, 'webserver.example.com', 'A', 'dns/view/view-uuid-123',
    );

    my $call = mock_api::get_last_call();
    like($call->{url}, qr/absolute_name_spec=="webserver\.example\.com\."/,
         'query includes trailing dot in FQDN');
};

done_testing;
