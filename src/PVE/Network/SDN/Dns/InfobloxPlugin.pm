package PVE::Network::SDN::Dns::InfobloxPlugin;

use strict;
use warnings;

use PVE::INotify;
use PVE::Cluster;
use PVE::Tools;
use Net::IP;

use base('PVE::Network::SDN::Dns::Plugin');

sub type {
    return 'infobloxuddi';
}

sub properties {
    return {
        url => {
            type => 'string',
            description => 'Infoblox Universal DDI API URL (e.g., https://csp.infoblox.com)',
        },
        token => {
            type => 'string',
            description => 'Infoblox API token',
        },
        dns_view => {
            type => 'string',
            description => 'Infoblox DNS View name (default: "default")',
        },
        ttl => {
            type => 'integer',
            description => 'DNS record TTL in seconds (default: 3600)',
        },
    };
}

sub options {
    return {
        url      => { optional => 0 },
        token    => { optional => 0 },
        dns_view => { optional => 1 },
        ttl      => { optional => 1 },
    };
}

# --- Private helper functions ---

sub infoblox_api_request {
    my ($config, $method, $path, $params) = @_;

    return PVE::Network::SDN::api_request(
        $method,
        "$config->{url}/api/ddi/v1${path}",
        [
            'Content-Type',  'application/json; charset=UTF-8',
            'Authorization', "Token $config->{token}",
        ],
        $params,
    );
}

sub get_dns_view_id {
    my ($config) = @_;

    my $view_name = $config->{dns_view} || 'default';

    my $result = eval {
        infoblox_api_request(
            $config, "GET",
            "/dns/view?_filter=name==\"$view_name\"",
            undef,
        );
    };

    if ($@ || !$result || !$result->{results} || scalar(@{$result->{results}}) == 0) {
        return undef;
    }

    return $result->{results}->[0]->{id};
}

sub get_auth_zone_id {
    my ($config, $zone_fqdn, $view_id) = @_;

    # Append trailing dot if missing
    $zone_fqdn .= '.' unless $zone_fqdn =~ /\.$/;

    my $result = eval {
        infoblox_api_request(
            $config, "GET",
            "/dns/auth_zone?_filter=fqdn==\"$zone_fqdn\" and view==\"$view_id\"",
            undef,
        );
    };

    if ($@ || !$result || !$result->{results} || scalar(@{$result->{results}}) == 0) {
        return undef;
    }

    return $result->{results}->[0]->{id};
}

sub find_dns_record_id {
    my ($config, $fqdn, $type, $view_id) = @_;

    # Append trailing dot if missing
    $fqdn .= '.' unless $fqdn =~ /\.$/;

    my $result = eval {
        infoblox_api_request(
            $config, "GET",
            "/dns/record?_filter="
              . "absolute_name_spec==\"$fqdn\""
              . " and type==\"$type\""
              . " and view==\"$view_id\"",
            undef,
        );
    };

    if ($@ || !$result || !$result->{results} || scalar(@{$result->{results}}) == 0) {
        return undef;
    }

    return $result->{results}->[0]->{id};
}

# --- DNS interface method stubs (implemented in Plan 02) ---

sub add_a_record {
    my ($class, $plugin_config, $zone, $hostname, $ip, $noerr) = @_;
    die "not yet implemented\n";
}

sub add_ptr_record {
    my ($class, $plugin_config, $zone, $hostname, $ip, $noerr) = @_;
    die "not yet implemented\n";
}

sub del_a_record {
    my ($class, $plugin_config, $zone, $hostname, $ip, $noerr) = @_;
    die "not yet implemented\n";
}

sub del_ptr_record {
    my ($class, $plugin_config, $zone, $ip, $noerr) = @_;
    die "not yet implemented\n";
}

sub verify_zone {
    my ($class, $plugin_config, $zone, $noerr) = @_;

    my $view_name = $plugin_config->{dns_view} || 'default';

    # Resolve DNS View ID
    my $view_id = get_dns_view_id($plugin_config);
    if (!$view_id) {
        die "DNS View \"$view_name\" not found in Infoblox\n" if !$noerr;
        return;
    }

    # Resolve auth zone
    my $zone_id = get_auth_zone_id($plugin_config, $zone, $view_id);
    if (!$zone_id) {
        die "zone $zone not found in Infoblox\n" if !$noerr;
        return;
    }

    return;
}

sub get_reversedns_zone {
    my ($class, $plugin_config, $subnetid, $subnet, $ip) = @_;
    die "not yet implemented\n";
}

sub on_update_hook {
    my ($class, $plugin_config) = @_;

    my $view_name = $plugin_config->{dns_view} || 'default';

    # Single GET to /dns/view tests reachability + auth + DNS View existence (3-in-1)
    my $result = eval {
        infoblox_api_request(
            $plugin_config, "GET",
            "/dns/view?_filter=name==\"$view_name\"",
            undef,
        );
    };

    if ($@) {
        # Distinguish between connectivity and auth errors
        if ($@ =~ /401|Unauthorized|403|Forbidden/i) {
            die "Authentication failed: invalid API token\n";
        }
        die "Cannot reach Infoblox API at $plugin_config->{url}: $@\n";
    }

    # DNS View existence
    if (!$result || !$result->{results} || scalar(@{$result->{results}}) == 0) {
        die "DNS View \"$view_name\" not found in Infoblox\n";
    }

    return;
}

1;
