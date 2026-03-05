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

# --- Private helper: build metadata params for address objects ---

sub build_address_params {
    my ($hostname, $mac, $vmid) = @_;
    my $params = {};
    $params->{comment} = $hostname if $hostname;
    $params->{names} = [{ name => $hostname, type => "user" }] if $hostname;
    my $tags = { source => "proxmox" };
    $tags->{vmid} = "$vmid" if defined $vmid;
    $params->{tags} = $tags;
    $params->{hwaddr} = $mac if $mac;
    return $params;
}

# --- Private helper: resolve range by start/end IP ---

sub get_range_id {
    my ($config, $start, $end, $space_id) = @_;
    my $result = eval {
        infoblox_api_request(
            $config, "GET",
            "/ipam/range?_filter=start==\"$start\" and end==\"$end\" and space==\"$space_id\"",
            undef,
        );
    };
    return undef if $@ || !$result || !$result->{results} || scalar(@{$result->{results}}) == 0;
    return $result->{results}->[0]->{id};
}

# --- IPAM interface methods ---

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

    my $space_id = get_ip_space_id($plugin_config, $plugin_config->{ip_space});
    if (!$space_id) {
        die "IP Space \"$plugin_config->{ip_space}\" not found\n" if !$noerr;
        return;
    }

    eval {
        # GET-before-POST: check if address already exists
        my $existing_id = get_address_id($plugin_config, $ip, $space_id);

        my $comment = $is_gateway ? "gateway" : $hostname;
        my $params = build_address_params($comment, $mac, $vmid);
        $params->{tags}->{gateway} = "true" if $is_gateway;

        if ($existing_id) {
            # Address exists -- update metadata (idempotent)
            infoblox_api_request(
                $plugin_config, "PATCH",
                "/ipam/address/$existing_id",
                $params,
            );
        } else {
            # Create new address
            $params->{address} = $ip;
            $params->{space} = $space_id;
            infoblox_api_request(
                $plugin_config, "POST",
                "/ipam/address",
                $params,
            );
        }
    };

    if ($@) {
        die "error adding IP $ip: $@" if !$noerr;
        return;
    }

    return;
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

    my $cidr = $subnet->{cidr};
    my $space_id = get_ip_space_id($plugin_config, $plugin_config->{ip_space});
    if (!$space_id) {
        die "IP Space \"$plugin_config->{ip_space}\" not found\n" if !$noerr;
        return;
    }

    my $infoblox_subnet_id = get_subnet_id($plugin_config, $cidr, $space_id);
    if (!$infoblox_subnet_id) {
        die "subnet $cidr not found in IP Space \"$plugin_config->{ip_space}\"\n" if !$noerr;
        return;
    }

    my $ip = eval {
        my $result = infoblox_api_request(
            $plugin_config, "POST",
            "/ipam/subnet/$infoblox_subnet_id/nextavailableip",
            undef,
        );

        my $address = $result->{results}->[0]->{address};
        my $address_id = $result->{results}->[0]->{id};

        # Set metadata on the allocated address
        my $params = build_address_params($hostname, $mac, $vmid);
        infoblox_api_request(
            $plugin_config, "PATCH",
            "/ipam/address/$address_id",
            $params,
        );

        return $address;
    };

    if ($@) {
        die "can't find free ip in subnet $cidr: $@" if !$noerr;
        return;
    }

    return $ip;
}

sub add_range_next_freeip {
    my ($class, $plugin_config, $subnet, $range, $data, $noerr) = @_;

    my $cidr = $subnet->{cidr};
    my $start = $range->{'start-address'};
    my $end = $range->{'end-address'};
    my $hostname = $data->{hostname};
    my $mac = $data->{mac};
    my $vmid = $data->{vmid};

    my $space_id = get_ip_space_id($plugin_config, $plugin_config->{ip_space});
    if (!$space_id) {
        die "IP Space \"$plugin_config->{ip_space}\" not found\n" if !$noerr;
        return;
    }

    my $range_id = get_range_id($plugin_config, $start, $end, $space_id);
    if (!$range_id) {
        die "range $start-$end not found in IP Space \"$plugin_config->{ip_space}\"\n" if !$noerr;
        return;
    }

    my $ip = eval {
        my $result = infoblox_api_request(
            $plugin_config, "POST",
            "/ipam/range/$range_id/nextavailableip",
            undef,
        );

        my $address = $result->{results}->[0]->{address};
        my $address_id = $result->{results}->[0]->{id};

        my $params = build_address_params($hostname, $mac, $vmid);
        infoblox_api_request(
            $plugin_config, "PATCH",
            "/ipam/address/$address_id",
            $params,
        );

        return $address;
    };

    if ($@) {
        die "can't find free ip in range $start-$end: $@" if !$noerr;
        return;
    }

    return $ip;
}

sub get_ips_from_mac {
    my ($class, $plugin_config, $mac, $zone) = @_;
    die "not yet implemented\n";
}

sub on_update_hook {
    my ($class, $plugin_config) = @_;

    # Step 1: API reachability + Step 2: Credential validity
    # A single GET to /ipam/ip_space tests both reachability and auth.
    # If the API is unreachable, we get a connection error.
    # If credentials are bad, we get a 401/403.
    my $result = eval {
        infoblox_api_request(
            $plugin_config, "GET",
            "/ipam/ip_space?_filter=name==\"$plugin_config->{ip_space}\"",
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

    # Step 3: IP Space existence
    if (!$result || !$result->{results} || scalar(@{$result->{results}}) == 0) {
        die "IP Space \"$plugin_config->{ip_space}\" not found in Infoblox\n";
    }

    return;
}

1;
