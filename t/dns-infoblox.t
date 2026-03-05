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

# -- verify_zone tests --

subtest 'verify_zone with existing zone succeeds' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/dns/view', {
        results => [{ id => 'dns/view/view-uuid-123', name => 'TestView' }],
    });
    mock_api::mock_response('GET', '/dns/auth_zone', {
        results => [{ id => 'dns/auth_zone/zone-uuid-456', fqdn => 'example.com.' }],
    });

    my $err;
    eval {
        PVE::Network::SDN::Dns::InfobloxPlugin->verify_zone(
            $config, 'example.com', 0,
        );
    };
    $err = $@;
    is($err, '', 'verify_zone succeeds for existing zone');
};

subtest 'verify_zone with missing zone dies' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/dns/view', {
        results => [{ id => 'dns/view/view-uuid-123', name => 'TestView' }],
    });
    mock_api::mock_response('GET', '/dns/auth_zone', {
        results => [],
    });

    eval {
        PVE::Network::SDN::Dns::InfobloxPlugin->verify_zone(
            $config, 'example.com', 0,
        );
    };
    like($@, qr/zone.*not found/, 'dies with zone not found message');
};

subtest 'verify_zone with missing DNS View dies' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/dns/view', {
        results => [],
    });

    eval {
        PVE::Network::SDN::Dns::InfobloxPlugin->verify_zone(
            $config, 'example.com', 0,
        );
    };
    like($@, qr/DNS View.*not found/, 'dies with DNS View not found message');
};

subtest 'verify_zone with noerr=1 returns undef instead of dying' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/dns/view', {
        results => [],
    });

    my $result;
    eval {
        $result = PVE::Network::SDN::Dns::InfobloxPlugin->verify_zone(
            $config, 'example.com', 1,
        );
    };
    is($@, '', 'does not die with noerr=1');
    is($result, undef, 'returns undef with noerr=1');
};

# -- on_update_hook tests --

subtest 'on_update_hook with valid config succeeds' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/dns/view', {
        results => [{ id => 'dns/view/view-uuid-123', name => 'TestView' }],
    });

    my $err;
    eval {
        PVE::Network::SDN::Dns::InfobloxPlugin->on_update_hook($config);
    };
    $err = $@;
    is($err, '', 'on_update_hook succeeds with valid config');
};

subtest 'on_update_hook with unreachable API' => sub {
    mock_api::clear_mocks();
    mock_api::mock_error('GET', '/dns/view', "connection refused\n");

    eval {
        PVE::Network::SDN::Dns::InfobloxPlugin->on_update_hook($config);
    };
    like($@, qr/Cannot reach Infoblox API at/, 'dies with unreachable API message');
};

subtest 'on_update_hook with invalid token' => sub {
    mock_api::clear_mocks();
    mock_api::mock_error('GET', '/dns/view', "401 Unauthorized\n");

    eval {
        PVE::Network::SDN::Dns::InfobloxPlugin->on_update_hook($config);
    };
    like($@, qr/Authentication failed: invalid API token/, 'dies with auth failure message');
};

subtest 'on_update_hook with missing DNS View' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/dns/view', {
        results => [],
    });

    eval {
        PVE::Network::SDN::Dns::InfobloxPlugin->on_update_hook($config);
    };
    like($@, qr/DNS View.*not found in Infoblox/, 'dies with DNS View not found message');
};

# -- add_a_record tests --

