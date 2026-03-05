package PVE::Network::SDN::Ipams::InfobloxPlugin;

use strict;
use warnings;

use PVE::INotify;
use PVE::Cluster;
use PVE::Tools;

use base('PVE::Network::SDN::Ipams::Plugin');

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
        ip_space => {
            type => 'string',
            description => 'Infoblox IP Space name',
        },
    };
}

sub options {
    return {
        url      => { optional => 0 },
        token    => { optional => 0 },
        ip_space => { optional => 0 },
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

sub get_ip_space_id {
    my ($config, $ip_space_name) = @_;

    my $result = eval {
        infoblox_api_request(
            $config, "GET",
            "/ipam/ip_space?_filter=name==\"$ip_space_name\"",
            undef,
        );
    };

    if ($@ || !$result || !$result->{results} || scalar(@{$result->{results}}) == 0) {
        return undef;
    }

    return $result->{results}->[0]->{id};
}

sub get_subnet_id {
    my ($config, $cidr, $space_id) = @_;

    my $result = eval {
        infoblox_api_request(
            $config, "GET",
            "/ipam/subnet?_filter=address==\"$cidr\" and space==\"$space_id\"",
            undef,
        );
    };

    if ($@ || !$result || !$result->{results} || scalar(@{$result->{results}}) == 0) {
        return undef;
    }

    return $result->{results}->[0]->{id};
}

sub get_address_id {
    my ($config, $ip, $space_id) = @_;

    my $result = eval {
        infoblox_api_request(
            $config, "GET",
            "/ipam/address?_filter=address==\"$ip\" and space==\"$space_id\"",
            undef,
        );
    };

    if ($@ || !$result || !$result->{results} || scalar(@{$result->{results}}) == 0) {
        return undef;
    }

    return $result->{results}->[0]->{id};
}

# --- IPAM interface method stubs (implemented in subsequent plans) ---

sub add_subnet {
    my ($class, $plugin_config, $subnetid, $subnet, $noerr) = @_;
    my $cidr = $subnet->{cidr};

    # Resolve IP Space name to ID
    my $space_id = get_ip_space_id($plugin_config, $plugin_config->{ip_space});
    if (!$space_id) {
        die "IP Space \"$plugin_config->{ip_space}\" not found in Infoblox\n" if !$noerr;
        return;
    }

    # Verify subnet exists in correct IP Space
    my $subnet_id = get_subnet_id($plugin_config, $cidr, $space_id);
    if (!$subnet_id) {
        die "subnet $cidr not found in IP Space \"$plugin_config->{ip_space}\"\n" if !$noerr;
        return;
    }

    # Subnet exists in correct IP Space -- verification passed
    return;
}

sub del_subnet {
    my ($class, $plugin_config, $subnetid, $subnet, $noerr) = @_;
    # No-op: subnets in Infoblox are managed by network teams
    return;
}

sub update_subnet {
    my ($class, $plugin_config, $subnetid, $subnet, $old_subnet, $noerr) = @_;
    # No-op: subnet properties in Infoblox are managed by network teams
    return;
}

sub add_ip {
    my ($class, $plugin_config, $subnetid, $subnet, $ip, $hostname, $mac, $vmid, $is_gateway, $noerr) = @_;
    die "not yet implemented\n";
}

sub update_ip {
    my ($class, $plugin_config, $subnetid, $subnet, $ip, $hostname, $mac, $vmid, $is_gateway, $noerr) = @_;
    die "not yet implemented\n";
}

sub del_ip {
    my ($class, $plugin_config, $subnetid, $subnet, $ip, $noerr) = @_;
    die "not yet implemented\n";
}

sub add_next_freeip {
    my ($class, $plugin_config, $subnetid, $subnet, $hostname, $mac, $vmid, $noerr) = @_;
    die "not yet implemented\n";
}

sub add_range_next_freeip {
    my ($class, $plugin_config, $subnet, $range, $data, $noerr) = @_;
    die "not yet implemented\n";
}

sub get_ips_from_mac {
    my ($class, $plugin_config, $mac, $zone) = @_;
    die "not yet implemented\n";
}

sub on_update_hook {
    my ($class, $plugin_config) = @_;
    die "not yet implemented\n";
}

1;
