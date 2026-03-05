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

# -- ID resolution helper tests (placeholders for Task 2) --

TODO: {
    local $TODO = 'ID resolution helpers not yet implemented';

    subtest 'get_ip_space_id resolves name to id' => sub {
        ok(0, 'get_ip_space_id placeholder');
    };

    subtest 'get_subnet_id resolves cidr to id' => sub {
        ok(0, 'get_subnet_id placeholder');
    };

    subtest 'get_address_id resolves ip to id' => sub {
        ok(0, 'get_address_id placeholder');
    };
}

done_testing;