subtest 'add_a_record creates new A record' => sub {
    mock_api::clear_mocks();
    # Mock DNS View found
    mock_api::mock_response('GET', '/dns/view', {
        results => [{ id => 'dns/view/view-uuid-123', name => 'TestView' }],
    });
    # Mock auth zone found
    mock_api::mock_response('GET', '/dns/auth_zone', {
        results => [{ id => 'dns/auth_zone/zone-uuid-456', fqdn => 'example.com.' }],
    });
    # Mock find_dns_record_id: no existing record
    mock_api::mock_response('GET', '/dns/record', {
        results => [],
    });
    # Mock POST success
    mock_api::mock_response('POST', '/dns/record', {
        result => { id => 'dns/record/new-a-uuid' },
    });

    eval {
        PVE::Network::SDN::Dns::InfobloxPlugin->add_a_record(
            $config, 'example.com', 'webserver', '10.0.0.5', 0,
        );
    };
    is($@, '', 'add_a_record succeeds for new record');

    # Find the POST call
    my $calls = mock_api::get_all_calls();
    my @post_calls = grep { $_->{method} eq 'POST' } @$calls;
    is(scalar @post_calls, 1, 'exactly one POST call made');

    my $post = $post_calls[0];
    like($post->{url}, qr{/dns/record}, 'POST to /dns/record');
    is($post->{params}->{type}, 'A', 'type is A');
    is($post->{params}->{rdata}->{address}, '10.0.0.5', 'rdata.address is correct');
    is($post->{params}->{name_in_zone}, 'webserver', 'name_in_zone is hostname');
    is($post->{params}->{zone}, 'dns/auth_zone/zone-uuid-456', 'zone is auth_zone resource ID');
    is($post->{params}->{view}, 'dns/view/view-uuid-123', 'view is DNS View resource ID');
    is($post->{params}->{ttl}, 3600, 'ttl defaults to 3600');
    is($post->{params}->{comment}, 'managed by proxmox', 'comment is set');
    is($post->{params}->{tags}->{source}, 'proxmox', 'tags.source is proxmox');
};

subtest 'add_a_record updates existing record (idempotent)' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/dns/view', {
        results => [{ id => 'dns/view/view-uuid-123', name => 'TestView' }],
    });
    mock_api::mock_response('GET', '/dns/auth_zone', {
        results => [{ id => 'dns/auth_zone/zone-uuid-456', fqdn => 'example.com.' }],
    });
    # Existing record found
    mock_api::mock_response('GET', '/dns/record', {
        results => [{ id => 'dns/record/existing-a-uuid', type => 'A' }],
    });
    # Mock PATCH success
    mock_api::mock_response('PATCH', '/dns/record', {
        result => { id => 'dns/record/existing-a-uuid' },
    });

    eval {
        PVE::Network::SDN::Dns::InfobloxPlugin->add_a_record(
            $config, 'example.com', 'webserver', '10.0.0.5', 0,
        );
    };
    is($@, '', 'add_a_record succeeds for existing record');

    # Verify PATCH was called (not POST)
    my $calls = mock_api::get_all_calls();
    my @patch_calls = grep { $_->{method} eq 'PATCH' } @$calls;
    my @post_calls = grep { $_->{method} eq 'POST' } @$calls;
    is(scalar @patch_calls, 1, 'exactly one PATCH call made');
    is(scalar @post_calls, 0, 'no POST call made');

    my $patch = $patch_calls[0];
    like($patch->{url}, qr{/dns/record/existing-a-uuid}, 'PATCH URL includes record ID');
};

subtest 'add_a_record uses custom ttl from config' => sub {
    mock_api::clear_mocks();
    my $config_ttl = { %$config, ttl => 7200 };

    mock_api::mock_response('GET', '/dns/view', {
        results => [{ id => 'dns/view/view-uuid-123', name => 'TestView' }],
    });
    mock_api::mock_response('GET', '/dns/auth_zone', {
        results => [{ id => 'dns/auth_zone/zone-uuid-456', fqdn => 'example.com.' }],
    });
    mock_api::mock_response('GET', '/dns/record', {
        results => [],
    });
    mock_api::mock_response('POST', '/dns/record', {
        result => { id => 'dns/record/new-a-uuid' },
    });

    eval {
        PVE::Network::SDN::Dns::InfobloxPlugin->add_a_record(
            $config_ttl, 'example.com', 'webserver', '10.0.0.5', 0,
        );
    };
    is($@, '', 'add_a_record succeeds with custom TTL');

    my $calls = mock_api::get_all_calls();
    my @post_calls = grep { $_->{method} eq 'POST' } @$calls;
    is($post_calls[0]->{params}->{ttl}, 7200, 'ttl uses config value 7200');
};

subtest 'add_a_record with missing DNS View dies' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/dns/view', {
        results => [],
    });

    eval {
        PVE::Network::SDN::Dns::InfobloxPlugin->add_a_record(
            $config, 'example.com', 'webserver', '10.0.0.5', 0,
        );
    };
    like($@, qr/DNS View.*not found/, 'dies with DNS View not found message');
};

subtest 'add_a_record with noerr=1 returns undef on error' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/dns/view', {
        results => [],
    });

    my $result;
    eval {
        $result = PVE::Network::SDN::Dns::InfobloxPlugin->add_a_record(
            $config, 'example.com', 'webserver', '10.0.0.5', 1,
        );
    };
    is($@, '', 'does not die with noerr=1');
};

# -- del_a_record tests --

subtest 'del_a_record deletes existing record' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/dns/view', {
        results => [{ id => 'dns/view/view-uuid-123', name => 'TestView' }],
    });
    # Existing record found
    mock_api::mock_response('GET', '/dns/record', {
        results => [{ id => 'dns/record/a-rec-to-delete', type => 'A' }],
    });
    # Mock DELETE success
    mock_api::mock_response('DELETE', '/dns/record', {});

    eval {
        PVE::Network::SDN::Dns::InfobloxPlugin->del_a_record(
            $config, 'example.com', 'webserver', '10.0.0.5', 0,
        );
    };
    is($@, '', 'del_a_record succeeds for existing record');

    # Verify DELETE was called
    my $calls = mock_api::get_all_calls();
    my @del_calls = grep { $_->{method} eq 'DELETE' } @$calls;
    is(scalar @del_calls, 1, 'exactly one DELETE call made');
    like($del_calls[0]->{url}, qr{/dns/record/a-rec-to-delete}, 'DELETE URL includes record ID');
};

subtest 'del_a_record with record not found succeeds silently' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/dns/view', {
        results => [{ id => 'dns/view/view-uuid-123', name => 'TestView' }],
    });
    # No existing record
    mock_api::mock_response('GET', '/dns/record', {
        results => [],
    });

    eval {
        PVE::Network::SDN::Dns::InfobloxPlugin->del_a_record(
            $config, 'example.com', 'webserver', '10.0.0.5', 0,
        );
    };
    is($@, '', 'del_a_record succeeds silently when record not found');

    # Verify no DELETE call
    my $calls = mock_api::get_all_calls();
    my @del_calls = grep { $_->{method} eq 'DELETE' } @$calls;
    is(scalar @del_calls, 0, 'no DELETE call made');
};

subtest 'del_a_record with missing DNS View dies' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/dns/view', {
        results => [],
    });

    eval {
        PVE::Network::SDN::Dns::InfobloxPlugin->del_a_record(
            $config, 'example.com', 'webserver', '10.0.0.5', 0,
        );
    };
    like($@, qr/DNS View.*not found/, 'dies with DNS View not found message');
};

subtest 'del_a_record with noerr=1 returns undef on error' => sub {
    mock_api::clear_mocks();
    mock_api::mock_response('GET', '/dns/view', {
        results => [],
    });

    my $result;
    eval {
        $result = PVE::Network::SDN::Dns::InfobloxPlugin->del_a_record(
            $config, 'example.com', 'webserver', '10.0.0.5', 1,
        );
    };
    is($@, '', 'does not die with noerr=1');
};

# -- Coverage summary test --

subtest 'coverage_summary - all methods exist' => sub {
    can_ok('PVE::Network::SDN::Dns::InfobloxPlugin',
        qw(type properties options
           verify_zone on_update_hook
           add_a_record add_ptr_record del_a_record del_ptr_record
           get_reversedns_zone));
};

done_testing;
